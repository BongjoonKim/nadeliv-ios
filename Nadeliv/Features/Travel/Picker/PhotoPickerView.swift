import Photos
import SwiftUI

/// 자체 사진 선택기. 시스템 PhotosPicker 와 달리 "이미 올린 사진"에 초록 테두리·체크를 표시해
/// 100장을 나눠 올릴 때 어디까지 올렸는지 바로 알 수 있게 한다.
/// 권한이 거부되면 `onUseSystemPicker` 로 시스템 선택기에 넘긴다.
struct PhotoPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthStore.self) private var auth
    @Environment(UploadManager.self) private var uploader
    @State private var model: PhotoPickerModel
    @State private var confirmUploaded = false

    private let onPick: ([String]) -> Void
    private let onUseSystemPicker: () -> Void

    init(travelId: String, onPick: @escaping ([String]) -> Void, onUseSystemPicker: @escaping () -> Void) {
        _model = State(initialValue: PhotoPickerModel(travelId: travelId))
        self.onPick = onPick
        self.onUseSystemPicker = onUseSystemPicker
    }

    private var travelId: String { model.travelId }
    private let columns = 4

    var body: some View {
        NavigationStack {
            Group {
                switch model.access {
                case .checking:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .denied:
                    deniedState
                case .authorized, .limited:
                    content
                }
            }
            .background(Theme.Color.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.Color.bg, for: .navigationBar)
            .toolbar { toolbarContent }
        }
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .task(id: model.access) {
            guard model.access == .authorized || model.access == .limited else { return }
            await model.loadServerMedia(api: auth.api)
        }
        .onChange(of: uploader.uploaded[travelId]?.count ?? 0) { model.refreshRegistry() }
        .onChange(of: model.notice) { _, notice in
            guard notice != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                model.notice = nil
            }
        }
        .confirmationDialog(
            "이미 올린 사진 \(model.selectedUploadedCount)개가 들어 있어요",
            isPresented: $confirmUploaded,
            titleVisibility: .visible
        ) {
            Button("빼고 올리기") { finish(model.selectionExcludingUploaded()) }
            Button("그대로 올리기") { finish(model.selection) }
        } message: {
            Text("그대로 올리면 앨범에 같은 사진이 한 번 더 생깁니다.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("취소") { dismiss() }
        }
        if model.access == .authorized || model.access == .limited {
            ToolbarItem(placement: .principal) {
                Menu {
                    Picker("앨범", selection: $model.currentCollection) {
                        ForEach(model.collections) { collection in
                            Text(collection.title).tag(collection)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.currentCollection.title)
                            .font(.headline)
                            .foregroundStyle(Theme.Color.text)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                }
                .accessibilityLabel("앨범 선택")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                if model.selectedUploadedCount > 0 {
                    confirmUploaded = true
                } else {
                    finish(model.selection)
                }
            } label: {
                Text(model.selection.isEmpty ? "올리기" : "올리기 \(model.selection.count)")
                    .bold()
            }
            .disabled(model.selection.isEmpty)
            .accessibilityIdentifier("picker.upload")
        }
    }

    private func finish(_ ids: [String]) {
        guard !ids.isEmpty else {
            dismiss()
            return
        }
        onPick(ids)
        dismiss()
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            statusBar
            GeometryReader { geometry in
                // 사진 앱처럼 최신(아래)부터 보여 준다. 한 화면에 다 들어가면 위에서부터.
                let cell = geometry.size.width / CGFloat(columns)
                let fits = cell > 0 ? Int(geometry.size.height / cell) * columns : 0
                ScrollViewReader { proxy in
                    ScrollView {
                        grid
                    }
                    .defaultScrollAnchor(model.visibleAssets.count > fits ? .bottom : .top)
                    .overlay(alignment: .bottomTrailing) {
                        if let last = model.lastUploadedId, !model.hideUploaded {
                            Button {
                                withAnimation { proxy.scrollTo(last, anchor: .center) }
                            } label: {
                                Label("마지막 올린 사진", systemImage: "arrow.down.to.line")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.Color.text)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Theme.Color.surface3, in: Capsule())
                                    .overlay(Capsule().stroke(Theme.Color.border2))
                            }
                            .padding(16)
                            .accessibilityIdentifier("picker.jumpToLastUploaded")
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Color.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.Color.surface3, in: Capsule())
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Color.accent)
                    Text("올린 사진 \(model.uploadedCount)")
                    if model.isLoadingServer {
                        ProgressView().controlSize(.mini)
                    }
                }
                let uploading = uploader.activeAssetIds(for: travelId).count
                if uploading > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.circle")
                            .foregroundStyle(Theme.Color.textSoft)
                        Text("올리는 중 \(uploading)")
                    }
                }
                Spacer()
                Toggle(isOn: $model.hideUploaded) {
                    Text("올린 사진 숨기기")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(model.hideUploaded ? Theme.Color.accentStrong : Theme.Color.textMuted)
                .accessibilityIdentifier("picker.hideUploaded")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.Color.textSoft)

            if model.access == .limited {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("일부 사진만 접근할 수 있어요.")
                    Button("더 선택") { PhotoLibrary.presentLimitedLibraryPicker() }
                        .font(.caption.weight(.semibold))
                }
                .font(.caption)
                .foregroundStyle(Theme.Color.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.Color.surface)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.Color.border) }
    }

    @ViewBuilder
    private var grid: some View {
        if model.visibleAssets.isEmpty {
            ContentUnavailableView {
                Label(model.hideUploaded && !model.assets.isEmpty ? "모두 올렸어요" : "사진이 없어요",
                      systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(model.hideUploaded && !model.assets.isEmpty
                     ? "이 앨범의 사진은 모두 올라가 있어요."
                     : (model.access == .limited ? "위의 '더 선택'으로 사진을 추가할 수 있어요." : ""))
            }
            .padding(.top, 80)
        } else {
            let items = Array(repeating: GridItem(.flexible(), spacing: 2), count: columns)
            LazyVGrid(columns: items, spacing: 2) {
                ForEach(model.visibleAssets, id: \.localIdentifier) { asset in
                    AssetCell(
                        asset: asset,
                        pixel: cellPixel,
                        state: cellState(asset)
                    )
                    .id(asset.localIdentifier)
                    .onTapGesture { model.toggle(asset) }
                }
            }
            .padding(.bottom, 72)
        }
    }

    private func cellState(_ asset: PHAsset) -> AssetCell.State {
        if let index = model.selectionIndex(of: asset) { return .selected(index) }
        if uploader.activeAssetIds(for: travelId).contains(asset.localIdentifier) { return .uploading }
        if model.isUploaded(asset) { return .uploaded }
        return .plain
    }

    /// 셀 한 칸의 픽셀 크기 (화면 폭 / 열 수 × 배율). 이 크기로만 썸네일을 받는다.
    private var cellPixel: CGFloat {
        UITraitCollection.current.displayScale * 440 / CGFloat(columns)
    }

    // MARK: - Denied

    private var deniedState: some View {
        ContentUnavailableView {
            Label("사진 보관함에 접근할 수 없어요", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("설정에서 사진 접근을 허용하면 이미 올린 사진을 표시해 드려요. 지금은 시스템 선택기로 고를 수 있어요.")
        } actions: {
            VStack(spacing: 10) {
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("시스템 선택기로 고르기") {
                    onUseSystemPicker()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("picker.useSystemPicker")
            }
        }
    }
}

// MARK: - Cell

private struct AssetCell: View {
    enum State: Equatable {
        case plain
        case uploaded
        case uploading
        case selected(Int)
    }

    let asset: PHAsset
    let pixel: CGFloat
    let state: State

    private var isVideo: Bool { asset.mediaType == .video }
    private var isUploaded: Bool { state == .uploaded }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AssetThumbnail(asset: asset, pixel: pixel)
                    // fill 로 넘친 사진은 잘려 보여도 터치 영역은 옆 칸까지 남는다 → 터치는 칸(바탕)만 받게 한다.
                    .allowsHitTesting(false)
            }
            .clipped()
            .overlay {
                switch state {
                case .uploaded: Theme.Color.bg.opacity(0.45)
                case .uploading: Theme.Color.bg.opacity(0.3)
                case .selected: Theme.Color.accent.opacity(0.2)
                case .plain: EmptyView()
                }
            }
            .overlay {
                // 올린 사진: 초록 테두리 (카카오톡의 "보낸 사진" 표시와 같은 역할)
                if isUploaded {
                    Rectangle().strokeBorder(Theme.Color.accentStrong, lineWidth: 3)
                }
                if case .selected = state {
                    Rectangle().strokeBorder(Theme.Color.accent, lineWidth: 3)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isVideo {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                        if asset.duration > 0 { Text(durationText) }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                badge.padding(5)
            }
            .contentShape(Rectangle())
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("picker.cell")
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .plain:
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))
                .shadow(radius: 2)
        case .uploaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.Color.bg, Theme.Color.accent)
                .shadow(radius: 2)
        case .uploading:
            Image(systemName: "arrow.up.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.Color.bg, Theme.Color.textSoft)
                .shadow(radius: 2)
        case .selected(let index):
            Text("\(index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.Color.bg)
                .frame(width: 22, height: 22)
                .background(Theme.Color.accent, in: Circle())
                .shadow(radius: 2)
        }
    }

    private var durationText: String {
        let seconds = Int(asset.duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var accessibilityText: String {
        let kind = isVideo ? "영상" : "사진"
        switch state {
        case .plain: return kind
        case .uploaded: return "\(kind), 이미 올림"
        case .uploading: return "\(kind), 올리는 중"
        case .selected(let index): return "\(kind), \(index)번째 선택"
        }
    }
}

/// PhotoKit 썸네일. 흐린 것이 먼저 오고 선명한 것으로 바뀐다. 셀이 사라지면 요청을 취소한다.
private struct AssetThumbnail: View {
    let asset: PHAsset
    let pixel: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.Color.surface3
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: asset.localIdentifier) {
            for await next in PhotoLibrary.thumbnails(for: asset, pixel: pixel) {
                image = next
            }
        }
    }
}
