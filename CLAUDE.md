# Nadeliv iOS — 개발 가이드

SwiftUI 네이티브 iOS 앱. 백엔드는 웹과 공용인 nadeliv-backend 를 그대로 쓴다.
상위 폴더의 `../CLAUDE.md`(백엔드 API 규칙), `../DESIGN.md`(브랜드)를 함께 참고한다.

## 구조

```
Nadeliv/
├── App/            # 앱 진입점(NadelivApp, RootView, MainTabView), AppConfig
├── Core/
│   ├── Network/    # APIClient (Bearer 토큰, 401 → refresh 후 1회 재시도) — 큰 파일은 안 보냄(커버 사진 multipart 만)
│   ├── Auth/       # AuthStore(@Observable, refresh 단일 실행), KeychainStore, 인증 모델
│   └── Image/      # ImageLoader(다운샘플 + 캐시), RemoteImage(후보 URL 순차 시도)
├── DesignSystem/   # Theme — 웹 homeTokens.ts 와 같은 다크 세이지-그린 토큰·projectPalette
└── Features/
    ├── Travel/
    │   ├── TravelModels.swift / TravelAPI.swift   # 여행·미디어 DTO, API 함수
    │   ├── List/     # 내 여행 목록(+ 로 만들기), 커버(TravelThumb — 웹과 같은 id 해시 색)
    │   ├── Form/     # 여행 만들기·설정(수정·삭제) 시트 (TravelFormModel/View), 커버 사진 1600px JPEG
    │   ├── Album/    # 앨범 그리드·필터·정렬·선택·삭제 (AlbumModel)
    │   ├── Viewer/   # 전체 화면 뷰어(display → 원본 순, 영상 스트리밍), 사진 앱 저장
    │   └── Upload/   # UploadManager(앱 전역 대기열·디스크 기록), BackgroundUploadSession(S3 PUT), UploadJobStore, HEIC→JPEG·메타데이터
    └── Profile/      # 내 정보·프로필 편집(이름·생일·사진)·비밀번호 변경·로그아웃·계정 삭제 (ProfileAPI)
Tools/MockBackend/  # UI 검증용 가짜 백엔드 (아래 "검증" 참고)
Tools/IconRender/   # 앱 아이콘(Nv 겹친 모노그램) 렌더 스크립트 — 아이콘을 고칠 때 여기서 다시 그린다
```

- Xcode 프로젝트는 폴더 동기화 그룹을 쓴다. `Nadeliv/` 아래에 파일을 추가하면 자동으로 빌드에 포함된다.
- 실행 화면은 `Config/Info.plist` 의 `UILaunchScreen` → 색 에셋 `LaunchBackground`(= Theme.Color.bg) 만 깐다. 자동 생성(`UILaunchScreen_Generation`)은 흰 화면이라 쓰지 않는다.
- `Config/Info.plist` 는 빌드 설정과 병합되는 부분 plist 다. 동기화 폴더 밖에 둬야 리소스로 중복 복사되지 않는다.

## 규칙

