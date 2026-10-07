import SwiftUI

/// 프로필 탭: 내 정보와 계정 관리(프로필 편집·비밀번호 변경·로그아웃·계정 삭제).
struct ProfileView: View {
    @Environment(AuthStore.self) private var auth
    let user: CurrentUser

    @State private var profile: UserProfile?
    @State private var loadError: String?
    @State private var isEditing = false
    @State private var isConfirmingSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    hero
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                infoSection
                accountSection
                dangerSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Color.bg)
            .navigationTitle("프로필")
            .toolbarBackground(Theme.Color.bg, for: .navigationBar)
            .refreshable { await load() }
            .task { if profile == nil { await load() } }
            .sheet(isPresented: $isEditing) {
                if let profile {
                    ProfileEditView(profile: profile) { saved in
                        self.profile = saved
                        Task { await auth.reloadCurrentUser() }
                    }
                }
            }
            .confirmationDialog("로그아웃할까요?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                Button("로그아웃", role: .destructive) { auth.signOut() }
                Button("취소", role: .cancel) {}
            }
        }
    }

    private var displayName: String { profile?.displayName ?? user.displayName }
    private var photoURL: URL? {
        if let profile { return profile.photoURL }
        return user.profileImage.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    // MARK: - Sections

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ProfileAvatar(name: displayName, url: photoURL)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(Theme.Font.serif(26))
                    .foregroundStyle(Theme.Color.text)
                    .lineLimit(2)
                    .accessibilityIdentifier("home.userName")
                if let userId = profile?.userId ?? user.userId {
                    Text(verbatim: "@\(userId)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Color.textSoft)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .bottomLeading)
        .padding(20)
        .background(Theme.heroGradient)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private var infoSection: some View {
        Section {
            row("이메일", profile?.email ?? user.email)
            row("생일", profile?.birthdayDate.map(ProfileDate.display))
            row("가입일", profile?.joinedDate.map(ProfileDate.display))
        } header: {
            Text("내 정보")
        } footer: {
            if let loadError {
                Text(loadError).foregroundStyle(Theme.Color.danger)
            }
        }
        .listRowBackground(Theme.Color.surface)
    }

    private var accountSection: some View {
        Section("계정") {
            Button {
                isEditing = true
            } label: {
                Label("프로필 편집", systemImage: "person.crop.circle")
            }
            .disabled(profile == nil)
            .accessibilityIdentifier("profile.edit")

            NavigationLink {
                PasswordChangeView()
            } label: {
                Label("비밀번호 변경", systemImage: "key")
            }
            .accessibilityIdentifier("profile.password")

            Button {
                isConfirmingSignOut = true
            } label: {
                Label("로그아웃", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("home.signOut")
        }
        // 버튼 행은 기본이 강조색이라 일반 행처럼 보이게 맞춘다 (섹션 머리글 색은 건드리지 않게 tint 로)
        .tint(Theme.Color.text)
        .listRowBackground(Theme.Color.surface)
    }

    private var dangerSection: some View {
        Section {
            NavigationLink {
                AccountDeleteView()
            } label: {
                Label("계정 삭제", systemImage: "person.crop.circle.badge.xmark")
                    .foregroundStyle(Theme.Color.danger)
            }
            .accessibilityIdentifier("profile.deleteAccount")
        }
        .listRowBackground(Theme.Color.surface)
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.Color.textMuted)
            Spacer()
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "-")
                .foregroundStyle(Theme.Color.text)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    // MARK: - Load

    private func load() async {
        do {
            profile = try await auth.api.myProfile()
            loadError = nil
        } catch {
            if case APIError.unauthorized = error { return }
            loadError = error.localizedDescription
        }
    }
}
