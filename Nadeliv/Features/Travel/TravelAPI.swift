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

    /// 기존 multipart 업로드 (POST /media). 백엔드 presigned 업로드가 배포되면 교체한다.
    func uploadMedia(
        travelId: String,
        multipartFile: URL,
        boundary: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> TravelMedia {
        try await uploadFile(
            "api/v1/travels/\(travelId)/media",
            fileURL: multipartFile,
            contentType: "multipart/form-data; boundary=\(boundary)",
            progress: progress
        )
    }
}
