import Foundation
import Observation
import Photos

/// 자체 사진 선택기 상태: 권한·앨범·항목 목록·선택·"이미 올린 사진" 판정.
///
/// 올린 사진 판정은 두 신호를 합친다.
/// 1. 이 기기에서 올린 기록 (UploadedAssetRegistry, localIdentifier 로 정확히 일치)
/// 2. 서버 앨범의 미디어와 촬영 시각+가로세로 크기 대조 — 다른 기기·웹에서 올린 사진용.
///    서버 takenAt 은 시간대 없는 카메라 로컬 시각이고 PHAsset.creationDate 는 절대 시각이라,
///    실제 존재하는 시간대 오프셋(-12h…+14h, 15분 단위) 중 하나로 맞으면 같은 사진으로 본다.
@Observable
final class PhotoPickerModel {
    enum Access { case checking, authorized, limited, denied }

    struct Collection: Identifiable, Hashable {
        let id: String
        let title: String
        /// nil = 전체(최근 항목)
        let assetCollection: PHAssetCollection?
    }

    static let maxSelection = 100

    let travelId: String
    private(set) var access: Access = .checking
    private(set) var collections: [Collection] = []
    var currentCollection: Collection {
        didSet { if currentCollection != oldValue { fetchAssets() } }
    }

    /// 현재 앨범의 전체 항목 (촬영 시각 오름차순 — 사진 앱처럼 아래가 최신)
    private(set) var assets: [PHAsset] = []
    /// 화면에 보이는 항목 (올린 사진 숨김 반영)
    private(set) var visibleAssets: [PHAsset] = []
    /// 선택 순서 (localIdentifier)
    private(set) var selection: [String] = []
    var hideUploaded = false {
        didSet { refreshVisible() }
    }
    /// 잠깐 보여 줄 안내 (선택 한도 등)
    var notice: String?

    private(set) var isLoadingServer = false
    private(set) var uploadedIds: Set<String> = []
    private(set) var uploadedCount = 0

    private var registryIds: Set<String> = []
    /// 서버 미디어의 촬영 시각(로컬 문자열을 UTC 로 읽은 epoch 초), 크기별. 크기 정보가 없는 미디어는 "" 키.
    private var serverEpochsByDims: [String: Set<Int>] = [:]
    private var observer: PhotoLibraryObserver?

    init(travelId: String) {
        self.travelId = travelId
        self.currentCollection = Collection(id: "all", title: "최근 항목", assetCollection: nil)
    }

    // MARK: - 불러오기

    func load() async {
        let status = await PhotoLibrary.requestAccess()
        switch status {
        case .authorized: access = .authorized
        case .limited: access = .limited
        default:
            access = .denied
            return
        }
        registryIds = UploadedAssetRegistry.shared.assetIds(for: travelId)
        loadCollections()
        fetchAssets()
        if observer == nil {
            observer = PhotoLibraryObserver { [weak self] in
                Task { @MainActor in self?.libraryDidChange() }
            }
        }
    }

    private func libraryDidChange() {
        access = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited ? .limited : .authorized
        loadCollections()
        fetchAssets()
    }

    private func loadCollections() {
        var list = [Collection(id: "all", title: "최근 항목", assetCollection: nil)]
        let smart: [(PHAssetCollectionSubtype, String)] = [
            (.smartAlbumFavorites, "즐겨찾는 항목"),
            (.smartAlbumVideos, "동영상"),
        ]
        for (subtype, title) in smart {
            if let collection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject {
                list.append(Collection(id: collection.localIdentifier, title: title, assetCollection: collection))
            }
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        for album in albums.objects(at: IndexSet(0..<albums.count)) {
            list.append(Collection(id: album.localIdentifier, title: album.localizedTitle ?? "앨범", assetCollection: album))
        }
        collections = list
        if !list.contains(currentCollection) { currentCollection = list[0] }
    }

    private func fetchAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        let result: PHFetchResult<PHAsset> = if let collection = currentCollection.assetCollection {
            PHAsset.fetchAssets(in: collection, options: options)
        } else {
            PHAsset.fetchAssets(with: options)
        }
        assets = result.objects(at: IndexSet(0..<result.count))
        let present = Set(assets.map(\.localIdentifier))
        selection.removeAll { !present.contains($0) }
        refreshUploaded()
    }

