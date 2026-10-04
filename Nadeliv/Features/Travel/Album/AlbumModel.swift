import Foundation
import Observation

/// 앨범 화면 상태: 필터·정렬·무한 스크롤·선택·삭제.
/// 웹 useTravelAlbumPage 와 같은 동작을 목표로 한다.
@Observable
final class AlbumModel {
    let travel: Travel
    let currentUserId: String?

    private(set) var items: [TravelMedia] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var counts: [MediaFilter: Int] = [:]
    var errorMessage: String?

    var filter: MediaFilter = .all
    var sort: MediaSort = .createdDesc
    var columns: Int = 3

    var isSelecting = false
    var selection: Set<String> = []
    private(set) var isDeleting = false

    private var page = 0
    private let pageSize = 60
    /// 필터를 빠르게 바꿀 때 이전 요청 결과가 덮어쓰지 않도록 세대 번호로 구분한다.
    private var generation = 0

    init(travel: Travel, currentUserId: String?) {
        self.travel = travel
        self.currentUserId = currentUserId
    }

    // MARK: - 권한 (서버도 같은 규칙으로 검사한다)

    var role: TravelRole? { travel.role(of: currentUserId) }
    /// 업로드: 멤버이면서 VIEWER 가 아닐 때
    var canEdit: Bool { role != nil && role != .viewer }

    /// 삭제: 본인이 올렸거나 ADMIN
    func canDelete(_ media: TravelMedia) -> Bool {
        guard canEdit else { return false }
        return role == .admin || (currentUserId != nil && media.uploadUserId == currentUserId)
    }

    var selectedItems: [TravelMedia] { items.filter { selection.contains($0.id) } }
    var canDeleteSelection: Bool { !selection.isEmpty && selectedItems.allSatisfy(canDelete) }

    // MARK: - 불러오기

    func reload(api: APIClient) async {
        generation += 1
        page = 0
        hasMore = true
        selection.removeAll()
        await loadPage(api: api, replacing: true)
        await refreshCounts(api: api)
    }

    func loadMoreIfNeeded(current media: TravelMedia, api: APIClient) async {
        guard hasMore, !isLoading else { return }
        // 끝에서 두 줄쯤 남았을 때 미리 다음 페이지를 부른다.
        guard let index = items.firstIndex(of: media), index >= items.count - columns * 2 else { return }
        await loadPage(api: api, replacing: false)
    }

    func loadMore(api: APIClient) async {
        guard hasMore, !isLoading else { return }
        await loadPage(api: api, replacing: false)
    }

    func refreshCounts(api: APIClient) async {
        let travelId = travel.id
        async let all = try? api.mediaCount(travelId: travelId, filter: .all)
        async let images = try? api.mediaCount(travelId: travelId, filter: .image)
        async let videos = try? api.mediaCount(travelId: travelId, filter: .video)
        let (a, i, v) = await (all, images, videos)
        if let a { counts[.all] = a }
        if let i { counts[.image] = i }
        if let v { counts[.video] = v }
    }

    private func loadPage(api: APIClient, replacing: Bool) async {
        if isLoading && !replacing { return }
        let currentGeneration = generation
        isLoading = true
        defer { if currentGeneration == generation { isLoading = false } }
        do {
            let result = try await api.media(
                travelId: travel.id, page: page, size: pageSize, sort: sort, filter: filter
            )
            guard currentGeneration == generation else { return }
            if replacing {
                items = result
            } else {
                let known = Set(items.map(\.id))
                items += result.filter { !known.contains($0.id) }
            }
            hasMore = result.count == pageSize
            page += 1
            errorMessage = nil
        } catch {
            guard currentGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 선택

    func toggleSelecting() {
        isSelecting.toggle()
        if !isSelecting { selection.removeAll() }
    }

    func toggle(_ media: TravelMedia) {
        if selection.contains(media.id) {
            selection.remove(media.id)
        } else {
            selection.insert(media.id)
        }
    }

    var allLoadedSelected: Bool { !items.isEmpty && selection.count == items.count }

    func toggleSelectAllLoaded() {
        selection = allLoadedSelected ? [] : Set(items.map(\.id))
    }

    // MARK: - 삭제

    /// - Returns: 실패한 개수
    @discardableResult
    func delete(ids: [String], api: APIClient) async -> Int {
        isDeleting = true
        defer { isDeleting = false }
        var failed = 0
        for id in ids {
            do {
                try await api.deleteMedia(travelId: travel.id, mediaId: id)
                remove(id: id)
            } catch {
                failed += 1
            }
        }
        selection.subtract(ids)
        if selection.isEmpty { isSelecting = false }
        await refreshCounts(api: api)
        return failed
    }

    private func remove(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: index)
        counts[.all] = max(0, (counts[.all] ?? 1) - 1)
        let kind: MediaFilter = removed.isVideo ? .video : .image
        counts[kind] = max(0, (counts[kind] ?? 1) - 1)
    }

    // MARK: - 업로드 반영

    /// 업로드 완료된 항목을 현재 목록에 반영한다.
    func didUpload(_ media: TravelMedia) {
        counts[.all, default: 0] += 1
        counts[media.isVideo ? .video : .image, default: 0] += 1
        let matchesFilter = filter == .all || (filter == .video) == media.isVideo
        guard matchesFilter, !items.contains(where: { $0.id == media.id }) else { return }
        switch sort {
        case .createdDesc: items.insert(media, at: 0)
        case .createdAsc: if !hasMore { items.append(media) }
        case .takenDesc, .takenAsc: break // 촬영 시각 위치는 서버 정렬에 맡긴다 (다음 새로고침 때 반영)
        }
    }
}
