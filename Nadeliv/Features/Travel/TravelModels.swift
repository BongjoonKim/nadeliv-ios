import Foundation

// MARK: - 여행

/// GET /api/v1/travels/my 응답 (백엔드 TravelListResponse)
struct TravelListResponse: Decodable {
    let travels: [Travel]
    let pagination: Pagination?

    struct Pagination: Decodable {
        let totalCount: Int?
        let pageSize: Int?
        let currentPage: Int?
        let hasMore: Bool?
    }
}

/// 백엔드 TravelResponse 중 앨범에 필요한 필드만.
struct Travel: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let description: String?
    let coverImageUrl: String?
    let status: String?
    let startDate: String?   // "yyyy-MM-dd"
    let endDate: String?
    let destination: String?
    let members: [TravelMember]?
    let memberCount: Int?

    var displayTitle: String { (title?.isEmpty == false ? title : nil) ?? "제목 없는 여행" }

    func role(of userId: String?) -> TravelRole? {
        guard let userId else { return nil }
        return members?.first { $0.userId == userId }.flatMap { TravelRole(rawValue: $0.role ?? "") }
    }

    /// "2026.10.03 – 10.05" 형식. 날짜가 없으면 nil.
    var dateRangeText: String? {
        guard let start = TravelDate.parseDay(startDate) else { return nil }
        let startText = TravelDate.dayFormatter.string(from: start)
        guard let end = TravelDate.parseDay(endDate), end != start else { return startText }
        let sameYear = Calendar.current.component(.year, from: start) == Calendar.current.component(.year, from: end)
        let endText = (sameYear ? TravelDate.monthDayFormatter : TravelDate.dayFormatter).string(from: end)
        return "\(startText) – \(endText)"
    }
}

struct TravelMember: Decodable, Hashable {
    let userId: String?
    let role: String?
    let nickname: String?
}

enum TravelRole: String {
    case admin = "ADMIN"
    case user = "USER"
    case viewer = "VIEWER"
}

// MARK: - 미디어

/// 백엔드 TravelMedia
struct TravelMedia: Decodable, Identifiable, Hashable {
    let id: String
    let travelId: String?
    let uploadUserId: String?
    let originalFileName: String?
    let fileUrl: String?
    let thumbnailUrl: String?
    /// 중간 크기(2048px) JPEG — 뷰어용. 3단계 이후 업로드분에만 있고, 영상은 없다.
    let displayUrl: String?
    let mimeType: String?
    let fileSize: Int64?
    let width: Int?
    let height: Int?
    let duration: Int?
    let takenAt: String?
    let created: String?

    var isVideo: Bool {
        if let mimeType { return mimeType.hasPrefix("video/") }
        let ext = (fileUrl as NSString?)?.pathExtension.lowercased() ?? ""
        return ["mp4", "mov", "m4v", "webm", "avi"].contains(ext)
    }

    var originalURL: URL? { fileUrl.flatMap(URL.init(string:)) }
    var thumbURL: URL? { thumbnailUrl.flatMap(URL.init(string:)) }
    var displayURL: URL? { displayUrl.flatMap(URL.init(string:)) }

    /// 뷰어에서 큰 그림으로 시도할 URL 순서: display(빠르고 작음) → 원본. display 객체가 아직 없으면 원본으로.
    var viewerImageURLs: [URL] { [displayURL, originalURL].compactMap { $0 } }

    /// 그리드 셀에서 시도할 URL 순서. 영상 원본은 이미지로 디코딩할 수 없으니 썸네일만.
    var gridImageURLs: [URL] {
        isVideo ? [thumbURL].compactMap { $0 } : [thumbURL, originalURL].compactMap { $0 }
    }

    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        return String(format: "%d:%02d", duration / 60, duration % 60)
    }

    var takenDate: Date? { TravelDate.parseDateTime(takenAt) }
    var createdDate: Date? { TravelDate.parseDateTime(created) }
}

/// 앨범 필터 (백엔드 type 파라미터)
enum MediaFilter: String, CaseIterable, Identifiable {
    case all, image, video
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "전체"
        case .image: "사진"
        case .video: "영상"
        }
    }
}

/// 앨범 정렬 (백엔드 sort 파라미터)
enum MediaSort: String, CaseIterable, Identifiable {
    case createdDesc = "created_desc"
    case createdAsc = "created_asc"
    case takenDesc = "taken_desc"
    case takenAsc = "taken_asc"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .createdDesc: "최근 업로드순"
        case .createdAsc: "오래된 업로드순"
        case .takenDesc: "최근 촬영순"
        case .takenAsc: "오래된 촬영순"
        }
    }
}

struct CountResponse: Decodable {
    let count: Int
}

// MARK: - 날짜

/// 백엔드는 LocalDate("2026-10-03"), LocalDateTime("2026-10-03T19:35:49.123") 을 시간대 없이 보낸다.
/// 서버(서울) 기준 로컬 시각으로 해석한다.
nonisolated enum TravelDate {
    static let seoul = TimeZone(identifier: "Asia/Seoul")!

    static let dayFormatter: DateFormatter = make("yyyy.MM.dd")
    static let monthDayFormatter: DateFormatter = make("MM.dd")
    static let fullFormatter: DateFormatter = make("yyyy.MM.dd HH:mm")

    private static let isoDay: DateFormatter = make("yyyy-MM-dd")
    private static let isoDateTime: DateFormatter = make("yyyy-MM-dd'T'HH:mm:ss")

    static func parseDay(_ text: String?) -> Date? {
        guard let text, text.count >= 10 else { return nil }
        return isoDay.date(from: String(text.prefix(10)))
    }

    static func parseDateTime(_ text: String?) -> Date? {
        guard let text, text.count >= 19 else { return nil }
        return isoDateTime.date(from: String(text.prefix(19)))
    }

    /// 업로드 요청에 보낼 LocalDateTime 문자열
    static func serverString(_ date: Date) -> String {
        isoDateTime.string(from: date)
    }

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = seoul
        formatter.dateFormat = format
        return formatter
    }
}