- **색·폰트는 `Theme` 토큰만 사용.** 화면 코드에 hex 직접 입력 금지.
- **API 호출은 `APIClient` 경유.** 화면에서 URLSession 직접 호출 금지 (웹의 useAuthEP 규칙과 같음).
- **토큰 저장**: access 토큰은 메모리, refresh 토큰은 Keychain.
- **동시성**: Swift 6, 기본 actor 격리 = MainActor.
- **로그인 API**: `POST /ps/login` 은 form-urlencoded(`username`, `password`)만 받는다. JSON 아님.
- **동시성 주의**: 프레임워크가 백그라운드 큐에서 부르는 클로저(PHPhotoLibrary.performChanges, URLSession delegate 등)는 `nonisolated` 타입 안에서 만든다. 메인 액터 클로저를 넘기면 런타임 검사로 앱이 종료된다.
- **그리드 이미지**: fill 로 넘치는 이미지는 `.allowsHitTesting(false)` — 안 하면 옆 칸 터치를 가로챈다.
- **앨범 권한**: 업로드 = 멤버이면서 VIEWER 아님, 삭제 = 본인 업로드 또는 ADMIN (서버와 같은 규칙). 멤버 userId 는 로그인 아이디.
- **에러 문구**: 업무 에러는 응답의 `msg`, 인증 필터 에러는 `message` 필드 (ServerErrorBody.displayMessage).
- **업로드**: presigned 직접 업로드. `POST /media/uploads`(init) → part 파일을 **background URLSession** 으로 S3 에 PUT → `POST .../complete`. 앱이 백그라운드로 가거나 종료돼도 전송이 이어지고, `AppDelegate.handleEventsForBackgroundURLSession` 으로 깨어나 complete 까지 마친다.
  - 작업 기록은 `Application Support/uploads/jobs.json`, part 파일은 `uploads/{jobId}/` (멀티파트는 원본을 part 파일로 쪼갠 뒤 원본 삭제). 사진 선택기 항목은 메모리에만 있어 파일을 만들기 전에 앱이 죽으면 그 작업은 실패 처리된다.
  - part PUT 이 403 이면 URL 만료 → 300ms 동안 모아 `/parts` 로 재발급 후 그 part 만 다시 올린다. 그 외 실패는 같은 URL 로 최대 3회 재시도. complete 실패는 "다시 시도" 에서 complete 만 다시 부른다.
  - SINGLE PUT 만 `Content-Type` 을 보낸다 (서명에 포함). 멀티파트 part 는 URLSession 기본값(octet-stream)이 붙지만 서명 대상이 아니라 무방하다.
  - HEIC 는 여전히 앱에서 JPEG 으로 바꿔 올린다 (웹은 HEIC 원본 그대로 올리고 Lambda 가 display JPEG 를 만든다).
- **여행 만들기·설정**: 만들기 = `POST /api/v1/travels`(만든 사람이 ADMIN). 설정(수정·삭제) = ADMIN 만 (앨범 화면 톱니바퀴, 서버도 검사).
  - 수정은 `PUT` 에 **바꾼 필드만** 보낸다. 서버는 null 을 "변경 없음"으로 봐서 지우려면 빈 문자열·빈 배열을 보낸다 (커버 빼기 = `coverImageUrl: ""`). **날짜는 지울 수 없다** → 이미 날짜가 있으면 토글을 막는다.
  - 커버 사진은 긴 변 1600px JPEG 로 줄여 `POST /api/v1/files`(multipart, fileKey `travel/{id}/cover-{uuid}.jpg`)로 올리고 받은 URL 을 PUT. 고른 즉시가 아니라 저장할 때 올린다. 만들기는 여행을 만든 뒤 그 id 로 올린다 (커버만 실패하면 여행은 남기고 경고).
  - 날짜는 서버 LocalDate(서울) 기준이라 DatePicker 도 서울 달력·시간대로 띄운다.
  - dashboardItems 는 보내지 않는다 (비어 있으면 웹이 기본 구성을 쓴다).
- **계정(프로필 탭)**: `GET·PUT /api/v1/user/profile`, `PUT /api/v1/user/password`, `DELETE /api/v1/user/account`(본문 `{password}` — `APIClient.deleteJSON`).
  - 프로필 수정도 **바꾼 필드만** 보낸다. 사진 빼기 = `src: ""`. **생일은 지울 수 없다** → 이미 있으면 토글을 막는다. 생일은 시간대 없는 LocalDateTime 이라 UTC 달력으로 다룬다 (`ProfileDate`).
  - 프로필 사진은 긴 변 512px JPEG 로 `POST /api/v1/files`(fileKey `profile/{userId}/avatar-{uuid}.jpg`), 저장할 때 올린다. 저장 후 `AuthStore.reloadCurrentUser()` 로 `/users/me` 를 다시 읽는다.
  - 이메일은 앱에서 바꾸지 않는다 (백엔드가 인증 없이 바꾸는 구조라서).
  - 비밀번호 변경·탈퇴의 400 은 비밀번호 불일치(USER_004)뿐이다 → `APIError.isPasswordMismatch` 로 한국어 문구를 보여 준다.
  - 탈퇴(App Store 5.1.1(v)): 백엔드가 개인정보(이름·이메일·생일·사진·팔로우·북마크·여행/채널 닉네임)를 지우고 비활성화한다. 글·댓글·여행은 "Deleted user" 로 남고 userId 는 유지된다. 이후 refresh(403)·기존 access 토큰 모두 거절 → 앱은 성공 즉시 `signOut()`.
- **뷰어 이미지**: `TravelMedia.viewerImageURLs` = displayUrl(2048px JPEG, 3단계 이후 업로드분) → 원본. display 객체가 없으면 ImageLoader 가 nil 을 돌려줘 원본으로 넘어간다.

