import SwiftUI

/// 여행 커버. 커버 사진이 없거나 실패하면 id 해시로 고른 팔레트 그라데이션을 쓴다.
/// 해시는 웹 getTravelProjectColor 와 같은 방식이라 웹·앱에서 같은 색이 나온다.
struct TravelThumb: View {
    let travel: Travel

    var body: some View {
        // overlay 는 바탕(그라데이션) 크기를 따르므로, 꽉 채운(fill) 사진이 바깥으로 넘치지 않고 잘린다.
        gradient
            .overlay {
                if let url = travel.coverImageUrl.flatMap(URL.init(string:)) {
                    RemoteImage(urls: [url], maxPixel: 900) { Color.clear }
                        .allowsHitTesting(false)
                }
            }
            .clipped()
    }

    private var gradient: some View {
        let colors = Self.paletteColors(seed: travel.id)
        return LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func paletteColors(seed: String) -> (Color, Color) {
        var hash: Int32 = 0
        for unit in seed.utf16 {
            hash = hash &* 31 &+ Int32(unit)
        }
        let index = Int(abs(Int64(hash)) % Int64(Theme.projectPalette.count))
        return Theme.projectPalette[index]
    }
}
