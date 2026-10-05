"""nadeliv 백엔드 응답 형식을 흉내 내는 iOS UI 검증용 가짜 서버.

로컬 백엔드는 원격(운영) MongoDB 에 붙어 있어 테스트 계정·업로드를 만들 수 없다.
이 서버로 로그인·여행 목록·앨범·업로드·삭제·토큰 만료(401→refresh) 흐름을 검증한다.

업로드는 백엔드 3단계 presigned 방식과 같은 API 를 흉내 낸다:
  POST .../media/uploads → SINGLE(≤256KB) 또는 MULTIPART(128KB part) URL 발급 (실제 백엔드는 64MB/16MB)
  PUT  /s3/{uploadId}/{partNumber}?v=N → part 저장 (MOCK_EXPIRE_FIRST=1 이면 v=1 URL 은 403 → 재발급 흐름 검증)
                                           (MOCK_SLOW_PUT=초 이면 part 마다 그만큼 지연 → 앱 종료·재실행 복구 검증)
  POST .../uploads/{id}/parts, .../complete, DELETE .../uploads/{id}

여행 만들기·수정·삭제: POST /api/v1/travels, PUT·DELETE /api/v1/travels/{id} (수정·삭제는 ADMIN 만)
커버 사진: POST /api/v1/files (multipart file + fileKey) → files/ 에 저장하고 공개 URL 반환
  (MOCK_FAIL_FILES=1 이면 400 → 만들기에서 "커버만 실패" 경고 흐름 검증)

  ./setup.sh                     # 샘플 파일 생성 (최초 1회)
  python3 server.py 3999         # 실행
  xcodebuild ... BACKEND_URL=http://localhost:3999 build

테스트 계정: mockuser / mock-pass (서버 재시작 시 기존 액세스 토큰은 만료 처리됨)
"""
import json, os, re, sys, uuid
from email.parser import BytesParser
from email.policy import HTTP
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

BASE = os.path.dirname(os.path.abspath(__file__))
FILES = os.path.join(BASE, "files")
LOG = os.path.join(BASE, "requests.log")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 3999
HOST = f"http://localhost:{PORT}"
ME = "mockuser"

def log(msg):
    with open(LOG, "a") as f: f.write(msg + "\n")

TRAVELS = [
    {"id": "t-jeju-001", "title": "제주 가을 여행", "description": "", "coverImageUrl": f"{HOST}/files/p3.jpg",
     "visibility": "PUBLIC", "status": "COMPLETED", "startDate": "2026-09-20", "endDate": "2026-09-23",
     "destination": "제주", "memberCount": 2,
     "members": [{"userId": ME, "role": "ADMIN", "nickname": "나", "joinedAt": "2026-09-01T10:00:00"},
                 {"userId": "friend", "role": "USER", "nickname": "여행친구", "joinedAt": "2026-09-02T10:00:00"}],
     "created": "2026-09-01T10:00:00.123456", "updated": "2026-09-24T08:00:00"},
    {"id": "t-gyeongju-002", "title": "경주 한옥 스테이", "coverImageUrl": None, "status": "PLANNING",
     "startDate": "2026-11-07", "endDate": "2026-11-08", "destination": "경주", "memberCount": 3,
     "members": [{"userId": "friend", "role": "ADMIN", "nickname": "여행친구"},
                 {"userId": ME, "role": "USER", "nickname": "나"},
                 {"userId": "third", "role": "USER", "nickname": "셋째"}],
     "created": "2026-10-01T10:00:00"},
    {"id": "t-busan-003", "title": "부산 바다 산책", "coverImageUrl": None, "status": "COMPLETED",
     "startDate": "2025-12-30", "endDate": "2026-01-02", "destination": "부산", "memberCount": 2,
     "members": [{"userId": "friend", "role": "ADMIN", "nickname": "여행친구"},
                 {"userId": ME, "role": "VIEWER", "nickname": "나"}],
     "created": "2025-12-01T10:00:00"},
]

