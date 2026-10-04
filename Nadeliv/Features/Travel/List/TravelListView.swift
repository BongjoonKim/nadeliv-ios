import SwiftUI

/// 여행 탭 첫 화면: 내 여행 목록. 여행을 누르면 앨범으로 바로 들어간다.
struct TravelListView: View {
    @Environment(AuthStore.self) private var auth
    @State private var model = TravelListModel()

    var body: some View {
        NavigationStack {
            content
                .background(Theme.Color.bg)
                .navigationTitle("여행")
                .toolbarBackground(Theme.Color.bg, for: .navigationBar)
                .navigationDestination(for: Travel.self) { travel in
                    AlbumView(travel: travel)
                }
        }
        .task { if model.travels.isEmpty { await model.reload(api: auth.api) } }
    }

    @ViewBuilder
    private var content: some View {
        if model.travels.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.travels) { travel in
                        NavigationLink(value: travel) {
                            TravelCard(travel: travel)
                        }
                        .buttonStyle(.plain)
                        .task { await model.loadMoreIfNeeded(current: travel, api: auth.api) }
                    }
                    if model.isLoading { ProgressView().padding() }
                }
                .padding(16)
            }
            .refreshable { await model.reload(api: auth.api) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(model.errorMessage == nil ? "아직 여행이 없어요" : "불러오지 못했어요",
                      systemImage: model.errorMessage == nil ? "suitcase" : "wifi.exclamationmark")
            } description: {
                Text(model.errorMessage ?? "웹에서 여행 프로젝트를 만들면 여기에 나타납니다.")
            } actions: {
                Button("다시 시도") { Task { await model.reload(api: auth.api) } }
            }
            .foregroundStyle(Theme.Color.textSoft)
        }
    }
}

private struct TravelCard: View {
    let travel: Travel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TravelThumb(travel: travel)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text(travel.displayTitle)
                    .font(Theme.Font.serif(20))
                    .foregroundStyle(Theme.Color.text)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if let dates = travel.dateRangeText {
                        Label(dates, systemImage: "calendar")
                    }
                    if let destination = travel.destination, !destination.isEmpty {
                        Label(destination, systemImage: "mappin.and.ellipse")
                            .lineLimit(1)
                    }
                    if let count = travel.memberCount, count > 1 {
                        Label("\(count)", systemImage: "person.2")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.Color.textMuted)
            }
            .padding(14)
        }
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.Color.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }
}
