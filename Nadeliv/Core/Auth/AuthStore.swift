import Foundation
import Observation

/// 앱 전체 인증 상태. 웹의 AuthContext + useAuthEP 를 합친 역할.
@Observable
final class AuthStore {
    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(CurrentUser)
    }

    private(set) var state: State = .restoring

    var currentUser: CurrentUser? {
        if case .signedIn(let user) = state { return user }
        return nil
    }
    let api: APIClient

    private static let refreshTokenKey = "refreshToken"

    init(api: APIClient = APIClient()) {
        self.api = api
        api.refreshHandler = { [weak self] in
            guard let self else { throw APIError.unauthorized }
            return try await self.refreshAccessToken()
        }
    }

    /// 앱 시작 시: Keychain 의 refresh 토큰으로 세션을 복구한다.
    func restoreSession() async {
        guard state == .restoring else { return }
        guard KeychainStore.get(Self.refreshTokenKey) != nil else {
            state = .signedOut
            return
        }
        do {
            api.accessToken = try await refreshAccessToken()
            try await loadCurrentUser()
        } catch {
            signOut()
        }
    }

    func signIn(userId: String, password: String) async throws {
        let token: TokenResponse = try await api.postForm(
            "ps/login",
            fields: ["username": userId, "password": password]
        )
        guard let access = token.accessToken, let refresh = token.refreshToken else {
            throw APIError.server(status: 200, message: "토큰을 받지 못했습니다.")
        }
        KeychainStore.set(refresh, for: Self.refreshTokenKey)
        api.accessToken = access
        try await loadCurrentUser()
    }

    func signOut() {
        KeychainStore.delete(Self.refreshTokenKey)
        api.accessToken = nil
        state = .signedOut
    }

    // MARK: - Private

    private func loadCurrentUser() async throws {
        let user: CurrentUser = try await api.get("api/v1/users/me")
        state = .signedIn(user)
    }

    /// 진행 중인 refresh. 여러 요청이 동시에 401 을 받아도 refresh 는 한 번만 호출한다.
    private var refreshTask: Task<String, Error>?

    private func refreshAccessToken() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        guard let refresh = KeychainStore.get(Self.refreshTokenKey) else {
            throw APIError.unauthorized
        }
        do {
            let token: TokenResponse = try await api.postJSON(
                "login/ps/refresh",
                body: RefreshRequest(refreshToken: refresh),
                authorized: false
            )
            guard let access = token.accessToken else { throw APIError.unauthorized }
            if let newRefresh = token.refreshToken {
                KeychainStore.set(newRefresh, for: Self.refreshTokenKey)
            }
            return access
        } catch let error as APIError {
            // refresh 자체가 거절되면 로그인 화면으로 돌린다. 네트워크 오류는 그대로 올린다.
            if case .transport = error { throw error }
            signOut()
            throw APIError.unauthorized
        }
    }
}
