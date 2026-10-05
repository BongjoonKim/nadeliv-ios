import Foundation

/// 여행·앨범 API. 화면은 이 함수들만 호출한다.
extension APIClient {
    func myTravels(page: Int, size: Int = 20) async throws -> TravelListResponse {
        try await get("api/v1/travels/my", query: [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "size", value: String(size)),
        ])
    }

    func travel(id: String) async throws -> Travel {
        try await get("api/v1/travels/\(id)")
    }

    // MARK: - 여행 만들기·수정·삭제 (수정·삭제는 ADMIN 만 — 서버가 검사한다)

    func createTravel(_ request: TravelCreateRequest) async throws -> Travel {
        try await postJSON("api/v1/travels", body: request)
    }

    /// nil 인 필드는 보내지 않고, 서버는 보내지 않은 필드를 바꾸지 않는다.
    func updateTravel(id: String, _ request: TravelUpdateRequest) async throws -> Travel {
        try await putJSON("api/v1/travels/\(id)", body: request)
    }

    /// 여행과 그 앨범·채널·멤버를 모두 지운다.
    func deleteTravel(id: String) async throws {
        try await delete("api/v1/travels/\(id)")
    }

    /// 커버 사진 업로드 (백엔드 /api/v1/files → 공개 S3 URL). 웹 CoverImageField 와 같은 key 규칙.
    func uploadCoverImage(travelId: String, jpeg: Data) async throws -> String {
        let key = "travel/\(travelId)/cover-\(UUID().uuidString.lowercased()).jpg"
        let response: FileUploadResponse = try await postMultipart(
            "api/v1/files",
            fields: ["fileKey": key],
            file: MultipartFile(fieldName: "file", fileName: "cover.jpg", mimeType: "image/jpeg", data: jpeg)
        )
        return response.url
    }

    func media(travelId: String, page: Int, size: Int, sort: MediaSort, filter: MediaFilter) async throws -> [TravelMedia] {
        try await get("api/v1/travels/\(travelId)/media", query: [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "type", value: filter.rawValue),
        ])
    }

    func mediaCount(travelId: String, filter: MediaFilter) async throws -> Int {
        let response: CountResponse = try await get(
            "api/v1/travels/\(travelId)/media/count",
            query: [URLQueryItem(name: "type", value: filter.rawValue)]
        )
        return response.count
    }

    func deleteMedia(travelId: String, mediaId: String) async throws {
        try await delete("api/v1/travels/\(travelId)/media/\(mediaId)")
    }

    // MARK: - presigned 직접 업로드 (백엔드 /media/uploads, 웹과 공용)

    /// 업로드 시작. 64MB 초과면 MULTIPART 로 part URL 들이 온다.
    func initMediaUpload(travelId: String, request: MediaUploadInitRequest) async throws -> MediaUploadInitResponse {
        try await postJSON("api/v1/travels/\(travelId)/media/uploads", body: request)
    }

    /// 만료된(403) part URL 재발급
    func refreshUploadParts(travelId: String, uploadId: String, partNumbers: [Int]) async throws -> MediaUploadInitResponse {
        try await postJSON(
            "api/v1/travels/\(travelId)/media/uploads/\(uploadId)/parts",
            body: MediaUploadPartsRequest(partNumbers: partNumbers)
        )
    }

    /// 모든 part 가 올라간 뒤 호출. 서버가 S3 를 확인하고 TravelMedia 를 만든다 (재호출해도 같은 미디어).
    func completeMediaUpload(travelId: String, uploadId: String) async throws -> TravelMedia {
        try await postJSON("api/v1/travels/\(travelId)/media/uploads/\(uploadId)/complete", body: EmptyBody())
    }

    func abortMediaUpload(travelId: String, uploadId: String) async throws {
        try await delete("api/v1/travels/\(travelId)/media/uploads/\(uploadId)")
    }
}

/// POST /api/v1/travels (백엔드 TravelCreateRequest). dashboardItems 는 안 보낸다 → 웹이 기본 구성을 쓴다.
nonisolated struct TravelCreateRequest: Encodable {
    var title: String
    var description: String?
    var visibility: TravelVisibility
    var startDate: String?
    var endDate: String?
    var destination: String?
    var tags: [String]
}

/// PUT /api/v1/travels/{id} (백엔드 TravelUpdateRequest). 바꾼 필드만 채운다.
/// 서버는 null 을 "변경 없음"으로 보므로 지우려면 빈 문자열·빈 배열을 보낸다. 날짜는 지울 수 없다.
nonisolated struct TravelUpdateRequest: Encodable {
    var title: String?
    var description: String?
    var coverImageUrl: String?
    var visibility: TravelVisibility?
    var startDate: String?
    var endDate: String?
    var destination: String?
    var tags: [String]?

    var isEmpty: Bool {
        title == nil && description == nil && coverImageUrl == nil && visibility == nil
            && startDate == nil && endDate == nil && destination == nil && tags == nil
    }
}

nonisolated struct FileUploadResponse: Decodable {
    let url: String
}

/// 본문 없는 POST 용 (서버는 @RequestBody 를 받지 않는다)
nonisolated struct EmptyBody: Encodable {}
