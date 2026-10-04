import Foundation
import Observation
import PhotosUI
import SwiftUI

/// 앱 전체에서 하나만 두는 업로드 대기열 (presigned 직접 업로드).
///
/// 흐름: 사진 선택 → 파일 준비(HEIC→JPEG·메타데이터) → `POST /media/uploads`(init)
///      → part 파일을 background URLSession 으로 S3 에 PUT → 모두 끝나면 `POST .../complete`.
/// 작업 기록은 디스크(UploadJobStore)에 남겨, 앱이 종료돼도 시스템이 올린 결과를 이어서 complete 한다.
@Observable
final class UploadManager {
    static let shared = UploadManager()

    typealias Job = UploadJobRecord

    private(set) var jobs: [Job]
    /// 여행별로 올라간 미디어. 앨범 화면이 이 배열의 새 항목을 목록에 반영한다.
    private(set) var uploaded: [String: [TravelMedia]] = [:]

    /// 전송 중인 part 의 보낸 바이트 (jobId → partNumber → bytes)
    private var inflight: [UUID: [Int: Int64]] = [:]
    /// 아직 파일로 만들지 않은 사진 선택기 항목 (메모리에만 있음)
    private var pickerItems: [UUID: PhotosPickerItem] = [:]
    /// 지금 URLSession 에 들어가 있는 part ("jobId|partNumber")
    private var liveTasks: Set<String> = []
    private var completing: [UUID: Task<Void, Never>] = [:]
    /// URL 만료(403)로 재발급을 기다리는 part. 모아서 한 번에 /parts 를 부른다 (S3 는 모든 part URL 이 같은 시각에 만료된다)
    private var refreshQueue: [UUID: Set<Int>] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var preparer: Task<Void, Never>?
    private var api: APIClient?

    private static let maxAttempts = 3
    private static let maxRefreshes = 5

    private init() {
        var records = UploadJobStore.load()
        // 파일을 만들기 전에 앱이 종료된 작업은 복구할 수 없다 (선택기 항목이 메모리에만 있었음)
        for index in records.indices where records[index].status == .waiting || records[index].status == .preparing {
            records[index].status = .failed
            records[index].errorMessage = "앱이 종료되어 업로드를 준비하지 못했습니다. 다시 선택해 주세요."
        }
        jobs = records
        UploadJobStore.removeOrphans(keeping: Set(records.map(\.id)))
        persist()
    }

    // MARK: - 화면에서 부르는 것

    /// 로그인된 API 클라이언트를 연결하고, 지난 실행에서 남은 작업을 이어서 처리한다.
    func configure(api: APIClient) {
        self.api = api
        Task { await reconcile() }
    }

    func enqueue(_ items: [PhotosPickerItem], travelId: String, api: APIClient) {
        guard !items.isEmpty else { return }
        self.api = api
        // 이전 묶음이 모두 끝났으면 진행 표시를 새로 시작한다
        if jobs.allSatisfy(\.isFinished) { clearFinished() }
        for item in items {
            let job = Job(travelId: travelId)
            pickerItems[job.id] = item
            jobs.append(job)
        }
        persist()
        startPreparerIfNeeded()
    }

    func retryFailed(api: APIClient) {
        self.api = api
        for index in jobs.indices where jobs[index].status == .failed {
            jobs[index].errorMessage = nil
            if jobs[index].allPartsDone {
                jobs[index].status = .completing
                runComplete(jobs[index].id)
            } else if jobs[index].uploadId != nil {
                jobs[index].status = .uploading
                for p in jobs[index].parts.indices { jobs[index].parts[p].attempts = 0 }
                submitPendingParts(jobs[index].id)
            } else if pickerItems[jobs[index].id] != nil {
                jobs[index].status = .waiting
            }
        }
        persist()
        startPreparerIfNeeded()
    }

    func clearFinished() {
        for job in jobs where job.isFinished {
            pickerItems[job.id] = nil
            inflight[job.id] = nil
            UploadJobStore.removeFiles(job.id)
        }
        jobs.removeAll(where: \.isFinished)
        persist()
    }

    // MARK: - 진행 요약 (여행별)