MEDIA = {}
def seed():
    items = []
    for i in range(1, 15):
        uploader = ME if i % 3 else "friend"
        items.append({"id": f"m{i}", "travelId": "t-jeju-001", "uploadUserId": uploader,
            "fileName": f"{uuid.uuid4()}.jpg", "originalFileName": f"IMG_{4000+i}.jpg",
            "fileUrl": f"{HOST}/files/p{i}.jpg",
            # m5 는 썸네일이 아직 없는 상태(Lambda 지연)를 흉내 낸다 → 원본 폴백 확인용
            "thumbnailUrl": f"{HOST}/files/p{i}-thumb.jpg" if i != 5 else f"{HOST}/files/missing-thumb.jpg",
            # 3단계 이후 업로드분에만 display(2048px JPEG) 가 있다. 홀수는 있음, 짝수는 없음(원본 폴백 확인용)
            "displayUrl": f"{HOST}/files/p{i}.jpg" if i % 2 else None,
            "mimeType": "image/jpeg", "fileSize": os.path.getsize(os.path.join(FILES, f"p{i}.jpg")),
            "width": 2400, "height": 2400, "duration": None,
            "takenAt": f"2026-09-2{i % 4}T1{i % 10}:0{i % 6}:00", "created": f"2026-09-24T09:{i:02d}:00.5"})
    items.append({"id": "v1", "travelId": "t-jeju-001", "uploadUserId": ME, "originalFileName": "IMG_5001.MP4",
        "fileUrl": f"{HOST}/files/v1.mp4", "thumbnailUrl": f"{HOST}/files/v1-thumb.jpg", "displayUrl": None, "mimeType": "video/mp4",
        "fileSize": os.path.getsize(os.path.join(FILES, "v1.mp4")), "width": 1920, "height": 1080, "duration": 75,
        "takenAt": "2026-09-22T17:30:00", "created": "2026-09-24T10:00:00"})
    MEDIA["t-jeju-001"] = items
    MEDIA["t-gyeongju-002"] = []
    MEDIA["t-busan-003"] = [dict(items[0], id="b1", travelId="t-busan-003", uploadUserId="friend")]
seed()

# 서버 재시작 전 발급 토큰은 모두 만료된 것으로 본다 → 앱의 401 → refresh → 재시도 흐름 검증용
VALID = set()
COUNTER = [10]
def issue():
    COUNTER[0] += 1
    t = f"access-{COUNTER[0]}"; VALID.add(t); return t

def is_video(m): return (m.get("mimeType") or "").startswith("video/")

# presigned 업로드 세션 (uploadId → dict). 실제보다 작은 기준으로 멀티파트를 자주 타게 한다
UPLOADS = {}
MULTIPART_THRESHOLD = 256 * 1024
PART_SIZE = 128 * 1024
EXPIRE_FIRST = os.environ.get("MOCK_EXPIRE_FIRST") == "1"
# part 하나 받는 데 N초 걸리게 해서, 업로드 도중 앱을 종료하고 재실행하는 복구 흐름을 검증한다
SLOW_PUT = float(os.environ.get("MOCK_SLOW_PUT") or 0)
PARTS_DIR = os.path.join(FILES, "parts")
os.makedirs(PARTS_DIR, exist_ok=True)

FAIL_FILES = os.environ.get("MOCK_FAIL_FILES") == "1"
SAFE_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")

def find_travel(travel_id):
    return next((t for t in TRAVELS if t["id"] == travel_id), None)

def apply_travel_fields(t, body):
    """백엔드 updateTravel 과 같이 null(없는 키)은 그대로 둔다."""
    for k in ("title", "description", "coverImageUrl", "visibility", "status", "startDate", "endDate", "destination", "tags"):
        if body.get(k) is not None: t[k] = body[k]
    if t.get("coverImageUrl") == "": t["coverImageUrl"] = None
    if t.get("startDate") and t.get("endDate") and t["startDate"] > t["endDate"]:
        return False
    return True

def my_role(travel_id):
    return next((x["role"] for t in TRAVELS if t["id"] == travel_id for x in t["members"] if x["userId"] == ME), None)

