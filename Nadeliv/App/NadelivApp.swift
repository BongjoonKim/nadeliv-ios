import SwiftUI

@main
struct NadelivApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var auth = AuthStore()
    @State private var uploader = UploadManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(uploader)
                .preferredColorScheme(.dark)
                .tint(Theme.Color.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            // 전경 복귀 때 백그라운드에서 끝난 업로드를 마무리(complete)한다
            if phase == .active, auth.currentUser != nil {
                Task { await uploader.reconcile() }
            }
        }
    }
}

/// background URLSession 이벤트로 앱이 깨어났을 때 받는 곳.
/// 세션을 같은 identifier 로 다시 만들면 시스템이 밀린 delegate 콜백을 보내 준다.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        guard identifier == BackgroundUploadSession.identifier else {
            completionHandler()
            return
        }
        BackgroundUploadSession.shared.setCompletionHandler(completionHandler)
        _ = UploadManager.shared
    }
}

/// 인증 상태에 따라 화면을 고른다.
struct RootView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(UploadManager.self) private var uploader

    private var isSignedIn: Bool { auth.currentUser != nil }

    var body: some View {
        ZStack {
            Theme.Color.bg.ignoresSafeArea()
            switch auth.state {
            case .restoring:
                ProgressView()
            case .signedOut:
                LoginView()
            case .signedIn(let user):
                MainTabView(user: user)
            }
        }
        .task { await auth.restoreSession() }
        .task(id: isSignedIn) {
            // 로그인되면 업로드 매니저가 API 를 쓸 수 있게 하고, 지난 실행에서 남은 업로드를 이어서 처리한다
            if isSignedIn { uploader.configure(api: auth.api) }
        }
    }
}