    struct Summary {
        let total: Int
        let done: Int
        let failed: Int
        /// 전체 진행률 0...1 (현재 파일 진행률 포함)
        let progress: Double
        var isActive: Bool { done + failed < total }
    }

    func summary(for travelId: String) -> Summary? {
        let mine = jobs.filter { $0.travelId == travelId }
        guard !mine.isEmpty else { return nil }
        var units = 0.0
        var done = 0
        var failed = 0
        for job in mine {
            switch job.status {
            case .done: done += 1; units += 1
            case .failed: failed += 1; units += 1
            case .uploading, .completing: units += progress(of: job)
            case .waiting, .preparing: break
            }
        }
        return Summary(total: mine.count, done: done, failed: failed, progress: units / Double(mine.count))
    }

    func firstError(for travelId: String) -> String? {
        jobs.first { $0.travelId == travelId && $0.status == .failed }?.errorMessage
    }

    /// 파일 하나의 진행률. 완료된 part + 전송 중인 바이트.
    func progress(of job: Job) -> Double {
        guard job.fileSize > 0 else { return 0 }
        let sent = job.doneBytes + (inflight[job.id]?.values.reduce(0, +) ?? 0)
        // complete 호출이 남아 있으니 1.0 은 done 에서만
        return min(Double(sent) / Double(job.fileSize), 0.99)
    }

    // MARK: - 준비 (순서대로 하나씩: 변환·쪼개기는 CPU·디스크를 많이 쓴다)

    private func startPreparerIfNeeded() {
        guard preparer == nil else { return }
        preparer = Task {
            while let index = jobs.firstIndex(where: { $0.status == .waiting && pickerItems[$0.id] != nil }) {
                await prepare(jobs[index].id)
            }
            preparer = nil
        }
    }

    private func prepare(_ id: UUID) async {
        guard let item = pickerItems[id], let api else { return }
        update(id) { $0.status = .preparing }

        var tempFile: URL?
        do {
            guard let picked = try await item.loadTransferable(type: PickedFile.self) else {
                throw UploadError.unreadable
            }
            tempFile = picked.url
            let prepared = try await UploadPreparer.prepare(picked.url)
            tempFile = prepared.fileURL
            let source = try UploadJobStore.adopt(prepared.fileURL, job: id)
            tempFile = nil
            let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
            guard size > 0 else { throw UploadError.unreadable }

            guard let travelId = jobs.first(where: { $0.id == id })?.travelId else { return }
            let response = try await api.initMediaUpload(travelId: travelId, request: MediaUploadInitRequest(
                fileName: prepared.fileName, contentType: prepared.mimeType, fileSize: size,
                width: prepared.width, height: prepared.height, duration: prepared.duration, takenAt: prepared.takenAt
            ))

            var parts: [Job.Part] = []
            if response.method == .multipart {
                let urls = response.parts
                let partSize = response.partSize
                let paths = try await Task.detached(priority: .utility) {
                    try UploadJobStore.split(source, job: id, parts: urls, partSize: partSize)
                }.value
                for (part, path) in zip(urls.sorted { $0.partNumber < $1.partNumber }, paths) {
                    parts.append(Job.Part(
                        partNumber: part.partNumber, size: part.size,
                        offset: Int64(part.partNumber - 1) * partSize, relativePath: path, url: part.url
                    ))
                }
            } else if let only = response.parts.first {
                parts.append(Job.Part(
                    partNumber: 1, size: size, offset: 0,
                    relativePath: UploadJobStore.relativePath(source), url: only.url
                ))
            } else {
                throw UploadError.badResponse
            }

            pickerItems[id] = nil
            update(id) {
                $0.fileName = prepared.fileName
                $0.mimeType = response.contentType ?? prepared.mimeType
                $0.fileSize = size
                $0.width = prepared.width
                $0.height = prepared.height
                $0.duration = prepared.duration
                $0.takenAt = prepared.takenAt
                $0.uploadId = response.uploadId
                $0.method = response.method
                $0.parts = parts
                $0.status = .uploading
            }
            submitPendingParts(id)
        } catch {
            if let tempFile { try? FileManager.default.removeItem(at: tempFile) }
            UploadJobStore.removeFiles(id)
            fail(id, error.localizedDescription)
        }
    }

