import SwiftUI

@main
struct NadelivApp: App {
    @State private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .preferredColorScheme(.dark)
                .tint(Theme.Color.accent)
        }
    }
}

/// 인증 상태에 따라 화면을 고른다.
struct RootView: View {
    @Environment(AuthStore.self) private var auth

    var body: some View {
        ZStack {
            Theme.Color.bg.ignoresSafeArea()
            switch auth.state {
            case .restoring:
                ProgressView()
            case .signedOut:
                LoginView()
            case .signedIn(let user):
                HomeView(user: user)
            }
        }
        .task { await auth.restoreSession() }
    }
}
