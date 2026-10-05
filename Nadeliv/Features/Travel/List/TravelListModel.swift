import Foundation
import Observation

@Observable
final class TravelListModel {
    private(set) var travels: [Travel] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    var errorMessage: String?

    private var page = 0
    private let pageSize = 20

    func reload(api: APIClient) async {
        page = 0
        hasMore = true
        await loadPage(api: api, replacing: true)
    }

    func loadMoreIfNeeded(current travel: Travel, api: APIClient) async {
        guard hasMore, !isLoading, travel.id == travels.last?.id else { return }
        await loadPage(api: api, replacing: false)
    }

    // MARK: - 만들기·수정·삭제 반영 (다시 불러오지 않고 목록만 고친다)

    func didCreate(_ travel: Travel) {
        travels.insert(travel, at: 0)
    }

    func didUpdate(_ travel: Travel) {
        guard let index = travels.firstIndex(where: { $0.id == travel.id }) else { return }
        travels[index] = travel
    }

    func didDelete(id: String) {
        travels.removeAll { $0.id == id }
    }

    private func loadPage(api: APIClient, replacing: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await api.myTravels(page: page, size: pageSize)
            travels = replacing ? response.travels : travels + response.travels
            hasMore = response.pagination?.hasMore ?? (response.travels.count == pageSize)
            page += 1
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