    // MARK: - 전송

    /// - only: 특정 part 만 (재시도·재발급 뒤). nil 이면 안 끝난 part 전부 (시작·앱 재실행).
    private func submitPendingParts(_ id: UUID, only: Int? = nil) {
        guard let job = jobs.first(where: { $0.id == id }), job.status == .uploading else { return }
        let awaitingRefresh = refreshQueue[id] ?? []
        for part in job.parts where !part.isDone {
            if let only, part.partNumber != only { continue }
            // 새 URL 을 기다리는 part 를 옛 URL 로 다시 보내지 않는다
            if awaitingRefresh.contains(part.partNumber) { continue }
            let description = "\(id.uuidString)|\(part.partNumber)"
            guard !liveTasks.contains(description), let url = URL(string: part.url) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            if job.method == .single, let mimeType = job.mimeType {
                // 단일 PUT 은 Content-Type 이 서명에 들어 있다. 멀티파트 part 는 헤더 없이 보낸다
                request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            }
            liveTasks.insert(description)
            BackgroundUploadSession.shared.upload(
                request, fromFile: UploadJobStore.fileURL(part.relativePath), description: description
            )
        }
    }

    /// URLSession 콜백 (BackgroundUploadSession 이 MainActor 로 넘겨 준다)
    func taskDidSend(description: String, bytes: Int64) {
        guard let (id, partNumber) = parse(description) else { return }
        inflight[id, default: [:]][partNumber] = bytes
    }

    func taskDidComplete(description: String, status: Int?, error: Error?, responseBody: String?) {
        liveTasks.remove(description)
        guard let (id, partNumber) = parse(description),
              let jobIndex = jobs.firstIndex(where: { $0.id == id }),
              let partIndex = jobs[jobIndex].parts.firstIndex(where: { $0.partNumber == partNumber })
        else { return }
        inflight[id]?[partNumber] = nil
        guard jobs[jobIndex].status == .uploading else { return }

        if error == nil, let status, (200..<300).contains(status) {
            jobs[jobIndex].parts[partIndex].isDone = true
            if jobs[jobIndex].allPartsDone {
                jobs[jobIndex].status = .completing
                inflight[id] = nil
                persist()
                runComplete(id)
            } else {
                persist()
            }
            return
        }

        if let urlError = error as? URLError, urlError.code == .cancelled {
            return
        }

        if status == 403 {
            // presigned URL 만료 — 새 URL 을 받아 같은 part 를 다시 올린다
            jobs[jobIndex].parts[partIndex].refreshes += 1
            if jobs[jobIndex].parts[partIndex].refreshes > Self.maxRefreshes {
                fail(id, "업로드 링크가 계속 만료됩니다. 다시 시도해 주세요.")
                return
            }
            persist()
            queueRefresh(id, partNumber: partNumber)
            return
        }

        jobs[jobIndex].parts[partIndex].attempts += 1
        let attempts = jobs[jobIndex].parts[partIndex].attempts
        if attempts > Self.maxAttempts {
            let detail = error?.localizedDescription ?? status.map { "HTTP \($0)" } ?? "알 수 없는 오류"
            if let responseBody { print("[Upload] part \(partNumber) failed: \(responseBody.prefix(300))") }
            fail(id, "업로드에 실패했습니다. (\(detail))")
            return
        }
        persist()
        // 잠깐 쉬었다가 같은 URL 로 재시도 (일시적 네트워크·5xx)
        Task {
            try? await Task.sleep(for: .seconds(2 * attempts))
            submitPendingParts(id, only: partNumber)
        }
    }

    private func queueRefresh(_ id: UUID, partNumber: Int) {
        refreshQueue[id, default: []].insert(partNumber)
        guard refreshTasks[id] == nil else { return }
        refreshTasks[id] = Task {
            // 거의 동시에 만료된 다른 part 들의 403 을 잠깐 모은다
            try? await Task.sleep(for: .milliseconds(300))
            refreshTasks[id] = nil
            await refreshPartURLs(id)
        }
    }

