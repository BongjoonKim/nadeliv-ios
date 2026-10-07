import PhotosUI
import SwiftUI

/// 프로필 편집 시트: 사진·이름·생일.
struct ProfileEditView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var model: ProfileEditModel
    @State private var photoItem: PhotosPickerItem?

    private let onSaved: (UserProfile) -> Void

    init(profile: UserProfile, onSaved: @escaping (UserProfile) -> Void) {
        _model = State(initialValue: ProfileEditModel(profile: profile))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                nameSection
                birthdaySection
                emailSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Color.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("프로필 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.Color.bg, for: .navigationBar)
            .toolbar { toolbarContent }
            .onChange(of: model.name) { model.clampInputs() }
            .onChange(of: photoItem) {
                guard let item = photoItem else { return }
                photoItem = nil
                Task { await model.pickPhoto(item) }
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

    private var photoSection: some View {
        Section {
            HStack(spacing: 16) {
                EditAvatarPreview(model: model)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(model.hasPhoto ? "사진 바꾸기" : "사진 고르기", systemImage: "photo.badge.plus")
                    }
                    .accessibilityIdentifier("profileEdit.pickPhoto")
                    if model.hasPhoto {
                        Button(role: .destructive) {
                            model.removePhoto()
                        } label: {
                            Label("사진 빼기", systemImage: "trash")
                        }
                        .foregroundStyle(Theme.Color.danger)
                        .accessibilityIdentifier("profileEdit.removePhoto")
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
            Text("프로필 사진")
        }
    }

    private var nameSection: some View {
        Section {
            TextField("이름", text: $model.name)
                .textContentType(.name)
                .accessibilityIdentifier("profileEdit.name")
                .listRowBackground(Theme.Color.surface)
        } header: {
            Text("이름")
        } footer: {
            Text(verbatim: "\(model.name.count)/\(ProfileEditModel.nameLimit)")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var birthdaySection: some View {
        Section {
            Toggle("생일 입력", isOn: $model.hasBirthday.animation())
                .disabled(model.hasBirthday && !model.canClearBirthday)
                .accessibilityIdentifier("profileEdit.hasBirthday")
            if model.hasBirthday {
                DatePicker("생일", selection: $model.birthday, in: ...Date.now, displayedComponents: .date)
                    .accessibilityIdentifier("profileEdit.birthday")
            }
        } header: {
            Text("생일")
        } footer: {
            if !model.canClearBirthday {
                Text("이미 입력한 생일은 바꿀 수만 있고 지울 수는 없어요.")
            }
        }
        .listRowBackground(Theme.Color.surface)
        // 시간대 없는 날짜라 UTC 달력으로 골라야 기기 시간대와 상관없이 같은 날로 저장된다.
        .environment(\.calendar, ProfileDate.calendar)
        .environment(\.timeZone, ProfileDate.calendar.timeZone)
    }

    private var emailSection: some View {
        Section("이메일") {
            Text(model.profile.email ?? "-")
                .foregroundStyle(Theme.Color.textMuted)
                .listRowBackground(Theme.Color.surface)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("취소") { dismiss() }
                .disabled(model.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            if model.isSaving {
                ProgressView()
            } else {
                Button("저장") {
                    Task {
                        if let profile = await model.save(api: auth.api) {
                            onSaved(profile)
                            dismiss()
                        }
                    }
                }
                .bold()
                .disabled(!model.canSave)
                .accessibilityIdentifier("profileEdit.save")
            }
        }
    }
}

/// 편집 중 사진 미리보기: 새로 고른 사진 → 기존 사진 → 이니셜
private struct EditAvatarPreview: View {
    let model: ProfileEditModel

    var body: some View {
        ZStack {
            if let data = model.photoPreviewData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProfileAvatar(name: model.trimmedName.isEmpty ? model.profile.displayName : model.trimmedName,
                              url: model.existingPhotoURL)
            }
            if model.isPreparingPhoto || (model.isSaving && model.photoPreviewData != nil) {
                Color.black.opacity(0.35)
                ProgressView().tint(Theme.Color.text)
            }
        }
        .clipShape(Circle())
    }
}

/// 원형 프로필 사진. 사진이 없거나 못 불러오면 이름 첫 글자를 보여 준다 (웹 profileUi Avatar 와 같음).
struct ProfileAvatar: View {
    let name: String
    let url: URL?

    var body: some View {
        ZStack {
            Theme.Color.badgeBg
            Text(String(name.prefix(1)).uppercased())
                .font(Theme.Font.serif(26, weight: .medium))
                .foregroundStyle(Theme.Color.badgeText)
            if let url {
                RemoteImage(urls: [url], maxPixel: 300) { Color.clear }
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.Color.border2, lineWidth: 0.5))
    }
}
