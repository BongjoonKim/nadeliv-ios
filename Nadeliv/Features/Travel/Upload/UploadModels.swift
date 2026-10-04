import Foundation

// MARK: - presigned 업로드 API DTO (백엔드 MediaUpload* 와 1:1)

/// POST /api/v1/travels/{id}/media/uploads 요청
nonisolated struct MediaUploadInitRequest: Encodable {
    let fileName: String
    let contentType: String
    let fileSize: Int64
    let width: Int?
    let height: Int?
    let duration: Int?
    let takenAt: String?
}

nonisolated enum MediaUploadMethod: String, Codable {
    case single = "SINGLE"
    case multipart = "MULTIPART"
}

nonisolated struct MediaUploadPartURL: Decodable {
    let partNumber: Int
    /// 이 part 의 바이트 수. 서명에 포함되므로 정확히 이 크기로 PUT 해야 한다.
    let size: Int64
    let url: String
}

/// init·parts 응답.
/// - SINGLE: parts 1개. url 에 PUT, Content-Type 헤더 = contentType
/// - MULTIPART: parts N개. 각 url 에 해당 바이트 범위를 PUT (Content-Type 없이)
nonisolated struct MediaUploadInitResponse: Decodable {
    let uploadId: String
    let method: MediaUploadMethod
    let contentType: String?
    let partSize: Int64
    let partCount: Int
    let parts: [MediaUploadPartURL]
    let urlExpiresAt: String?
    let sessionExpiresAt: String?
}

nonisolated struct MediaUploadPartsRequest: Encodable {
    let partNumbers: [Int]
}
