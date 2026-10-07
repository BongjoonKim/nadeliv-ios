import Foundation

/// GET·PUT /api/v1/user/profile 응답 (백엔드 UserProfileResponse)
struct UserProfile: Decodable, Equatable {
    let id: String?
    let userId: String?
    let email: String?
    let name: String?
    /// 프로필 사진 URL. 사진을 뺀 사용자는 빈 문자열이다.
    let src: String?
    /// LocalDateTime 문자열 ("1996-05-01T00:00:00")
    let birthday: String?
    let roles: [String]?
    let created: String?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return userId ?? "여행자"
    }

    var photoURL: URL? {
        guard let src, !src.isEmpty else { return nil }
        return URL(string: src)
    }

    var birthdayDate: Date? { ProfileDate.parseDay(birthday) }
    var joinedDate: Date? { ProfileDate.parseDay(created) }
}

/// nil 인 필드는 보내지 않고, 서버는 보내지 않은 필드를 바꾸지 않는다.
struct ProfileUpdateRequest: Encodable {
    var name: String?
    /// 사진 빼기 = 빈 문자열 (null 은 "변경 없음")
    var src: String?
    var birthday: String?

    var isEmpty: Bool { name == nil && src == nil && birthday == nil }
}

struct PasswordChangeRequest: Encodable {
    let currentPassword: String
    let newPassword: String
}

struct AccountDeleteRequest: Encodable {
    let password: String
}

/// 생일·가입일은 시간대 없는 LocalDateTime 이라 날짜 부분만 쓴다. 기기 시간대와 상관없이 같은 날로 보이게 UTC 달력으로 다룬다.
enum ProfileDate {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func parseDay(_ text: String?) -> Date? {
        guard let text, text.count >= 10 else { return nil }
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// 서버에 보내는 LocalDateTime ("1996-05-01T00:00:00")
    static func serverDateTime(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02dT00:00:00", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func display(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: calendar.timeZone))
    }
}

/// 내 계정 API. 화면은 이 함수들만 호출한다.
extension APIClient {
    func myProfile() async throws -> UserProfile {
        try await get("api/v1/user/profile")
    }

    func updateMyProfile(_ request: ProfileUpdateRequest) async throws -> UserProfile {
        try await putJSON("api/v1/user/profile", body: request)
    }

    /// 현재 비밀번호가 틀리면 400 (USER_004)
    func changePassword(_ request: PasswordChangeRequest) async throws {
        let _: EmptyResponse = try await putJSON("api/v1/user/password", body: request)
    }

    /// 회원 탈퇴. 서버는 개인정보(이름·이메일·생일·사진·팔로우·북마크)를 지우고 로그인을 막는다.
    /// 올린 글·댓글·여행은 "Deleted user" 로 남는다. 비밀번호가 틀리면 400 (USER_004).
    func deleteMyAccount(password: String) async throws {
        try await deleteJSON("api/v1/user/account", body: AccountDeleteRequest(password: password))
    }

    /// 프로필 사진 업로드 (백엔드 /api/v1/files → 공개 S3 URL)
    func uploadProfilePhoto(userId: String, jpeg: Data) async throws -> String {
        let key = "profile/\(userId)/avatar-\(UUID().uuidString.lowercased()).jpg"
        let response: FileUploadResponse = try await postMultipart(
            "api/v1/files",
            fields: ["fileKey": key],
            file: MultipartFile(fieldName: "file", fileName: "avatar.jpg", mimeType: "image/jpeg", data: jpeg)
        )
        return response.url
    }
}

extension APIError {
    /// 비밀번호 확인이 필요한 API(비밀번호 변경·탈퇴)에서 400 은 비밀번호 불일치(USER_004) 뿐이다.
    var isPasswordMismatch: Bool {
        if case .server(400, _) = self { return true }
        return false
    }
}