## 빌드·검증

```bash
xcodebuild -project Nadeliv.xcodeproj -scheme Nadeliv -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
```

로컬 백엔드는 원격(운영) MongoDB 에 붙어 있다. **테스트 계정 생성·테스트 업로드·삭제를 로컬 백엔드로 하지 말 것.**
화면 검증은 가짜 백엔드로 한다.

```bash
Tools/MockBackend/setup.sh                      # 샘플 사진·영상 생성 (최초 1회)
python3 Tools/MockBackend/server.py 3999        # 가짜 백엔드 실행
MOCK_EXPIRE_FIRST=1 python3 Tools/MockBackend/server.py 3999   # part URL 만료(403→재발급) 흐름 검증용
xcodebuild ... BACKEND_URL=http://localhost:3999 build   # 이 빌드를 시뮬레이터에 설치
```

- 테스트 계정 `mockuser` / `mock-pass`. 여행 3개(ADMIN·USER·VIEWER 역할), 사진 14장·영상 1개.
- 프로필 조회·수정, 비밀번호 변경, 탈퇴도 흉내 낸다 (PROFILE UPDATE / PASSWORD CHANGE / ACCOUNT DELETE). 탈퇴하면 로그인·refresh 가 거절되니 서버를 재시작해 되돌린다 (비밀번호도 mock-pass 로 돌아감).
- 여행 만들기·수정·삭제와 커버 업로드(`/api/v1/files`)도 흉내 낸다 (요청 기록 TRAVEL CREATE/UPDATE/DELETE, FILE UPLOAD). `MOCK_FAIL_FILES=1` 이면 파일 업로드가 400 → "커버만 실패" 경고 흐름 검증용.
- 시뮬레이터 자동 입력으로 시스템 Toggle 을 켤 때는 tap 이 아니라 짧은 swipe 를 쓴다 (tap 은 반응하지 않는다).
- 서버를 재시작하면 기존 액세스 토큰이 만료 처리돼 401 → refresh → 재시도 흐름을 확인할 수 있다.
- 요청 기록은 `Tools/MockBackend/requests.log` (UPLOAD INIT/S3 PUT/PARTS REFRESH/COMPLETE 로 업로드 흐름이 보인다).
- 가짜 서버는 256KB 초과면 멀티파트(128KB part) 로 응답해 작은 시뮬레이터 샘플로도 멀티파트를 탄다 (실제 백엔드는 64MB/16MB).
- 시뮬레이터 앱 컨테이너의 업로드 기록: `xcrun simctl get_app_container booted com.nadeliv.app data` → `Library/Application Support/uploads/`.
- 시뮬레이터 기기 언어가 한국어면 자동 입력이 한글 자모로 들어간다 → 테스트 시뮬레이터 키보드를 en_US 로 설정.

## TestFlight 배포

팀에 등록된 기기가 없어 Automatic 서명 archive 는 "no devices" 로 실패한다 → 서명 없이 archive 하고 export 에서 App Store 배포 서명(클라우드 관리 인증서)을 한다.

```bash
# 1) project.pbxproj 의 CURRENT_PROJECT_VERSION 을 올린다 (Debug·Release 둘 다). 같은 번호는 업로드 거절.
xcodebuild -project Nadeliv.xcodeproj -scheme Nadeliv -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Nadeliv.xcarchive CODE_SIGNING_ALLOWED=NO archive
# 2) ExportOptions: method=app-store-connect, destination=upload, teamID=4VCQ777SL9, signingStyle=automatic
xcodebuild -exportArchive -archivePath build/Nadeliv.xcarchive -exportPath build/upload \
  -exportOptionsPlist build/ExportOptions-upload.plist -allowProvisioningUpdates
```

- 업로드 인증은 Xcode 에 로그인된 Apple ID 를 쓴다. 처리(10~30분) 후 내부 테스팅 그룹에 자동 배포된다.
- 테스터는 **내부 테스팅** 그룹으로만 추가한다. 외부 그룹·빌드 화면의 "개인 테스터"는 베타 심사(데모 계정 필요)로 넘어간다.
- Release 빌드는 운영 백엔드(`api.nadeliv.com`)에 붙는다. 실기기 테스트 업로드는 오너 여행 하나에서 하고 지운다.

## 브랜치

작업은 `develop`. `production` 머지·푸시는 오너만 한다.
