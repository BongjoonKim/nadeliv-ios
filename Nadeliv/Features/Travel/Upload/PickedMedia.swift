import CoreTransferable
import UniformTypeIdentifiers

/// 사진 선택기에서 받은 원본 파일을 앱 임시 폴더로 복사해 둔 것.
/// 영상도 메모리에 올리지 않고 파일 경로로만 다룬다.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedFile(url: try copyToTemp(received.file))
        }
        FileRepresentation(importedContentType: .image) { received in
            PickedFile(url: try copyToTemp(received.file))
        }
    }

    nonisolated static func copyToTemp(_ source: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "uploads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: "\(UUID().uuidString)-\(source.lastPathComponent)")
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }
}
