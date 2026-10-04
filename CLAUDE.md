# Nadeliv iOS — 개발 가이드

SwiftUI 네이티브 iOS 앱. 백엔드는 웹과 공용인 nadeliv-backend 를 그대로 쓴다.
상위 폴더의 `../CLAUDE.md`(백엔드 API 규칙), `../DESIGN.md`(브랜드)를 함께 참고한다.

## 구조

```
Nadeliv/
├── App/            # 앱 진입점(NadelivApp, RootView, MainTabView), AppConfig
├── Core/
│   ├── Network/    # APIClient (Bearer 토큰, 401 → refresh 후 1회 재시도) — 파일 전송은 안 함
│   ├── Auth/       # AuthStore(@Observable, refresh 단일 실행), KeychainStore, 인증 모델
│   └── Image/      # ImageLoader(다운샘플 + 캐시), RemoteImage(후보 URL 순차 시도)
├── DesignSystem/   # Theme — 웹 homeTokens.ts 와 같은 다크 세이지-그린 토큰·projectPalette
└── Features/
    ├── Travel/
    │   ├── TravelModels.swift / TravelAPI.swift   # 여행·미디어 DTO, API 함수
    │   ├── List/     # 내 여행 목록, 커버(TravelThumb — 웹과 같은 id 해시 색)
    │   ├── Album/    # 앨범 그리드·필터·정렬·선택·삭제 (AlbumModel)
    │   ├── Viewer/   # 전체 화면 뷰어(display → 원본 순, 영상 스트리밍), 사진 앱 저장
    │   └── Upload/   # UploadManager(앱 전역 대기열·디스크 기록), BackgroundUploadSession(S3 PUT), UploadJobStore, HEIC→JPEG·메타데이터
    └── Profile/      # 계정 정보·로그아웃
Tools/MockBackend/  # UI 검증용 가짜 백엔드 (아래 "검증" 참고)
```

- Xcode 프로젝트는 폴더 동기화 그룹을 쓴다. `Nadeliv/` 아래에 파일을 추가하면 자동으로 빌드에 포함된다.
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
- 서버를 재시작하면 기존 액세스 토큰이 만료 처리돼 401 → refresh → 재시도 흐름을 확인할 수 있다.
- 요청 기록은 `Tools/MockBackend/requests.log` (UPLOAD INIT/S3 PUT/PARTS REFRESH/COMPLETE 로 업로드 흐름이 보인다).
- 가짜 서버는 256KB 초과면 멀티파트(128KB part) 로 응답해 작은 시뮬레이터 샘플로도 멀티파트를 탄다 (실제 백엔드는 64MB/16MB).
- 시뮬레이터 앱 컨테이너의 업로드 기록: `xcrun simctl get_app_container booted com.nadeliv.app data` → `Library/Application Support/uploads/`.
- 시뮬레이터 기기 언어가 한국어면 자동 입력이 한글 자모로 들어간다 → 테스트 시뮬레이터 키보드를 en_US 로 설정.

## 브랜치

작업은 `develop`. `production` 머지·푸시는 오너만 한다.
