import Foundation
import Photos
import UIKit

/// PhotoKit 을 감싼 작은 도우미. 백그라운드 큐에서 불리는 콜백은 여기(nonisolated) 안에서만 만든다.
nonisolated enum PhotoLibrary {
    /// 그리드 썸네일 전용 캐시 매니저 (PhotoKit 이 내부에서 큐를 관리한다)
    static let imageManager = PHCachingImageManager()

    /// 전체 접근(.readWrite)을 요청한다. 선택기는 "읽기"만 필요하지만 PhotoKit 의 읽기 권한 단계가 readWrite 다.
    static func requestAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != .notDetermined { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// 썸네일을 흐린 것 → 선명한 것 순으로 흘려보낸다. 구독이 끝나면(셀이 사라지면) 요청도 취소한다.
    static func thumbnails(for asset: PHAsset, pixel: CGFloat) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let request = imageManager.requestImage(
                for: asset, targetSize: CGSize(width: pixel, height: pixel), contentMode: .aspectFill, options: options
            ) { image, info in
                if let image { continuation.yield(image) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if !degraded || cancelled || info?[PHImageErrorKey] != nil {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in imageManager.cancelImageRequest(request) }
        }
    }

    /// 제한된 접근일 때 "더 선택" 시스템 화면을 띄운다.
    @MainActor
    static func presentLimitedLibraryPicker() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              var controller = scene.keyWindow?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }
}

/// 사진 보관함 변경(촬영·삭제·제한 범위 변경) 알림. PhotoKit 은 백그라운드 큐에서 부르므로 격리하지 않는다.
nonisolated final class PhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
