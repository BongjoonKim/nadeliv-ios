import Foundation

/// 본문이 없는 응답(204 등)을 받을 때 쓰는 타입.
struct EmptyResponse: Decodable {}

/// 백엔드 HTTP 클라이언트.
/// - 인증이 필요한 요청은 Bearer 액세스 토큰을 붙이고, 401 이면 refresh 후 한 번만 재시도한다.
/// - 웹 프론트의 useAuthEP() 와 같은 역할.
/// - 파일 전송은 여기서 하지 않는다. 여행 미디어는 presigned URL 로 S3 에 직접 올린다 (BackgroundUploadSession).
final class APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    /// 현재 액세스 토큰. 웹과 같이 메모리에만 둔다 (refresh 토큰만 Keychain).
    var accessToken: String?
    /// 401 을 받았을 때 호출된다. 새 액세스 토큰을 돌려주거나, 실패하면 throw.
    var refreshHandler: (() async throws -> String)?

    init(baseURL: URL = AppConfig.backendURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: - Public

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], authorized: Bool = true) async throws -> T {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = "GET"
        return try await send(request, authorized: authorized)
    }

    func postJSON<T: Decodable, Body: Encodable>(_ path: String, body: Body, authorized: Bool = true) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, authorized: authorized)
    }

    /// application/x-www-form-urlencoded POST. 로그인(/ps/login)이 이 형식만 받는다.
    func postForm<T: Decodable>(_ path: String, fields: [String: String], authorized: Bool = false) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents 는 '+' 를 인코딩하지 않으므로 폼 본문에서는 직접 바꿔준다.
        let encoded = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        request.httpBody = Data(encoded.utf8)
        return try await send(request, authorized: authorized)
    }

    func delete(_ path: String) async throws {
        var request = URLRequest(url: url(path))
        request.httpMethod = "DELETE"
        let _: EmptyResponse = try await send(request, authorized: true)
    }

    // MARK: - Private

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        return url
    }

    private func send<T: Decodable>(
        _ request: URLRequest,
        authorized: Bool,
        isRetry: Bool = false,
        perform: ((URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> T {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized {
            guard let token = accessToken else { throw APIError.unauthorized }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            if let perform {
                (data, response) = try await perform(request)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch {
            throw APIError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401, authorized, !isRetry, let refreshHandler {
            accessToken = try await refreshHandler()
            return try await send(request, authorized: authorized, isRetry: true, perform: perform)
        }
        if status == 401, authorized {
            throw APIError.unauthorized
        }
        guard (200..<300).contains(status) else {
            let body = try? decoder.decode(ServerErrorBody.self, from: data)
            throw APIError.server(status: status, message: body?.displayMessage)
        }

        if data.isEmpty, let empty = EmptyResponse() as? T {
            return empty
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}
