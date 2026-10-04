import Foundation

/// POST /ps/login, POST /login/ps/refresh 응답 (백엔드 TokenDTO)
struct TokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
}

struct RefreshRequest: Encodable {
    let refreshToken: String
}

/// GET /api/v1/users/me 응답 (백엔드 UserResponse)
struct CurrentUser: Decodable, Equatable {
    let id: String?
    let userId: String?
    let name: String?
    let email: String?
    let profileImage: String?
    let roles: [String]?

    var displayName: String { name ?? userId ?? "여행자" }
}
