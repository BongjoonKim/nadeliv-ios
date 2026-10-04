import Foundation
import Observation
import PhotosUI
import SwiftUI

/// 앱 전체에서 하나만 두는 업로드 대기열.
/// 앨범 화면을 벗어나도 업로드가 이어지고, 한 번에 하나씩 순서대로 올린다.
///
/// 지금은 앱이 켜져 있을 때만 올라간다 (기존 multipart API).
/// 백엔드 presigned 업로드가 배포되면 background URLSession 으로 바꿔
/// 앱을 닫아도 이어지게 한다 — 이 클래스 안에서만 바꾸면 된다.
@Observable
final class UploadManager {
    struct Job: Identifiable {
        enum State: Equatable {
            case waiting
            case preparing
            case uploading(Double)
            case done
            case failed(String)
        }

        let id = UUID()
        let travelId: String
        let item: PhotosPickerItem
        var state: State = .waiting

        var isFinished: Bool {
            switch state {
            case .done, .failed: true
            default: false
            }
        }
    }

    private(set) var jobs: [Job] = []
    /// 여행별로 올라간 미디어. 앨범 화면이 이 배열의 새 항목을 목록에 반영한다.
    private(set) var uploaded: [String: [TravelMedia]] = [:]

    private var worker: Task<Void, Never>?

    func enqueue(_ items: [PhotosPickerItem], travelId: String, api: APIClient) {
        guard !items.isEmpty else { return }
        // 이전 묶음이 모두 끝났으면 진행 표시를 새로 시작한다.
        if jobs.allSatisfy(\.isFinished) {
            jobs.removeAll()
        }
        jobs += items.map { Job(travelId: travelId, item: $0) }
        startWorkerIfNeeded(api: api)
    }

    func retryFailed(api: APIClient) {
        for index in jobs.indices {
            if case .failed = jobs[index].state { jobs[index].state = .waiting }
        }
        startWorkerIfNeeded(api: api)
    }

    func clearFinished() {
        jobs.removeAll(where: \.isFinished)
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
            switch job.state {
            case .done: done += 1; units += 1
            case .failed: failed += 1; units += 1
            case .uploading(let p): units += p
            default: break
            }
        }
        return Summary(total: mine.count, done: done, failed: failed, progress: units / Double(mine.count))
    }

    func firstError(for travelId: String) -> String? {
        for job in jobs where job.travelId == travelId {
            if case .failed(let message) = job.state { return message }
        }
        return nil
    }

    // MARK: - 작업 처리

    private func startWorkerIfNeeded(api: APIClient) {
        guard worker == nil else { return }
        worker = Task {
            while let index = jobs.firstIndex(where: { $0.state == .waiting }) {
                await run(index: index, api: api)
            }
            worker = nil
        }
    }

    private func run(index: Int, api: APIClient) async {
        let jobId = jobs[index].id
        let travelId = jobs[index].travelId
        let item = jobs[index].item
        update(jobId) { $0.state = .preparing }

        var tempFiles: [URL] = []
        defer { tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        do {
            guard let picked = try await item.loadTransferable(type: PickedFile.self) else {
                throw UploadError.unreadable
            }
            tempFiles.append(picked.url)
            let prepared = try await UploadPreparer.prepare(picked.url)
            tempFiles.append(prepared.fileURL)
            let boundary = "nadeliv-\(UUID().uuidString)"
            let body = try await Task.detached(priority: .utility) {
                try MultipartBuilder.build(prepared, boundary: boundary)
            }.value
            tempFiles.append(body)

            update(jobId) { $0.state = .uploading(0) }
            let media = try await api.uploadMedia(
                travelId: travelId, multipartFile: body, boundary: boundary
            ) { [weak self] fraction in
                self?.update(jobId) { $0.state = .uploading(min(fraction, 0.99)) }
            }
            update(jobId) { $0.state = .done }
            uploaded[travelId, default: []].append(media)
        } catch {
            update(jobId) { $0.state = .failed(error.localizedDescription) }
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    enum UploadError: LocalizedError {
        case unreadable
        var errorDescription: String? { "사진 보관함에서 파일을 읽지 못했습니다." }
    }
}
