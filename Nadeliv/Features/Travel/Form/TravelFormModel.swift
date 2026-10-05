import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 여행 만들기·설정 폼에서 고치는 값.
struct TravelDraft: Equatable {
    var title = ""
    var destination = ""
    var hasDates = false
    var startDate = TravelFormModel.today
    var endDate = TravelFormModel.today
    var description = ""
    var tags: [String] = []
    var visibility: TravelVisibility = .private

    init() {}

    init(travel: Travel) {
        title = travel.title ?? ""
        destination = travel.destination ?? ""
        description = travel.description ?? ""
        tags = travel.tags ?? []
        visibility = travel.visibility ?? .private
        if let start = TravelDate.parseDay(travel.startDate) {
            hasDates = true
            startDate = start
            endDate = TravelDate.parseDay(travel.endDate) ?? start
        }
    }
}

/// 여행 만들기·설정 화면 상태. 웹 TravelCreateProject + TravelSettings(CoverImageField) 와 같은 규칙.
/// - 커버 사진은 고른 즉시 올리지 않고 저장할 때 올린다 (취소하면 아무것도 바뀌지 않게).
/// - 만들기: 여행을 만든 뒤 그 id 로 커버를 올리고 coverImageUrl 을 PUT 한다 (S3 key 에 travelId 가 들어가서).
@Observable
final class TravelFormModel {
    enum Mode {
        case create
        case edit(Travel)
    }

    enum CoverChange: Equatable {
        case unchanged
        /// 줄인 JPEG (긴 변 1600px)
        case replace(Data)
        case remove
    }

    /// 저장 결과. 만들기에서 여행은 생겼지만 커버만 실패하면 warning 이 있다.
    struct SaveResult {
        let travel: Travel
        let warning: String?
    }

