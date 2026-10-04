import SwiftUI

/// 후보 URL 을 순서대로 시도하는 원격 이미지.
/// 썸네일은 업로드 후 Lambda 가 비동기로 만들기 때문에 아직 없을 수 있다 → 원본으로 폴백.
struct RemoteImage<Placeholder: View>: View {
    let urls: [URL]
    let maxPixel: CGFloat
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: urls) {
            image = nil
            for url in urls {
                if let loaded = await ImageLoader.shared.image(for: url, maxPixel: maxPixel) {
                    image = loaded
                    return
                }
            }
        }
    }
}
