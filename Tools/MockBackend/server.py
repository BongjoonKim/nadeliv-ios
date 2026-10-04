"""nadeliv 백엔드 응답 형식을 흉내 내는 iOS UI 검증용 가짜 서버.

로컬 백엔드는 원격(운영) MongoDB 에 붙어 있어 테스트 계정·업로드를 만들 수 없다.
이 서버로 로그인·여행 목록·앨범·업로드·삭제·토큰 만료(401→refresh) 흐름을 검증한다.

  ./setup.sh                     # 샘플 파일 생성 (최초 1회)
  python3 server.py 3999         # 실행
  xcodebuild ... BACKEND_URL=http://localhost:3999 build

테스트 계정: mockuser / mock-pass (서버 재시작 시 기존 액세스 토큰은 만료 처리됨)
"""
import json, os, re, sys, uuid
from email.parser import BytesParser
from email.policy import default as email_policy
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
            "mimeType": "image/jpeg", "fileSize": os.path.getsize(os.path.join(FILES, f"p{i}.jpg")),
            "width": 2400, "height": 2400, "duration": None,
            "takenAt": f"2026-09-2{i % 4}T1{i % 10}:0{i % 6}:00", "created": f"2026-09-24T09:{i:02d}:00.5"})
    items.append({"id": "v1", "travelId": "t-jeju-001", "uploadUserId": ME, "originalFileName": "IMG_5001.MP4",
        "fileUrl": f"{HOST}/files/v1.mp4", "thumbnailUrl": f"{HOST}/files/v1-thumb.jpg", "mimeType": "video/mp4",
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
        m = re.match(r"^/api/v1/travels/([^/]+)/media$", u.path)
        if m:
            if not self.authed(): return
            travel_id = m.group(1)
            role = next((x["role"] for t in TRAVELS if t["id"] == travel_id for x in t["members"] if x["userId"] == ME), None)
            if role in (None, "VIEWER"):
                self.rfile.read(length); return self.send_json(403, {"status": "FORBIDDEN", "msg": "여행 편집 권한이 없습니다", "code": "TRV_003"})
            raw = self.rfile.read(length)
            msg = BytesParser(policy=email_policy).parsebytes(
                b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + raw)
            parts = {p.get_param("name", header="content-disposition"): p for p in msg.iter_parts()}
            fpart = parts["file"]
            class F: pass
            f = F(); f.filename = fpart.get_filename(); f.type = fpart.get_content_type()
            data = fpart.get_payload(decode=True)
            req = json.loads(parts["request"].get_payload(decode=True)) if "request" in parts else {}
            log(f"request part content-type={parts['request'].get_content_type() if 'request' in parts else None}")
            ext = os.path.splitext(f.filename)[1].lower() or ".bin"
            name = f"up-{uuid.uuid4().hex[:8]}{ext}"
            with open(os.path.join(FILES, name), "wb") as out: out.write(data)
            log(f"UPLOAD filename={f.filename} type={f.type} bytes={len(data)} head={data[:4].hex()} request={req}")
            media = {"id": name, "travelId": travel_id, "uploadUserId": ME, "originalFileName": f.filename,
                     "fileUrl": f"{HOST}/files/{name}", "thumbnailUrl": f"{HOST}/files/missing-thumb.jpg",
                     "mimeType": f.type, "fileSize": len(data), "width": req.get("width"), "height": req.get("height"),
                     "duration": req.get("duration"), "takenAt": req.get("takenAt"), "created": "2026-10-04T15:00:00.1"}
            MEDIA.setdefault(travel_id, []).append(media)
            return self.send_json(200, media)
        self.send_json(404, {"error": "Not Found"})

    def do_DELETE(self):
        if not self.authed(): return
        m = re.match(r"^/api/v1/travels/([^/]+)/media/([^/]+)$", urlparse(self.path).path)
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