    static let titleLimit = 100
    static let descriptionLimit = 2000
    static var today: Date { seoulCalendar.startOfDay(for: .now) }
    /// 날짜는 서버(서울) 기준 LocalDate 로 주고받는다. DatePicker 도 이 달력으로 보여준다.
    static let seoulCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TravelDate.seoul
        return calendar
    }()

    let mode: Mode
    var draft: TravelDraft
    private let original: TravelDraft
    private(set) var cover: CoverChange = .unchanged
    var tagInput = ""
    var deleteConfirmText = ""

    private(set) var isSaving = false
    private(set) var isPreparingCover = false
    private(set) var isDeleting = false
    var errorMessage: String?

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create: original = TravelDraft()
        case .edit(let travel): original = TravelDraft(travel: travel)
        }
        draft = original
    }

    var travel: Travel? {
        if case .edit(let travel) = mode { return travel }
        return nil
    }

    var isCreate: Bool { travel == nil }
    var isBusy: Bool { isSaving || isPreparingCover || isDeleting }
    var trimmedTitle: String { draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasChanges: Bool { draft != original || cover != .unchanged }
    var canSave: Bool { !trimmedTitle.isEmpty && !isBusy && (isCreate || hasChanges) }

    /// 서버는 null 을 "변경 없음"으로 봐서 날짜를 지울 수 없다 → 이미 날짜가 있는 여행은 끌 수 없게 한다.
    var canClearDates: Bool { !original.hasDates }

    /// 화면에 보여줄 커버: 새로 고른 사진 → (지우지 않았다면) 기존 커버 URL
    var coverPreviewData: Data? {
        if case .replace(let data) = cover { return data }
        return nil
    }

    var existingCoverURL: URL? {
        guard cover == .unchanged else { return nil }
        return travel?.coverImageUrl.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    var hasCover: Bool { coverPreviewData != nil || existingCoverURL != nil }

    /// 삭제 확인: 여행 이름을 그대로 입력해야 한다 (웹과 같음)
    var canDelete: Bool {
        guard let travel, !isBusy else { return false }
        return deleteConfirmText == travel.displayTitle
    }

    // MARK: - 입력

    func clampInputs() {
        if draft.title.count > Self.titleLimit { draft.title = String(draft.title.prefix(Self.titleLimit)) }
        if draft.description.count > Self.descriptionLimit {
            draft.description = String(draft.description.prefix(Self.descriptionLimit))
        }
        if draft.endDate < draft.startDate { draft.endDate = draft.startDate }
    }

    func addTag() {
        let tag = tagInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^#+", with: "", options: .regularExpression)
        tagInput = ""
        guard !tag.isEmpty, !draft.tags.contains(tag) else { return }
        draft.tags.append(tag)
    }

    func removeTag(_ tag: String) {
        draft.tags.removeAll { $0 == tag }
    }

    func pickCover(_ item: PhotosPickerItem) async {
        isPreparingCover = true
        defer { isPreparingCover = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CocoaError(.fileReadUnknown)
            }
            let jpeg = try await Task.detached(priority: .userInitiated) {
                try CoverImageProcessor.jpeg(from: data)
            }.value
            cover = .replace(jpeg)
        } catch {
            errorMessage = "이 사진을 불러오지 못했어요. 다른 사진을 골라 주세요."
        }
    }

    func removeCover() {
        // 새로 고른 사진만 있었다면 원래 상태로 되돌린다.
        if case .replace = cover, existingCoverURLIgnoringChange == nil {
            cover = .unchanged
        } else {
            cover = .remove
        }
    }

    private var existingCoverURLIgnoringChange: String? {
        travel?.coverImageUrl.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - 저장

    func save(api: APIClient) async -> SaveResult? {
        clampInputs()
        guard canSave else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            if let travel {
                return SaveResult(travel: try await update(travel, api: api), warning: nil)
            }
            return try await create(api: api)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func create(api: APIClient) async throws -> SaveResult {
        let dates = draft.hasDates
            ? (TravelDate.serverDay(draft.startDate), TravelDate.serverDay(draft.endDate))
            : nil
        let created = try await api.createTravel(TravelCreateRequest(
            title: trimmedTitle,
            description: nonEmpty(draft.description),
            visibility: draft.visibility,
            startDate: dates?.0,
            endDate: dates?.1,
            destination: nonEmpty(draft.destination),
            tags: draft.tags
        ))
        guard case .replace(let jpeg) = cover else { return SaveResult(travel: created, warning: nil) }
        do {
            let url = try await api.uploadCoverImage(travelId: created.id, jpeg: jpeg)
            let updated = try await api.updateTravel(id: created.id, TravelUpdateRequest(coverImageUrl: url))
            return SaveResult(travel: updated, warning: nil)
        } catch {
            return SaveResult(
                travel: created,
                warning: "여행은 만들었지만 커버 사진을 올리지 못했어요. 여행 설정에서 다시 올려 주세요."
            )
        }
    }

    private func update(_ travel: Travel, api: APIClient) async throws -> Travel {
        var request = TravelUpdateRequest()
        if trimmedTitle != original.title { request.title = trimmedTitle }
        if trimmed(draft.description) != original.description { request.description = trimmed(draft.description) }
        if trimmed(draft.destination) != original.destination { request.destination = trimmed(draft.destination) }
        if draft.tags != original.tags { request.tags = draft.tags }
        if draft.visibility != original.visibility { request.visibility = draft.visibility }
        if draft.hasDates,
           !original.hasDates || draft.startDate != original.startDate || draft.endDate != original.endDate {
            request.startDate = TravelDate.serverDay(draft.startDate)
            request.endDate = TravelDate.serverDay(draft.endDate)
        }
        switch cover {
        case .unchanged: break
        case .replace(let jpeg): request.coverImageUrl = try await api.uploadCoverImage(travelId: travel.id, jpeg: jpeg)
        // 서버는 null 을 "변경 없음"으로 보므로 빈 문자열로 지운다 (웹과 같음).
        case .remove: request.coverImageUrl = ""
        }
        guard !request.isEmpty else { return travel }
        return try await api.updateTravel(id: travel.id, request)
    }

    // MARK: - 삭제

    func delete(api: APIClient) async -> Bool {
        guard let travel, canDelete else { return false }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await api.deleteTravel(id: travel.id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nonEmpty(_ text: String) -> String? {
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }
}

/// 커버 사진을 긴 변 1600px JPEG 으로 줄인다 (웹 resizeImageFile 과 같은 기준). EXIF 회전을 반영한다.
nonisolated enum CoverImageProcessor {
    static func jpeg(from data: Data, maxPixel: Int = 1600, quality: CGFloat = 0.85) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}
