# Nadeliv iOS

나들이브(Nadeliv) iOS 앱. SwiftUI 네이티브, iOS 17 이상.

웹([nadeliv-frontend](https://github.com/BongjoonKim/nadeliv-frontend))과 같은 백엔드([nadeliv-backend](https://github.com/BongjoonKim/nadeliv-backend))를 사용한다.

## 실행

1. 로컬 백엔드를 `localhost:3003` 에서 실행한다.
2. `Nadeliv.xcodeproj` 를 Xcode 로 열고 iPhone 시뮬레이터에서 실행한다.

| 빌드 구성 | 백엔드 |
|-----------|--------|
| Debug | `http://localhost:3003` |
| Release | `https://api.nadeliv.com` |

백엔드 주소는 빌드 설정 `BACKEND_URL` 에서 바꾼다.

## 브랜치

- `develop`: 모든 작업 브랜치
- `production`: 운영 배포 브랜치. 오너가 직접 머지한다.
