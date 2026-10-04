import AVKit
import SwiftUI

/// 전체 화면 미디어 뷰어. 좌우로 넘기고, 사진은 확대, 영상은 S3 에서 바로 스트리밍한다.
struct MediaViewer: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let model: AlbumModel

    @State private var currentId: String
    @State private var showChrome = true
    @State private var showInfo = false
    @State private var confirmDelete = false
    @State private var isWorking = false
    @State private var alertMessage: String?

    init(model: AlbumModel, startId: String) {
        self.model = model
        _currentId = State(initialValue: startId)
    }

    private var current: TravelMedia? { model.items.first { $0.id == currentId } }
    private var currentIndex: Int? { model.items.firstIndex { $0.id == currentId } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentId) {
                ForEach(model.items) { media in
                    MediaPage(media: media, isCurrent: media.id == currentId) {
                        withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
                    }
                    .tag(media.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        // 상단·하단 바만 따로 얹어 가운데(사진 확대·영상 컨트롤) 터치를 가로채지 않게 한다.
        .overlay(alignment: .top) {
            if showChrome { topBar.transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            if showChrome { bottomBar.transition(.opacity) }
        }
        .statusBarHidden(!showChrome)
        .onChange(of: currentId) {
            // 끝에 가까워지면 다음 페이지를 미리 불러온다.
            if let index = currentIndex, index >= model.items.count - 5 {
                Task { await model.loadMore(api: auth.api) }
            }
        }
        .sheet(isPresented: $showInfo) {
            if let current { MediaInfoSheet(media: current, travel: model.travel) }
        }
        .alert("알림", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("닫기")
            Spacer()
            if let index = currentIndex {
                Text("\(index + 1) / \(model.counts[model.filter] ?? model.items.count)")
                    .font(.subheadline.monospacedDigit())
            }
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 8)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            chromeButton("저장", systemImage: "square.and.arrow.down") { Task { await saveCurrent() } }
                .disabled(isWorking)
            chromeButton("정보", systemImage: "info.circle") { showInfo = true }
            if let current, model.canDelete(current) {
                chromeButton("삭제", systemImage: "trash") { confirmDelete = true }
                    .disabled(isWorking)
                    .confirmationDialog("이 항목을 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("삭제", role: .destructive) { Task { await deleteCurrent() } }
                    } message: {
                        Text("삭제하면 되돌릴 수 없습니다.")
                    }
            }
        }
        .padding(.bottom, 8)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }

    private func chromeButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
    }

    // MARK: - Actions

    private func saveCurrent() async {
        guard let current else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await PhotoSaver.save([current])
            alertMessage = "사진 앱에 저장했습니다."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func deleteCurrent() async {
        guard let current, let index = currentIndex else { return }
        isWorking = true
        defer { isWorking = false }
        // 지울 항목의 다음(없으면 이전) 항목으로 먼저 이동한다.
        let neighbor = model.items.indices.contains(index + 1) ? model.items[index + 1]
            : (index > 0 ? model.items[index - 1] : nil)
        let failed = await model.delete(ids: [current.id], api: auth.api)
        if failed > 0 {
            alertMessage = "삭제하지 못했습니다."
        } else if let neighbor {
            currentId = neighbor.id
        } else {
            dismiss()
        }
    }
}

// MARK: - Page

private struct MediaPage: View {
    let media: TravelMedia
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        if media.isVideo {
            VideoPage(media: media, isCurrent: isCurrent)
        } else {
            PhotoPage(media: media, onTap: onTap)
        }
    }
}

/// 썸네일을 먼저 보여주고, 화면 크기에 맞춘 고해상도로 바꿔 끼운다.
private struct PhotoPage: View {
    let media: TravelMedia
    let onTap: () -> Void

    @State private var image: UIImage?
    @State private var isFullLoaded = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, onSingleTap: onTap)
            } else {
                ProgressView().tint(.white)
            }
            if image != nil && !isFullLoaded {
                ProgressView().tint(.white).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 90)
            }
        }
        .task(id: media.id) {
            if let thumb = media.thumbURL {
                image = await ImageLoader.shared.image(for: thumb, maxPixel: 600)
            }
            guard let original = media.originalURL else { return }
            let screen = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
            // 확대해도 선명하도록 화면의 약 2배까지 디코딩한다.
            if let full = await ImageLoader.shared.image(for: original, maxPixel: screen * 2) {
                image = full
            }
            isFullLoaded = true
        }
    }
}

/// 영상은 원본 S3 주소를 AVPlayer 로 바로 스트리밍한다 (전체를 내려받지 않음).
private struct VideoPage: View {
    let media: TravelMedia
    let isCurrent: Bool

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                // 재생 컨트롤이 뷰어 상단(닫기)·하단(저장·정보·삭제) 버튼과 겹치지 않도록 여백을 둔다.
                VideoPlayer(player: player)
                    .padding(.top, 56)
                    .padding(.bottom, 84)
            } else if let thumb = media.thumbURL {
                RemoteImage(urls: [thumb], maxPixel: 800, contentMode: .fit) { Color.black }
            }
        }
        .onAppear { if isCurrent { preparePlayer() } }
        .onChange(of: isCurrent) {
            if isCurrent {
                preparePlayer()
            } else {
                player?.pause()
            }
        }
        .onDisappear { player?.pause() }
    }

    private func preparePlayer() {
        if player == nil, let url = media.originalURL {
            player = AVPlayer(url: url)
        }
        // 사진 앱처럼 영상 페이지로 오면 바로 재생한다.
        player?.play()
    }
}

// MARK: - Zoom

/// 핀치·더블탭 확대가 되는 이미지. SwiftUI 만으로는 스크롤·확대 경계 처리가 어려워 UIScrollView 를 쓴다.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.frame = scrollView.bounds
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSingleTap: onSingleTap) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var onSingleTap: () -> Void

        init(onSingleTap: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func singleTapped() { onSingleTap() }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

// MARK: - Info

private struct MediaInfoSheet: View {
    let media: TravelMedia
    let travel: Travel

    var body: some View {
        NavigationStack {
            List {
                row("파일 이름", media.originalFileName)
                row("종류", media.mimeType)
                if let size = media.fileSize {
                    row("크기", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let width = media.width, let height = media.height {
                    row("해상도", "\(width) × \(height)")
                }
                if let duration = media.durationText { row("길이", duration) }
                row("촬영", media.takenDate.map { TravelDate.fullFormatter.string(from: $0) })
                row("업로드", media.createdDate.map { TravelDate.fullFormatter.string(from: $0) })
                row("올린 사람", uploaderName)
            }
            .navigationTitle("정보")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private var uploaderName: String? {
        guard let id = media.uploadUserId else { return nil }
        let nickname = travel.members?.first { $0.userId == id }?.nickname
        return nickname.flatMap { $0.isEmpty ? nil : $0 } ?? id
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
        }
    }
}
