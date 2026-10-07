import Foundation
import Observation
import PhotosUI
import SwiftUI

/// 프로필 편집(이름·생일·사진) 상태. 웹 ProfileInfo 와 같은 API (`PUT /api/v1/user/profile`).
/// - 사진은 고른 즉시 올리지 않고 저장할 때 올린다 (취소하면 아무것도 바뀌지 않게) — 여행 커버와 같은 규칙.
/// - 이메일은 앱에서 바꾸지 않는다.
@Observable
final class ProfileEditModel {
    enum PhotoChange: Equatable {
        case unchanged
        /// 줄인 JPEG (긴 변 512px)
        case replace(Data)
        case remove
    }

    static let nameLimit = 30

    let profile: UserProfile
    var name: String
    var hasBirthday: Bool
    var birthday: Date
    private(set) var photo: PhotoChange = .unchanged

    private(set) var isSaving = false
    private(set) var isPreparingPhoto = false
    var errorMessage: String?

    init(profile: UserProfile) {
        self.profile = profile
        name = profile.name ?? ""
        hasBirthday = profile.birthdayDate != nil
        birthday = profile.birthdayDate ?? ProfileDate.calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))!
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBusy: Bool { isSaving || isPreparingPhoto }

    /// 서버는 null 을 "변경 없음"으로 봐서 생일을 지울 수 없다 → 이미 생일이 있으면 끌 수 없게 한다.
    var canClearBirthday: Bool { profile.birthdayDate == nil }

    var birthdayChanged: Bool {
        guard hasBirthday else { return false }
        guard let original = profile.birthdayDate else { return true }
        return !ProfileDate.calendar.isDate(birthday, inSameDayAs: original)
    }

    var hasChanges: Bool { trimmedName != (profile.name ?? "") || birthdayChanged || photo != .unchanged }
    var canSave: Bool { !trimmedName.isEmpty && hasChanges && !isBusy }

    /// 화면에 보여줄 사진: 새로 고른 사진 → (빼지 않았다면) 기존 사진
    var photoPreviewData: Data? {
        if case .replace(let data) = photo { return data }
        return nil
    }

    var existingPhotoURL: URL? { photo == .unchanged ? profile.photoURL : nil }
    var hasPhoto: Bool { photoPreviewData != nil || existingPhotoURL != nil }

    // MARK: - 입력

    func clampInputs() {
        if name.count > Self.nameLimit { name = String(name.prefix(Self.nameLimit)) }
    }

    func pickPhoto(_ item: PhotosPickerItem) async {
        isPreparingPhoto = true
        defer { isPreparingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CocoaError(.fileReadUnknown)
            }
            let jpeg = try await Task.detached(priority: .userInitiated) {
                try CoverImageProcessor.jpeg(from: data, maxPixel: 512)
            }.value
            photo = .replace(jpeg)
        } catch {
            errorMessage = "이 사진을 불러오지 못했어요. 다른 사진을 골라 주세요."
        }
    }

    func removePhoto() {
        // 새로 고른 사진만 있었다면 원래 상태로 되돌린다.
        if case .replace = photo, profile.photoURL == nil {
            photo = .unchanged
        } else {
            photo = .remove
        }
    }

    // MARK: - 저장

    func save(api: APIClient) async -> UserProfile? {
        clampInputs()
        guard canSave else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            var request = ProfileUpdateRequest()
            if trimmedName != (profile.name ?? "") { request.name = trimmedName }
            if birthdayChanged { request.birthday = ProfileDate.serverDateTime(birthday) }
            switch photo {
            case .unchanged: break
            case .replace(let jpeg):
                request.src = try await api.uploadProfilePhoto(userId: profile.userId ?? "me", jpeg: jpeg)
            // 서버는 null 을 "변경 없음"으로 보므로 빈 문자열로 지운다.
            case .remove: request.src = ""
            }
            guard !request.isEmpty else { return profile }
            return try await api.updateMyProfile(request)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
