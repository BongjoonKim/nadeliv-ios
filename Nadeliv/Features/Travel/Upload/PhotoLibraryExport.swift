import Foundation
import Photos
import UniformTypeIdentifiers

/// 사진 보관함 항목(PHAsset)을 앱 임시 폴더의 파일로 꺼낸다.
/// PhotosPicker 경로의 PickedFile 과 같은 자리에 같은 이름 규칙("UUID-원본이름")으로 두어 UploadPreparer 가 똑같이 처리한다.
nonisolated enum PhotoLibraryExport {
    enum ExportError: LocalizedError {
        case notFound
        case noResource
        var errorDescription: String? {
            switch self {
            case .notFound: "사진 보관함에서 항목을 찾지 못했습니다. 삭제됐거나 접근이 제한된 사진일 수 있습니다."
            case .noResource: "사진 보관함에서 원본 파일을 찾지 못했습니다."
            }
        }
    }

    /// 편집본이 있으면 편집본(fullSize*), 없으면 원본 — PhotosPicker 의 `.current` 와 같은 선택.
    /// iCloud 에만 있는 원본은 받아온다.
    static func export(localIdentifier: String) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw ExportError.notFound
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]
        guard let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } }).first else {
            throw ExportError.noResource
        }

        let dir = FileManager.default.temporaryDirectory.appending(path: "uploads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = resource.originalFilename
        if (name as NSString).pathExtension.isEmpty,
           let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension {
            name += "." + ext
        }
        let target = dir.appending(path: "\(UUID().uuidString)-\(name)")

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return target
    }
}