def part_urls(up, numbers=None):
    v = up["urlVersion"]
    out = []
    for n in range(1, up["partCount"] + 1):
        if numbers and n not in numbers: continue
        size = min(up["partSize"], up["fileSize"] - (n - 1) * up["partSize"])
        out.append({"partNumber": n, "size": size, "url": f"{HOST}/s3/{up['id']}/{n}?v={v}"})
    return out

def upload_response(up, numbers=None):
    return {"uploadId": up["id"], "method": up["method"], "contentType": up["contentType"],
            "partSize": up["partSize"], "partCount": up["partCount"], "parts": part_urls(up, numbers),
            "urlExpiresAt": "2026-10-05T00:00:00", "sessionExpiresAt": "2026-10-06T00:00:00"}

class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): log(f"{self.command} {self.path} -> {args[1] if len(args) > 1 else ''}")

    def send_json(self, code, obj=None, headers=None):
        body = b"" if obj is None else json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        if obj is not None: self.send_header("Content-Type", "application/json;charset=UTF-8")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers()
        if body: self.wfile.write(body)

    def authed(self):
        auth = self.headers.get("Authorization", "")
        token = auth[len("Bearer "):] if auth.startswith("Bearer ") else ""
        if token.startswith("access-") and token not in VALID:
            log(f"EXPIRED token {token} -> 401")
            self.send_json(401, {"error": "Unauthorized", "message": "Token expired", "status": 401}); return False
        if not token.startswith("access-"):
            self.send_json(403, {"error": "Forbidden"}); return False
        return True

    def do_GET(self):
        u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path.startswith("/files/"): return self.serve_file(u.path[len("/files/"):])
        if not self.authed(): return
        if u.path == "/api/v1/users/me":
            return self.send_json(200, {"id": "64f0mock", "userId": ME, "name": "테스트 사용자", "email": "mock@example.com",
                                        "roles": ["user"], "createdAt": "2026-01-01T00:00:00"})
        if u.path == "/api/v1/travels/my":
            page, size = int(q.get("page", 0)), int(q.get("size", 10))
            chunk = TRAVELS[page*size:(page+1)*size]
            return self.send_json(200, {"travels": chunk, "pagination": {"totalCount": len(TRAVELS), "pageSize": size,
                                        "currentPage": page, "hasMore": (page+1)*size < len(TRAVELS)}})
        m = re.match(r"^/api/v1/travels/([^/]+)/media(/count)?$", u.path)
        if m:
            items = list(MEDIA.get(m.group(1), []))
            t = q.get("type", "all")
            if t == "image": items = [x for x in items if not is_video(x)]
            if t == "video": items = [x for x in items if is_video(x)]
            if m.group(2): return self.send_json(200, {"count": len(items)})
            s = q.get("sort", "created_desc")
            key = "takenAt" if s.startswith("taken") else "created"
            items.sort(key=lambda x: x.get(key) or "", reverse=s.endswith("desc"))
            page, size = int(q.get("page", 0)), int(q.get("size", 20))
            return self.send_json(200, items[page*size:(page+1)*size])
        self.send_json(404, {"error": "Not Found"})

    def do_POST(self):
        u = urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0) or 0)
        if u.path == "/ps/login":
            form = parse_qs(self.rfile.read(length).decode())
            if form.get("username", [""])[0] == "mockuser" and form.get("password", [""])[0].startswith("mock-pass"):
                return self.send_json(200, {"accessToken": issue(), "refreshToken": "refresh-1", "grantType": []})
            return self.send_json(401, {"error": "Unauthorized", "message": "Invalid username or password"})
        if u.path == "/login/ps/refresh":
            body = json.loads(self.rfile.read(length) or b"{}")
            log(f"refresh with {body.get('refreshToken')}")
            return self.send_json(200, {"accessToken": issue(), "refreshToken": "refresh-2"})
        if u.path == "/api/v1/travels":
            if not self.authed(): return
            body = json.loads(self.rfile.read(length) or b"{}")
            if not (body.get("title") or "").strip():
                return self.send_json(400, {"msg": "여행 제목은 필수입니다", "code": "VALIDATION"})
            tid = f"t-new-{uuid.uuid4().hex[:8]}"
            t = {"id": tid, "visibility": "PRIVATE", "status": "PLANNING", "tags": [], "coverImageUrl": None,
                 "members": [{"userId": ME, "role": "ADMIN", "nickname": "나", "joinedAt": "2026-10-05T10:00:00"}],
                 "memberCount": 1, "createdUser": ME, "created": "2026-10-05T10:00:00.5"}
            if not apply_travel_fields(t, body):
                return self.send_json(400, {"msg": "시작일은 종료일보다 늦을 수 없습니다", "code": "TRV_DATE"})
            TRAVELS.insert(0, t); MEDIA[tid] = []
            log(f"TRAVEL CREATE {tid} {json.dumps(body, ensure_ascii=False)}")
            return self.send_json(200, t)
        if u.path == "/api/v1/files":
            if not self.authed(): return
            raw = self.rfile.read(length)
            msg = BytesParser(policy=HTTP).parsebytes(
                f"Content-Type: {self.headers.get('Content-Type')}\r\n\r\n".encode() + raw)
            fields, file_part = {}, None
            for part in msg.iter_parts():
                name = part.get_param("name", header="content-disposition")
                if part.get_filename() is not None: file_part = part
                else: fields[name] = part.get_content().strip()
            key = fields.get("fileKey", "")
            ctype = file_part.get_content_type() if file_part else ""
            data = file_part.get_payload(decode=True) if file_part else b""
            log(f"FILE UPLOAD key={key} bytes={len(data)} content-type={ctype}")
            if FAIL_FILES: return self.send_json(400, None)
            if not SAFE_KEY.match(key) or ".." in key: return self.send_json(400, {"msg": "잘못된 파일 경로입니다"})
            if not ctype.startswith("image/") and not ctype.startswith("video/"):
                return self.send_json(400, {"msg": "지원하지 않는 파일 형식입니다"})
            name = key.replace("/", "_")
            with open(os.path.join(FILES, name), "wb") as f: f.write(data)
            return self.send_json(200, {"url": f"{HOST}/files/{name}"})
        m = re.match(r"^/api/v1/travels/([^/]+)/media/uploads$", u.path)
        if m:
            if not self.authed(): return
            travel_id = m.group(1)
            body = json.loads(self.rfile.read(length) or b"{}")
            if my_role(travel_id) in (None, "VIEWER"):
                return self.send_json(403, {"status": "FORBIDDEN", "msg": "여행 편집 권한이 없습니다", "code": "TRV_003"})
            size = int(body.get("fileSize") or 0)
            if size <= 0 or size > 5 * 1024 ** 3:
                return self.send_json(400, {"msg": "파일 크기는 최대 5GB 입니다", "code": "TRV_018"})
            up = {"id": f"u-{uuid.uuid4().hex[:10]}", "travelId": travel_id, "fileSize": size,
                  "contentType": (body.get("contentType") or "application/octet-stream").split(";")[0],
                  "request": body, "status": "PENDING", "urlVersion": 1, "media": None}
            if size > MULTIPART_THRESHOLD:
                up["method"] = "MULTIPART"; up["partSize"] = PART_SIZE
                up["partCount"] = (size + PART_SIZE - 1) // PART_SIZE
            else:
                up["method"] = "SINGLE"; up["partSize"] = size; up["partCount"] = 1
            UPLOADS[up["id"]] = up
            log(f"UPLOAD INIT {up['id']} {up['method']} size={size} parts={up['partCount']} request={body}")
            return self.send_json(200, upload_response(up))
        m = re.match(r"^/api/v1/travels/([^/]+)/media/uploads/([^/]+)/(parts|complete)$", u.path)
        if m:
            if not self.authed(): return
            up = UPLOADS.get(m.group(2))
            if not up or up["travelId"] != m.group(1):
                self.rfile.read(length)
                return self.send_json(404, {"msg": "업로드 세션을 찾을 수 없거나 만료되었습니다", "code": "TRV_019"})
            body = json.loads(self.rfile.read(length) or b"{}") if length else {}
            if m.group(3) == "parts":
                up["urlVersion"] += 1
                log(f"UPLOAD PARTS REFRESH {up['id']} numbers={body.get('partNumbers')} v={up['urlVersion']}")
                return self.send_json(200, upload_response(up, body.get("partNumbers") or None))
            # complete — 멱등: 이미 끝났으면 같은 미디어
            if up["media"]: return self.send_json(200, up["media"])
            have = [n for n in range(1, up["partCount"] + 1) if os.path.exists(os.path.join(PARTS_DIR, f"{up['id']}-{n}"))]
            if len(have) != up["partCount"]:
                log(f"UPLOAD COMPLETE {up['id']} incomplete {len(have)}/{up['partCount']}")
                return self.send_json(409, {"msg": "파일 업로드가 아직 끝나지 않았습니다", "code": "TRV_020"})
            req = up["request"]
            ext = os.path.splitext(req.get("fileName") or "")[1].lower() or ".bin"
            name = f"up-{uuid.uuid4().hex[:8]}{ext}"
            total = 0
            with open(os.path.join(FILES, name), "wb") as out:
                for n in range(1, up["partCount"] + 1):
                    pp = os.path.join(PARTS_DIR, f"{up['id']}-{n}")
                    with open(pp, "rb") as f: data = f.read(); out.write(data); total += len(data)
                    os.remove(pp)
            if total != up["fileSize"]:
                os.remove(os.path.join(FILES, name))
                return self.send_json(400, {"msg": "업로드된 파일 크기가 요청과 다릅니다", "code": "TRV_021"})
            with open(os.path.join(FILES, name), "rb") as f: head = f.read(4).hex()
            log(f"UPLOAD COMPLETE {up['id']} -> {name} bytes={total} head={head} type={up['contentType']}")
            media = {"id": name, "travelId": up["travelId"], "uploadUserId": ME, "originalFileName": req.get("fileName"),
                     "fileUrl": f"{HOST}/files/{name}", "thumbnailUrl": f"{HOST}/files/missing-thumb.jpg", "displayUrl": None,
                     "mimeType": up["contentType"], "fileSize": total, "width": req.get("width"), "height": req.get("height"),
                     "duration": req.get("duration"), "takenAt": req.get("takenAt"), "created": "2026-10-04T15:00:00.1"}
            up["media"] = media; up["status"] = "COMPLETED"
            MEDIA.setdefault(up["travelId"], []).append(media)
            return self.send_json(200, media)
        self.send_json(404, {"error": "Not Found"})

    def do_PUT(self):
        u = urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0) or 0)
        m = re.match(r"^/api/v1/travels/([^/]+)$", u.path)
        if m:
            if not self.authed(): return
            body = json.loads(self.rfile.read(length) or b"{}")
            t = find_travel(m.group(1))
            if not t: return self.send_json(404, {"msg": "여행을 찾을 수 없습니다"})
            if my_role(t["id"]) != "ADMIN": return self.send_json(403, {"msg": "여행 관리자만 할 수 있습니다"})
            before = dict(t)
            if not apply_travel_fields(t, body):
                t.clear(); t.update(before)
                return self.send_json(400, {"msg": "시작일은 종료일보다 늦을 수 없습니다", "code": "TRV_DATE"})
            log(f"TRAVEL UPDATE {t['id']} {json.dumps(body, ensure_ascii=False)}")
            return self.send_json(200, t)
        m = re.match(r"^/s3/([^/]+)/(\d+)$", u.path)
        if not m:
            self.rfile.read(length); return self.send_json(404, {"error": "Not Found"})
        up = UPLOADS.get(m.group(1)); n = int(m.group(2))
        v = int(parse_qs(u.query).get("v", ["1"])[0])
        if not up or n < 1 or n > up["partCount"]:
            self.rfile.read(length); return self.send_json(404, {"error": "NoSuchUpload"})
        if EXPIRE_FIRST and v < 2:
            # presigned URL 만료 흉내 — 앱이 /parts 로 재발급받아 다시 올려야 한다
            self.rfile.read(length)
            log(f"S3 PUT {up['id']}/{n} v={v} -> 403 (expired)")
            return self.send_json(403, {"error": "Request has expired"})
        expected = min(up["partSize"], up["fileSize"] - (n - 1) * up["partSize"])
        if length != expected:
            self.rfile.read(length)
            log(f"S3 PUT {up['id']}/{n} size mismatch {length} != {expected} -> 403")
            return self.send_json(403, {"error": "SignatureDoesNotMatch (content-length)"})
        ctype = self.headers.get("Content-Type")
        if SLOW_PUT: import time; time.sleep(SLOW_PUT)
        with open(os.path.join(PARTS_DIR, f"{up['id']}-{n}"), "wb") as out:
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(1 << 20, remaining))
                if not chunk: break
                out.write(chunk); remaining -= len(chunk)
        log(f"S3 PUT {up['id']}/{n} bytes={length} content-type={ctype}")
        self.send_json(200, None, {"ETag": f'"{uuid.uuid4().hex}"'})

    def do_DELETE(self):
        if not self.authed(): return
        path = urlparse(self.path).path
        m = re.match(r"^/api/v1/travels/([^/]+)/media/uploads/([^/]+)$", path)
        if m:
            up = UPLOADS.pop(m.group(2), None)
            if up:
                for n in range(1, up["partCount"] + 1):
                    try: os.remove(os.path.join(PARTS_DIR, f"{up['id']}-{n}"))
                    except FileNotFoundError: pass
                log(f"UPLOAD ABORT {up['id']}")
            return self.send_json(204)
        m = re.match(r"^/api/v1/travels/([^/]+)$", path)
        if m:
            t = find_travel(m.group(1))
            if not t: return self.send_json(404, {"msg": "여행을 찾을 수 없습니다"})
            if my_role(t["id"]) != "ADMIN": return self.send_json(403, {"msg": "여행 관리자만 할 수 있습니다"})
            TRAVELS.remove(t); MEDIA.pop(t["id"], None)
            log(f"TRAVEL DELETE {t['id']}")
            return self.send_json(204)
        m = re.match(r"^/api/v1/travels/([^/]+)/media/([^/]+)$", path)
        if not m: return self.send_json(404, {})
        items = MEDIA.get(m.group(1), [])
        item = next((x for x in items if x["id"] == m.group(2)), None)
        if not item: return self.send_json(404, {"msg": "미디어를 찾을 수 없습니다"})
        role = next((x["role"] for t in TRAVELS if t["id"] == m.group(1) for x in t["members"] if x["userId"] == ME), None)
        if item["uploadUserId"] != ME and role != "ADMIN":
            return self.send_json(403, {"msg": "삭제 권한이 없습니다"})
        items.remove(item)
        log(f"DELETED {item['id']}")
        self.send_json(204)

    def serve_file(self, name):
        path = os.path.join(FILES, os.path.basename(name))
        if not os.path.exists(path): return self.send_json(404, {"error": "no file"})
        size = os.path.getsize(path)
        ctype = "video/mp4" if path.endswith(".mp4") else ("image/png" if path.endswith(".png") else "image/jpeg")
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        if rng:
            a, b = rng.replace("bytes=", "").split("-")
            start = int(a) if a else 0
            end = int(b) if b else size - 1
            end = min(end, size - 1)
            self.send_response(206); self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        self.send_header("Content-Type", ctype); self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1)); self.end_headers()
        with open(path, "rb") as f:
            f.seek(start); remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(1 << 20, remaining))
                if not chunk: break
                try: self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError): return
                remaining -= len(chunk)

import socketserver
class Server(ThreadingHTTPServer):
    # HTTPServer.server_bind 의 getfqdn(역방향 DNS) 이 멈추는 경우가 있어 건너뛴다.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", PORT
Server(("127.0.0.1", PORT), H).serve_forever()
