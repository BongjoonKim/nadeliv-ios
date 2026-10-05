import PhotosUI
import SwiftUI

/// 여행 만들기 / 여행 설정(수정·삭제) 시트.
/// - 만들기: 여행 목록 + 버튼. 만든 사람이 ADMIN 이 된다.
/// - 설정: 앨범 화면에서 ADMIN 만 연다 (서버도 ADMIN 만 허용).
struct TravelFormView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var model: TravelFormModel
    @State private var coverItem: PhotosPickerItem?
    @FocusState private var tagFieldFocused: Bool

    private let onSaved: (TravelFormModel.SaveResult) -> Void
    private let onDeleted: (String) -> Void

    init(
        mode: TravelFormModel.Mode,
        onSaved: @escaping (TravelFormModel.SaveResult) -> Void,
        onDeleted: @escaping (String) -> Void = { _ in }
    ) {
        _model = State(initialValue: TravelFormModel(mode: mode))
        self.onSaved = onSaved
        self.onDeleted = onDeleted
    }

    var body: some View {
        NavigationStack {
            Form {
                coverSection
                titleSection
                destinationSection
                datesSection
                descriptionSection
                tagsSection
                visibilitySection
                if model.travel != nil { deleteSection }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Color.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(model.isCreate ? "새 여행" : "여행 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.Color.bg, for: .navigationBar)
            .toolbar { toolbarContent }
            .onChange(of: model.draft) { model.clampInputs() }
            .onChange(of: coverItem) {
                guard let item = coverItem else { return }
                coverItem = nil
                Task { await model.pickCover(item) }
            }
            .alert("알림", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        // 고친 내용이 있으면 아래로 쓸어 닫히지 않게 한다.
        .interactiveDismissDisabled(model.hasChanges || model.isBusy)
    }

    // MARK: - Sections

    private var coverSection: some View {
        Section {
            HStack(spacing: 14) {
                CoverPreview(model: model)
                    .frame(width: 112, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $coverItem, matching: .images) {
                        Label(model.hasCover ? "사진 바꾸기" : "사진 고르기", systemImage: "photo.badge.plus")
                    }
                    .accessibilityIdentifier("travelForm.pickCover")
                    if model.hasCover {
                        Button(role: .destructive) {
                            model.removeCover()
                        } label: {
                            Label("사진 빼기", systemImage: "trash")
                        }
                        .foregroundStyle(Theme.Color.danger)
                    }
                }
                .font(.subheadline)
                // Form 행 안에 버튼이 여러 개면 행 전체 탭이 모든 버튼을 누른다 → borderless 로 각자 받게 한다.
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
            }
            .padding(.vertical, 4)
            .listRowBackground(Theme.Color.surface)
        } header: {
            Text("커버 사진")
        } footer: {
            Text("여행 목록의 썸네일로 쓰여요. 사진이 없으면 색으로 표시돼요.")
        }
    }

    private var titleSection: some View {
        Section {
            TextField("어디로 떠나나요?", text: $model.draft.title)
                .accessibilityIdentifier("travelForm.title")
                .listRowBackground(Theme.Color.surface)
        } header: {
            Text("여행 이름")
        } footer: {
            Text(verbatim: "\(model.draft.title.count)/\(TravelFormModel.titleLimit)")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var destinationSection: some View {
        Section("여행지") {
            TextField("예: 제주, 경주, 부산", text: $model.draft.destination)
                .accessibilityIdentifier("travelForm.destination")
                .listRowBackground(Theme.Color.surface)
        }
    }

    private var datesSection: some View {
        Section {
            Toggle("날짜 정하기", isOn: $model.draft.hasDates.animation())
                .disabled(model.draft.hasDates && !model.canClearDates)
                .accessibilityIdentifier("travelForm.hasDates")
            if model.draft.hasDates {
                DatePicker("시작", selection: $model.draft.startDate, displayedComponents: .date)
                DatePicker("종료", selection: $model.draft.endDate, in: model.draft.startDate..., displayedComponents: .date)
            }
        } header: {
            Text("날짜")
        } footer: {
            if !model.canClearDates {
                Text("이미 정한 날짜는 바꿀 수만 있고 지울 수는 없어요.")
            }
        }
        .listRowBackground(Theme.Color.surface)
        // 서버 LocalDate(서울) 기준으로 고르게 한다 — 해외에서 열어도 날짜가 하루 밀리지 않도록.
        .environment(\.calendar, TravelFormModel.seoulCalendar)
        .environment(\.timeZone, TravelDate.seoul)
    }

    private var descriptionSection: some View {
        Section {
            TextField("어떤 여행인가요?", text: $model.draft.description, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityIdentifier("travelForm.description")
                .listRowBackground(Theme.Color.surface)
        } header: {
            Text("소개")
        } footer: {
            Text(verbatim: "\(model.draft.description.count)/\(TravelFormModel.descriptionLimit)")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var tagsSection: some View {
        Section("태그") {
            if !model.draft.tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(model.draft.tags, id: \.self) { tag in
                        TagChip(tag: tag) { model.removeTag(tag) }
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                TextField("태그 입력", text: $model.tagInput)
                    .focused($tagFieldFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        // 태그를 넣었으면 이어서 입력하도록 키보드를 유지하고, 빈 칸에서 완료를 누르면 닫는다.
                        let added = !model.tagInput.trimmingCharacters(in: .whitespaces).isEmpty
                        model.addTag()
                        tagFieldFocused = added
                    }
                    .accessibilityIdentifier("travelForm.tagInput")
                Button("추가") { model.addTag() }
                    .buttonStyle(.borderless)
                    .disabled(model.tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .listRowBackground(Theme.Color.surface)
    }

    private var visibilitySection: some View {
        Section {
            Picker("공개 범위", selection: $model.draft.visibility) {
                ForEach(TravelVisibility.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Theme.Color.surface)
        } header: {
            Text("공개 범위")
        } footer: {
            Text(model.draft.visibility == .public
                 ? "공개로 두면 누구나 볼 수 있는 여행 목록에 보여요."
                 : "여행 멤버만 볼 수 있어요.")
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        if let travel = model.travel {
            Section {
                TextField(travel.displayTitle, text: $model.deleteConfirmText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("travelForm.deleteConfirm")
                Button(role: .destructive) {
                    Task {
                        if await model.delete(api: auth.api) {
                            onDeleted(travel.id)
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        Text("여행 삭제")
                        if model.isDeleting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .foregroundStyle(model.canDelete ? Theme.Color.danger : Theme.Color.textFaint)
                .disabled(!model.canDelete)
                .accessibilityIdentifier("travelForm.delete")
            } header: {
                Text("여행 삭제")
            } footer: {
                Text("앨범의 사진·영상, 채팅, 멤버 정보까지 모두 지워지고 되돌릴 수 없어요. 확인을 위해 여행 이름을 그대로 입력해 주세요.")
            }
            .listRowBackground(Theme.Color.surface)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("취소") { dismiss() }
                .disabled(model.isSaving || model.isDeleting)
        }
        ToolbarItem(placement: .confirmationAction) {
            if model.isSaving {
                ProgressView()
            } else {
                Button(model.isCreate ? "만들기" : "저장") {
                    Task {
                        if let result = await model.save(api: auth.api) {
                            onSaved(result)
                            dismiss()
                        }
                    }
                }
                .bold()
                .disabled(!model.canSave)
                .accessibilityIdentifier("travelForm.save")
            }
        }
    }
}

/// 커버 미리보기: 새로 고른 사진 → 기존 커버 → 여행 색(만들기는 브랜드 그라데이션)
private struct CoverPreview: View {
    let model: TravelFormModel

    var body: some View {
        ZStack {
            if let travel = model.travel {
                let colors = TravelThumb.paletteColors(seed: travel.id)
                LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Theme.heroGradient
            }
            if let data = model.coverPreviewData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = model.existingCoverURL {
                RemoteImage(urls: [url], maxPixel: 400) { Color.clear }
            }
            if model.isPreparingCover || (model.isSaving && model.coverPreviewData != nil) {
                Color.black.opacity(0.35)
                ProgressView().tint(Theme.Color.text)
            }
        }
        .clipped()
    }
}

private struct TagChip: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(tag) 태그 빼기")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Theme.Color.badgeText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.Color.badgeBg)
        .clipShape(Capsule())
    }
}

/// 가로로 채우다 넘치면 다음 줄로 넘기는 레이아웃 (태그 칩용)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
