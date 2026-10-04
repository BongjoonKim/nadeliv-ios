import PhotosUI
import SwiftUI

/// 여행 앨범. 그리드 + 필터·정렬 + 선택(저장·삭제) + 업로드.
struct AlbumView: View {
    @Environment(AuthStore.self) private var auth
    let travel: Travel

    var body: some View {
        AlbumContent(travel: travel, currentUserId: auth.currentUser?.userId)
    }
}

private struct AlbumContent: View {
    @Environment(AuthStore.self) private var auth
    @Environment(UploadManager.self) private var uploader
    @State private var model: AlbumModel

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var viewerStart: TravelMedia?
    @State private var confirmDelete = false
    @State private var alertMessage: String?
    @State private var isSaving = false
    /// uploader.uploaded 중 이미 목록에 반영한 개수. nil = 화면에 처음 들어온 상태.
    @State private var appliedUploads: Int?

    init(travel: Travel, currentUserId: String?) {
        _model = State(initialValue: AlbumModel(travel: travel, currentUserId: currentUserId))
    }

    private var travelId: String { model.travel.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                filterBar
                grid
            }
        }
        .background(Theme.Color.bg)
        .refreshable { await model.reload(api: auth.api) }
        .navigationTitle(model.isSelecting ? selectionTitle : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Color.bg, for: .navigationBar)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { bottomBar }
        // 선택 중에는 탭 바를 숨겨 저장·삭제 바와 겹치지 않게 한다.
        .toolbar(model.isSelecting ? .hidden : .visible, for: .tabBar)
        .task { if model.items.isEmpty { await model.reload(api: auth.api) } }
        .onChange(of: model.filter) { Task { await model.reload(api: auth.api) } }
        .onChange(of: model.sort) { Task { await model.reload(api: auth.api) } }
        .onChange(of: pickerItems) {
            guard !pickerItems.isEmpty else { return }
            uploader.enqueue(pickerItems, travelId: travelId, api: auth.api)
            pickerItems = []
        }
        .onChange(of: uploader.uploaded[travelId]?.count ?? 0, initial: true) { _, count in
            // 화면에 들어오기 전에 끝난 업로드는 서버 목록에 이미 포함돼 있으므로 반영한 것으로 친다.
            guard let applied = appliedUploads else {
                appliedUploads = count
                return
            }
            let all = uploader.uploaded[travelId] ?? []
            for media in all.dropFirst(applied) { model.didUpload(media) }
            appliedUploads = count
        }
        .fullScreenCover(item: $viewerStart) { start in
            MediaViewer(model: model, startId: start.id)
        }
        .alert("알림", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.travel.displayTitle)
                .font(Theme.Font.serif(28))
                .foregroundStyle(Theme.Color.text)
            HStack(spacing: 10) {
                if let dates = model.travel.dateRangeText {
                    Label(dates, systemImage: "calendar")
                }
                if let total = model.counts[.all] {
                    Label("\(total)개", systemImage: "photo.on.rectangle")
                }
                if model.role == .viewer {
                    Label("보기 전용", systemImage: "eye")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.Color.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var filterBar: some View {
        Picker("필터", selection: $model.filter) {
            ForEach(MediaFilter.allCases) { filter in
                Text(filterLabel(filter)).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
    }

    private func filterLabel(_ filter: MediaFilter) -> String {
        if let count = model.counts[filter] { return "\(filter.label) \(count)" }
        return filter.label
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        if model.items.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: model.columns)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(model.items) { media in
                    MediaCell(
                        media: media,
                        maxPixel: cellPixel,
                        isSelecting: model.isSelecting,
                        isSelected: model.selection.contains(media.id)
                    )
                    .onTapGesture {
                        if model.isSelecting {
                            model.toggle(media)
                        } else {
                            viewerStart = media
                        }
                    }
                    .onLongPressGesture {
                        if !model.isSelecting {
                            model.isSelecting = true
                            model.toggle(media)
                        }
                    }
                    .task { await model.loadMoreIfNeeded(current: media, api: auth.api) }
                }
            }
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
    }

    /// 셀 한 칸의 픽셀 크기 (화면 폭 / 열 수 × 배율). 이 크기로만 디코딩한다.
    private var cellPixel: CGFloat {
        let scale = UITraitCollection.current.displayScale
        return 440 / CGFloat(model.columns) * scale
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoading {
            ProgressView()
        } else if let error = model.errorMessage {
            ContentUnavailableView {
                Label("불러오지 못했어요", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("다시 시도") { Task { await model.reload(api: auth.api) } }
            }
        } else {
            ContentUnavailableView {
                Label(model.filter == .all ? "아직 사진이 없어요" : "\(model.filter.label)이 없어요",
                      systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(model.canEdit ? "오른쪽 위 + 버튼으로 사진과 영상을 올려 보세요." : "")
            }
        }
    }

    // MARK: - Toolbar

    private var selectionTitle: String {
        model.selection.isEmpty ? "항목 선택" : "\(model.selection.count)개 선택됨"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(model.allLoadedSelected ? "선택 해제" : "모두 선택") { model.toggleSelectAllLoaded() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("완료") { model.toggleSelecting() }.bold()
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("정렬", selection: $model.sort) {
                        ForEach(MediaSort.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("크기", selection: $model.columns) {
                        Label("크게", systemImage: "square.grid.2x2").tag(2)
                        Label("보통", systemImage: "square.grid.3x3").tag(3)
                        Label("작게", systemImage: "square.grid.4x3.fill").tag(5)
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("정렬과 보기")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("선택") { model.toggleSelecting() }
                    .disabled(model.items.isEmpty)
            }
            if model.canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: 100,
                        matching: .any(of: [.images, .videos]),
                        preferredItemEncoding: .current
                    ) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("사진·영상 올리기")
                }
            }
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if let summary = uploader.summary(for: travelId) {
                UploadStatusBar(
                    summary: summary,
                    error: uploader.firstError(for: travelId),
                    onRetry: { uploader.retryFailed(api: auth.api) },
                    onDismiss: { uploader.clearFinished() }
                )
            }
            if model.isSelecting {
                selectionBar
            }
        }
    }

    private var selectionBar: some View {
        HStack {
            Button {
                Task { await saveSelection() }
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Label("사진 앱에 저장", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(model.selection.isEmpty || isSaving)

            Spacer()

            if model.canEdit {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    if model.isDeleting {
                        ProgressView()
                    } else {
                        Label("삭제", systemImage: "trash")
                    }
                }
                .disabled(!model.canDeleteSelection || model.isDeleting)
                // 확인 창이 삭제 버튼에서 뜨도록 버튼에 붙인다.
                .confirmationDialog(
                    "\(model.selection.count)개 항목을 삭제할까요?",
                    isPresented: $confirmDelete,
                    titleVisibility: .visible
                ) {
                    Button("삭제", role: .destructive) { Task { await deleteSelection() } }
                } message: {
                    Text("삭제하면 되돌릴 수 없습니다. 여행 멤버 모두의 앨범에서 사라집니다.")
                }
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func deleteSelection() async {
        let ids = Array(model.selection)
        let failed = await model.delete(ids: ids, api: auth.api)
        if failed > 0 {
            alertMessage = "\(failed)개 항목을 삭제하지 못했습니다."
        }
    }

    private func saveSelection() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await PhotoSaver.save(model.selectedItems)
            alertMessage = "\(saved)개 항목을 사진 앱에 저장했습니다."
            model.toggleSelecting()
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

// MARK: - Cell

private struct MediaCell: View {
    let media: TravelMedia
    let maxPixel: CGFloat
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RemoteImage(urls: media.gridImageURLs, maxPixel: maxPixel) {
                    ZStack {
                        Theme.Color.surface3
                        Image(systemName: media.isVideo ? "video" : "photo")
                            .foregroundStyle(Theme.Color.textFaint)
                    }
                }
                // fill 로 넘친 사진은 잘려 보여도 터치 영역은 옆 칸까지 남는다 → 터치는 칸(바탕)만 받게 한다.
                .allowsHitTesting(false)
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if media.isVideo {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                        if let duration = media.durationText { Text(duration) }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(5)
                }
            }
            .overlay {
                if isSelected {
                    Theme.Color.accent.opacity(0.25)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? Theme.Color.bg : .white, isSelected ? Theme.Color.accent : .clear)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(media.isVideo ? "영상" : "사진")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Upload status

private struct UploadStatusBar: View {
    let summary: UploadManager.Summary
    let error: String?
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if summary.isActive {
                    Text("업로드 중 \(summary.done + summary.failed + 1)/\(summary.total)")
                } else if summary.failed > 0 {
                    Text("\(summary.done)개 완료, \(summary.failed)개 실패")
                        .foregroundStyle(Theme.Color.danger)
                } else {
                    Text("\(summary.done)개 업로드 완료")
                }
                Spacer()
                if !summary.isActive {
                    if summary.failed > 0 {
                        Button("다시 시도", action: onRetry)
                    }
                    Button("닫기", action: onDismiss)
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.Color.text)

            ProgressView(value: summary.progress)
                .tint(summary.failed > 0 && !summary.isActive ? Theme.Color.danger : Theme.Color.accent)

            if let error, !summary.isActive {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.Color.textMuted)
                    .lineLimit(2)
            } else if summary.isActive {
                Text("앱을 닫으면 업로드가 멈춥니다.")
                    .font(.caption)
                    .foregroundStyle(Theme.Color.textFaint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.Color.surface)
        .overlay(alignment: .top) { Divider().overlay(Theme.Color.border) }
    }
}