    /// 서버 앨범의 미디어를 전부 읽어 촬영 시각+크기 키를 만든다 (다른 기기·웹에서 올린 사진 대조용).
    func loadServerMedia(api: APIClient) async {
        isLoadingServer = true
        defer { isLoadingServer = false }
        var epochs: [String: Set<Int>] = [:]
        let pageSize = 200
        var page = 0
        while page < 50 {
            guard let result = try? await api.media(
                travelId: travelId, page: page, size: pageSize, sort: .createdDesc, filter: .all
            ) else { break }
            for media in result {
                guard let takenAt = media.takenAt, let epoch = Self.localEpoch(takenAt) else { continue }
                let dims: String = if let width = media.width, let height = media.height, width > 0, height > 0 {
                    Self.dimsKey(width, height)
                } else {
                    ""
                }
                epochs[dims, default: []].insert(epoch)
            }
            if result.count < pageSize { break }
            page += 1
        }
        serverEpochsByDims = epochs
        refreshUploaded()
    }

    // MARK: - 올린 사진 판정

    private static func dimsKey(_ width: Int, _ height: Int) -> String {
        "\(min(width, height))x\(max(width, height))"
    }

    /// "2026-10-03T19:35:49" 를 UTC 인 것처럼 읽은 epoch 초 (시간대는 대조할 때 더한다)
    private static func localEpoch(_ text: String) -> Int? {
        guard text.count >= 19, let date = utcParser.date(from: String(text.prefix(19))) else { return nil }
        return Int(date.timeIntervalSince1970.rounded(.down))
    }

    private static let utcParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// 실제 쓰이는 시간대 오프셋 범위 (-12:00 … +14:00, 15분 단위)
    private static let timeZoneOffsets: [Int] = Array(stride(from: -12 * 3600, through: 14 * 3600, by: 900))

    private func matchesServer(_ asset: PHAsset) -> Bool {
        guard !serverEpochsByDims.isEmpty, let date = asset.creationDate else { return false }
        let sized = serverEpochsByDims[Self.dimsKey(asset.pixelWidth, asset.pixelHeight)]
        let unsized = serverEpochsByDims[""]
        guard sized != nil || unsized != nil else { return false }
        let base = Int(date.timeIntervalSince1970.rounded(.down))
        for offset in Self.timeZoneOffsets {
            let local = base + offset
            if sized?.contains(local) == true || unsized?.contains(local) == true { return true }
        }
        return false
    }

    private func refreshUploaded() {
        var ids: Set<String> = []
        for asset in assets where registryIds.contains(asset.localIdentifier) || matchesServer(asset) {
            ids.insert(asset.localIdentifier)
        }
        uploadedIds = ids
        uploadedCount = ids.count
        refreshVisible()
    }

    private func refreshVisible() {
        visibleAssets = hideUploaded ? assets.filter { !uploadedIds.contains($0.localIdentifier) } : assets
    }

    /// 방금 완료된 업로드를 표시에 반영한다 (선택기를 띄운 채 업로드가 끝났을 때)
    func refreshRegistry() {
        let fresh = UploadedAssetRegistry.shared.assetIds(for: travelId)
        guard fresh != registryIds else { return }
        registryIds = fresh
        refreshUploaded()
    }

    func isUploaded(_ asset: PHAsset) -> Bool { uploadedIds.contains(asset.localIdentifier) }

    /// 화면에 보이는 항목 중 마지막으로 올린 사진 (여기로 스크롤하면 그 다음 사진이 바로 보인다)
    var lastUploadedId: String? {
        visibleAssets.last { uploadedIds.contains($0.localIdentifier) }?.localIdentifier
    }

    // MARK: - 선택

    func selectionIndex(of asset: PHAsset) -> Int? {
        selection.firstIndex(of: asset.localIdentifier).map { $0 + 1 }
    }

    func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if let index = selection.firstIndex(of: id) {
            selection.remove(at: index)
        } else if selection.count >= Self.maxSelection {
            notice = "한 번에 \(Self.maxSelection)개까지 고를 수 있어요."
        } else {
            selection.append(id)
        }
    }

    /// 선택 중 이미 올린 사진의 개수
    var selectedUploadedCount: Int {
        selection.filter { uploadedIds.contains($0) }.count
    }

    func selectionExcludingUploaded() -> [String] {
        selection.filter { !uploadedIds.contains($0) }
    }
}
