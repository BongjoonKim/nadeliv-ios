import Foundation

/// S3 presigned URL 로 part 를 올리는 background URLSession.
/// 앱이 백그라운드로 가거나 종료돼도 시스템이 전송을 이어가고, 끝나면 앱을 깨워 delegate 를 부른다.
/// delegate 콜백은 백그라운드 큐에서 오므로 이 타입은 nonisolated 로 두고, 결과만 MainActor 의 UploadManager 로 넘긴다.
nonisolated final class BackgroundUploadSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "com.nadeliv.app.travel-upload"
    static let shared = BackgroundUploadSession()

    private var session: URLSession!
    private let lock = NSLock()
    /// taskIdentifier → 응답 본문 앞부분 (S3 에러 XML 진단용)
    private var responseBodies: [Int: Data] = [:]
    private var completionHandler: (@MainActor @Sendable () -> Void)?

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        // 사용자가 직접 시작한 업로드 — 시스템이 "한가할 때"로 미루지 않게 한다
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 4
        // 백엔드 업로드 세션 TTL(48h) 과 맞춘다. 그 안에 못 끝내면 part URL·세션이 모두 만료된다
        config.timeoutIntervalForResource = 48 * 60 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// AppDelegate 가 받은 completionHandler. 이벤트 처리가 끝난 뒤 반드시 불러야 한다.
    func setCompletionHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        completionHandler = handler
    }

    /// `description` = "jobId|partNumber". 완료 콜백에서 어느 작업의 어느 part 인지 알아내는 데 쓴다.
    @discardableResult
    func upload(_ request: URLRequest, fromFile file: URL, description: String) -> URLSessionUploadTask {
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = description
        task.resume()
        return task
    }

    /// 살아 있는 작업의 description 목록. 앱 재실행 후 어떤 part 가 아직 올라가는 중인지 확인한다.
    func liveDescriptions() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { $0.state == .completed ? nil : $0.taskDescription })
    }

    func cancelTasks(withPrefix prefix: String) async {
        for task in await session.allTasks where task.taskDescription?.hasPrefix(prefix) == true {
            task.cancel()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        var body = responseBodies[dataTask.taskIdentifier] ?? Data()
        if body.count < 4096 { body.append(data.prefix(4096 - body.count)) }
        responseBodies[dataTask.taskIdentifier] = body
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let description = task.taskDescription else { return }
        Task { @MainActor in
            UploadManager.shared.taskDidSend(description: description, bytes: totalBytesSent)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = responseBodies.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let description = task.taskDescription else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let message = body.flatMap { String(data: $0, encoding: .utf8) }
        Task { @MainActor in
            UploadManager.shared.taskDidComplete(
                description: description, status: status, error: error, responseBody: message
            )
        }
    }

    /// 백그라운드에서 깨어나 밀린 이벤트를 모두 받은 뒤 호출된다.
    /// 마지막 part 가 끝났으면 complete API 까지 부른 다음 시스템에 끝났다고 알린다.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = completionHandler
        completionHandler = nil
        lock.unlock()
        Task { @MainActor in
            await UploadManager.shared.waitForPendingCompletes(upTo: .seconds(20))
            handler?()
        }
    }
}
