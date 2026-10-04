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

/// 본문 없는 POST 용 (서버는 @RequestBody 를 받지 않는다)
nonisolated struct EmptyBody: Encodable {}
