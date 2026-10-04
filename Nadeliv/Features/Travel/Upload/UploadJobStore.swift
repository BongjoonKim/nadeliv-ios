import Foundation

/// 디스크에 남는 업로드 작업 기록. 앱이 종료돼도 background URLSession 이 올린 결과를 이어서 처리하기 위해 저장한다.
nonisolated struct UploadJobRecord: Codable, Identifiable {
    nonisolated enum Status: String, Codable {
        /// 사진 선택기 항목만 있고 파일은 아직 없음 (앱이 죽으면 복구 불가)
        case waiting
        /// 파일 변환·init 호출 중
        case preparing
        /// part 들이 S3 로 올라가는 중
        case uploading
        /// 모든 part 완료, complete 호출 대기/진행
        case completing
        case done
        case failed
    }

    nonisolated struct Part: Codable {
        let partNumber: Int
        let size: Int64
        let offset: Int64
        /// 업로드할 파일 (uploads 폴더 기준 상대 경로). SINGLE 은 원본 파일 그대로.
        var relativePath: String
        var url: String
        var isDone = false
        /// 같은 URL 로 다시 시도한 횟수 (네트워크·5xx)
        var attempts = 0
        /// URL 만료(403)로 재발급한 횟수
        var refreshes = 0
    }

    let id: UUID
    let travelId: String
    var status: Status
    var errorMessage: String?

    // 준비 결과
    var fileName: String?
    var mimeType: String?
    var fileSize: Int64 = 0
    var width: Int?
    var height: Int?
    var duration: Int?
    var takenAt: String?

    // init 결과
    var uploadId: String?
    var method: MediaUploadMethod?
    var parts: [Part] = []
    /// complete 결과 — 앨범에 반영된 뒤에도 기록에 남겨 중복 반영을 막는다
    var mediaId: String?

    init(id: UUID = UUID(), travelId: String) {
        self.id = id
        self.travelId = travelId
        self.status = .waiting
    }

    var isFinished: Bool { status == .done || status == .failed }
    var doneBytes: Int64 { parts.filter(\.isDone).reduce(0) { $0 + $1.size } }
    var allPartsDone: Bool { !parts.isEmpty && parts.allSatisfy(\.isDone) }
}

/// 작업 기록(JSON)과 업로드용 파일을 Application Support/uploads 아래에 둔다.
/// tmp 폴더는 시스템이 지울 수 있어 쓰지 않는다.
nonisolated enum UploadJobStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: "uploads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 백업 제외 (대용량 임시 파일)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
        return dir
    }()

    private static let recordsURL = directory.appending(path: "jobs.json")

    static func load() -> [UploadJobRecord] {
        guard let data = try? Data(contentsOf: recordsURL) else { return [] }
        return (try? JSONDecoder().decode([UploadJobRecord].self, from: data)) ?? []
    }

    static func save(_ records: [UploadJobRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: recordsURL, options: .atomic)
    }

    static func jobDirectory(_ id: UUID) -> URL {
        let dir = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(_ relativePath: String) -> URL {
        directory.appending(path: relativePath)
    }

    static func relativePath(_ url: URL) -> String {
        let base = directory.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        return full.hasPrefix(base) ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
    }

    static func removeFiles(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appending(path: id.uuidString))
    }

    /// 기록에 없는 작업 폴더를 지운다 (비정상 종료로 남은 찌꺼기)
    static func removeOrphans(keeping ids: Set<UUID>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name != "jobs.json" {
            if let id = UUID(uuidString: name), ids.contains(id) { continue }
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    // MARK: - 파일 준비

    /// 준비된 파일을 작업 폴더로 옮긴다 (같은 볼륨이라 복사 없이 이름만 바뀐다).
    static func adopt(_ source: URL, job id: UUID) throws -> URL {
        let target = jobDirectory(id).appending(path: "source." + source.pathExtension)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }

    /// 멀티파트: 원본을 part 파일로 쪼갠다. background URLSession 은 파일 단위로만 올릴 수 있다.
    /// 쪼갠 뒤 원본은 지워 디스크 사용량이 2배로 오래 남지 않게 한다.
    static func split(_ source: URL, job id: UUID, parts: [MediaUploadPartURL], partSize: Int64) throws -> [String] {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let dir = jobDirectory(id)
        var paths: [String] = []
        for part in parts.sorted(by: { $0.partNumber < $1.partNumber }) {
            let target = dir.appending(path: "part-\(part.partNumber)")
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let writer = try FileHandle(forWritingTo: target)
            defer { try? writer.close() }
            try reader.seek(toOffset: UInt64(Int64(part.partNumber - 1) * partSize))
            var remaining = part.size
            while remaining > 0 {
                let chunk = try reader.read(upToCount: Int(min(remaining, 8 * 1024 * 1024))) ?? Data()
                if chunk.isEmpty { throw CocoaError(.fileReadCorruptFile) }
                try writer.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            paths.append(relativePath(target))
        }
        try? FileManager.default.removeItem(at: source)
        return paths
    }
}
