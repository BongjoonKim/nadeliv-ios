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