    private func refreshPartURLs(_ id: UUID) async {
        let numbers = Array(refreshQueue[id] ?? []).sorted()
        guard !numbers.isEmpty, let api, let job = jobs.first(where: { $0.id == id }), let uploadId = job.uploadId else {
            refreshQueue[id] = nil
            return
        }
        do {
            let response = try await api.refreshUploadParts(travelId: job.travelId, uploadId: uploadId, partNumbers: numbers)
            update(id) { record in
                for fresh in response.parts {
                    if let p = record.parts.firstIndex(where: { $0.partNumber == fresh.partNumber }) {
                        record.parts[p].url = fresh.url
                    }
                }
            }
            refreshQueue[id] = nil
            for number in numbers { submitPendingParts(id, only: number) }
        } catch {
            refreshQueue[id] = nil
            fail(id, error.localizedDescription)
        }
    }

    // MARK: - complete

    private func runComplete(_ id: UUID) {
        guard completing[id] == nil else { return }
        completing[id] = Task {
            defer { completing[id] = nil }
            guard let api, let job = jobs.first(where: { $0.id == id }), let uploadId = job.uploadId else { return }
            do {
                let media = try await api.completeMediaUpload(travelId: job.travelId, uploadId: uploadId)
                update(id) {
                    $0.status = .done
                    $0.mediaId = media.id
                }
                uploaded[job.travelId, default: []].append(media)
                UploadJobStore.removeFiles(id)
            } catch {
                // part 는 다 올라가 있으니 "다시 시도" 에서 complete 만 다시 부른다
                fail(id, error.localizedDescription)
            }
        }
    }

    /// 백그라운드에서 깨어났을 때: complete 호출이 끝날 때까지(최대 limit) 기다린 뒤 시스템에 알린다
    func waitForPendingCompletes(upTo limit: Duration) async {
        let pending = Array(completing.values)
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for task in pending { await task.value } }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - 재실행·전경 복귀 시 이어서 처리

    /// URLSession 에 실제로 남아 있는 작업과 기록을 맞춘다.
    /// 끝났는데 complete 를 못 한 작업은 complete 하고, 올라가다 만 part 는 다시 넣는다.
    func reconcile() async {
        guard api != nil else { return }
        // 세션을 다시 만들면 앱이 죽어 있는 동안 끝난 part 의 완료 콜백이 밀려서 온다.
        // 잠깐 기다려 그 콜백을 먼저 받아야 이미 올라간 part 를 다시 보내지 않는다
        try? await Task.sleep(for: .seconds(2))
        liveTasks = await BackgroundUploadSession.shared.liveDescriptions()
        for job in jobs {
            switch job.status {
            case .uploading:
                if job.allPartsDone {
                    update(job.id) { $0.status = .completing }
                    runComplete(job.id)
                } else {
                    submitPendingParts(job.id)
                }
            case .completing:
                runComplete(job.id)
            case .waiting, .preparing, .done, .failed:
                break
            }
        }
        startPreparerIfNeeded()
    }

    // MARK: - helpers

    private func fail(_ id: UUID, _ message: String) {
        update(id) {
            $0.status = .failed
            $0.errorMessage = message
        }
        inflight[id] = nil
        refreshQueue[id] = nil
        refreshTasks[id]?.cancel()
        refreshTasks[id] = nil
        Task { await BackgroundUploadSession.shared.cancelTasks(withPrefix: id.uuidString) }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        persist()
    }

    private func persist() {
        UploadJobStore.save(jobs)
    }

    private func parse(_ description: String) -> (UUID, Int)? {
        let pieces = description.split(separator: "|")
        guard pieces.count == 2, let id = UUID(uuidString: String(pieces[0])), let part = Int(pieces[1]) else { return nil }
        return (id, part)
    }

    enum UploadError: LocalizedError {
        case unreadable
        case badResponse
        var errorDescription: String? {
            switch self {
            case .unreadable: "사진 보관함에서 파일을 읽지 못했습니다."
            case .badResponse: "서버 응답이 올바르지 않습니다."
            }
        }
    }
}
