# Nadeliv iOS — 개발 가이드

SwiftUI 네이티브 iOS 앱. 백엔드는 웹과 공용인 nadeliv-backend 를 그대로 쓴다.
상위 폴더의 `../CLAUDE.md`(백엔드 API 규칙), `../DESIGN.md`(브랜드)를 함께 참고한다.

## 구조

```
Nadeliv/
├── App/            # 앱 진입점(NadelivApp, RootView), AppConfig
├── Core/
│   ├── Network/    # APIClient (Bearer 토큰, 401 → refresh 후 1회 재시도)
│   └── Auth/       # AuthStore(@Observable), KeychainStore, 인증 모델
├── DesignSystem/   # Theme — 웹 homeTokens.ts 와 같은 다크 세이지-그린 토큰
└── Features/       # 화면별 폴더 (Login, Home, ...)
```

- Xcode 프로젝트는 폴더 동기화 그룹을 쓴다. `Nadeliv/` 아래에 파일을 추가하면 자동으로 빌드에 포함된다.
- `Config/Info.plist` 는 빌드 설정과 병합되는 부분 plist 다. 동기화 폴더 밖에 둬야 리소스로 중복 복사되지 않는다.

## 규칙

- **색·폰트는 `Theme` 토큰만 사용.** 화면 코드에 hex 직접 입력 금지.
- **API 호출은 `APIClient` 경유.** 화면에서 URLSession 직접 호출 금지 (웹의 useAuthEP 규칙과 같음).
- **토큰 저장**: access 토큰은 메모리, refresh 토큰은 Keychain.
- **동시성**: Swift 6, 기본 actor 격리 = MainActor.
- **로그인 API**: `POST /ps/login` 은 form-urlencoded(`username`, `password`)만 받는다. JSON 아님.
- **대용량 업로드**: 현재 백엔드는 multipart `POST /api/v1/files` 뿐. 대용량은 presigned URL API 를 백엔드에 추가한 뒤 background URLSession 으로 올린다.

## 빌드·검증

```bash
xcodebuild -project Nadeliv.xcodeproj -scheme Nadeliv -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
```

## 브랜치

작업은 `develop`. `production` 머지·푸시는 오너만 한다.
