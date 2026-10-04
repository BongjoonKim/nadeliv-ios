import Foundation
import Photos

/// 앨범 미디어를 기기 사진 앱에 저장한다. (추가 전용 권한만 요청)
enum PhotoSaver {
    nonisolated enum SaveError: LocalizedError {
        case denied
        case download
        var errorDescription: String? {
            switch self {
            case .denied: "사진 보관함 접근이 허용되지 않았습니다. 설정 앱에서 권한을 켜 주세요."
            case .download: "파일을 내려받지 못했습니다."
            }
        }
    }

    /// - Returns: 저장에 성공한 개수
    static func save(_ items: [TravelMedia]) async throws -> Int {
        let targets = items.compactMap { item in item.originalURL.map { Target(url: $0, isVideo: item.isVideo) } }
        return try await Worker.save(targets)
    }

    nonisolated struct Target: Sendable {
        let url: URL
        let isVideo: Bool
    }

    /// PHPhotoLibrary 는 변경 블록을 백그라운드 큐에서 실행한다.
    /// 메인 액터에 묶인 클로저를 넘기면 Swift 6 런타임 검사로 앱이 종료되므로, 이 부분은 격리하지 않는다.
    private nonisolated enum Worker {
        static func save(_ targets: [Target]) async throws -> Int {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { throw SaveError.denied }

            var saved = 0
            for target in targets {
                let local = try await download(target.url)
                defer { try? FileManager.default.removeItem(at: local) }
                let isVideo = target.isVideo
                try await PHPhotoLibrary.shared().performChanges {
                    if isVideo {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: local)
                    } else {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: local)
                    }
                }
                saved += 1
            }
            return saved
        }

        private static func download(_ url: URL) async throws -> URL {
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw SaveError.download
            }
            // 사진 앱이 형식을 알아보도록 원래 확장자를 붙인다.
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let target = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
            try FileManager.default.moveItem(at: temp, to: target)
            return target
        }
    }
}
