import UIKit
import ImageIO

/// 원격 이미지를 받아 화면 크기에 맞게 줄여(downsample) 메모리 캐시에 둔다.
/// 여행 앨범은 수백 장의 원본 사진을 다루므로, 원본 해상도로 디코딩하지 않는 것이 핵심이다.
actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    init() {
        cache.totalCostLimit = 150 * 1024 * 1024 // 디코딩된 픽셀 기준 약 150MB
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 500 * 1024 * 1024
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    /// - maxPixel: 긴 변 기준 최대 픽셀. 셀 크기 × 화면 배율 정도를 넘긴다.
    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let task = inFlight[key as String] { return await task.value }

        let session = self.session
        let task = Task<UIImage?, Never> {
            guard
                let (data, response) = try? await session.data(from: url),
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    private nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // EXIF 회전 반영
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
