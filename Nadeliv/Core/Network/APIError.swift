import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case server(status: Int, message: String?)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "로그인이 필요합니다."
        case .server(_, let message?):
            return message
        case .server(403, nil):
            return "권한이 없습니다."
        case .server(let status, nil):
            return "서버 오류가 발생했습니다. (\(status))"
        case .decoding:
            return "응답을 해석하지 못했습니다."
        case .transport:
            return "서버에 연결할 수 없습니다. 네트워크를 확인해 주세요."
        }
    }
}

/// 백엔드 에러 응답 본문.
/// - CustomException(ErrorResponse): { "msg": "한국어 문구", "code": "TRV_017", ... }
/// - 인증 필터 등: { "message": "...", "error": "..." }
struct ServerErrorBody: Decodable {
    let msg: String?
    let message: String?

    /// 사용자에게 보여줄 문구. 업무 에러의 msg 를 우선한다.
    var displayMessage: String? { msg ?? message }
}
