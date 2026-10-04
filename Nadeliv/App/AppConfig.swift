import Foundation

/// 빌드 구성별 설정. 값은 Config/Info.plist 의 BackendURL (← 빌드 설정 BACKEND_URL) 에서 읽는다.
enum AppConfig {
    static let backendURL: URL = {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "BackendURL") as? String,
            let url = URL(string: raw)
        else {
            fatalError("Info.plist 에 BackendURL 이 없습니다. 빌드 설정 BACKEND_URL 을 확인하세요.")
        }
        return url
    }()
}
