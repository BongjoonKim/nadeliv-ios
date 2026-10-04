import SwiftUI

/// 프로필 탭: 계정 정보와 로그아웃.
struct ProfileView: View {
    @Environment(AuthStore.self) private var auth
    let user: CurrentUser

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    profileCard
                }
                .padding(20)
            }
            .background(Theme.Color.bg)
            .navigationTitle("프로필")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("로그아웃") { auth.signOut() }
                        .accessibilityIdentifier("home.signOut")
                }
            }
            .toolbarBackground(Theme.Color.bg, for: .navigationBar)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("반가워요,")
                .font(.subheadline)
                .foregroundStyle(Theme.Color.textSoft)
            Text(user.displayName)
                .font(Theme.Font.serif(30))
                .foregroundStyle(Theme.Color.text)
                .accessibilityIdentifier("home.userName")
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .bottomLeading)
        .padding(20)
        .background(Theme.heroGradient)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("아이디", user.userId)
            Divider().overlay(Theme.Color.border)
            row("이메일", user.email)
        }
        .padding(16)
        .background(Theme.Color.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.Color.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.Color.textMuted)
            Spacer()
            Text(value ?? "-").foregroundStyle(Theme.Color.text)
        }
        .font(.subheadline)
    }
}
