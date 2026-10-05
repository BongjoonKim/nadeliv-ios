import SwiftUI

/// 여행 탭 첫 화면: 내 여행 목록. 여행을 누르면 앨범으로 바로 들어간다. + 로 새 여행을 만든다.
struct TravelListView: View {
    @Environment(AuthStore.self) private var auth
    @State private var model = TravelListModel()
    @State private var path: [Travel] = []
    @State private var isCreating = false
    /// 만들기 시트가 닫힌 뒤 들어갈 새 여행 (시트가 닫히는 중에 push 하면 애니메이션이 꼬인다)
    @State private var createdTravel: Travel?
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(Theme.Color.bg)
                .navigationTitle("여행")
                .toolbarBackground(Theme.Color.bg, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { isCreating = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("새 여행 만들기")
                            .accessibilityIdentifier("travelList.create")
                    }
                }
                .navigationDestination(for: Travel.self) { travel in
                    AlbumView(
                        travel: travel,
                        onTravelChanged: { model.didUpdate($0) },
                        onTravelDeleted: { id in
                            model.didDelete(id: id)
                            path.removeAll { $0.id == id }
                        }
                    )
                }
        }
        .task { if model.travels.isEmpty { await model.reload(api: auth.api) } }
        .sheet(isPresented: $isCreating, onDismiss: openCreatedTravel) {
            TravelFormView(mode: .create) { result in
                model.didCreate(result.travel)
                // 커버만 실패한 경우엔 목록에 남아 경고를 보여준다 (알림과 화면 전환을 동시에 하면 전환이 무시된다).
                if let warning = result.warning {
                    alertMessage = warning
                } else {
                    createdTravel = result.travel
                }
            }
        }
        .alert("알림", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func openCreatedTravel() {
        guard let travel = createdTravel else { return }
        createdTravel = nil
        path.append(travel)
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
                Text(model.errorMessage ?? "첫 여행을 만들고 사진과 영상을 모아 보세요.")
            } actions: {
                if model.errorMessage == nil {
                    Button("여행 만들기") { isCreating = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("다시 시도") { Task { await model.reload(api: auth.api) } }
                }
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
