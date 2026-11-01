import Foundation
import Observation

/// 이 기기에서 올린 사진 보관함 항목의 기록 (여행별 localIdentifier → mediaId).
/// 자체 사진 선택기(PhotoPickerView)가 "이미 올린 사진" 표시에 쓴다.
/// 다른 기기·웹에서 올린 것은 여기 없으므로 촬영 시각+크기로 따로 대조한다 (PhotoPickerModel).
@Observable
final class UploadedAssetRegistry {
    static let shared = UploadedAssetRegistry()

    /// travelId → (assetId → mediaId)
    private(set) var entries: [String: [String: String]]

    private static let fileURL = UploadJobStore.directory.appending(path: "uploaded-assets.json")

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func assetIds(for travelId: String) -> Set<String> {
        Set((entries[travelId] ?? [:]).keys)
    }

    func record(assetId: String, mediaId: String, travelId: String) {
        entries[travelId, default: [:]][assetId] = mediaId
        persist()
    }

    /// 앨범에서 미디어를 지우면 기록도 지워 같은 사진을 다시 올릴 수 있게 한다.
    func remove(mediaId: String, travelId: String) {
        guard let map = entries[travelId] else { return }
        let kept = map.filter { $0.value != mediaId }
        guard kept.count != map.count else { return }
        entries[travelId] = kept.isEmpty ? nil : kept
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
