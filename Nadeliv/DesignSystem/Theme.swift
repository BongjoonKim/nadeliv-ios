import SwiftUI

/// 다크 세이지-그린 에디토리얼 브랜드 토큰.
/// 웹의 homeTokens.ts 와 같은 값을 쓴다. 화면 코드에서 색을 직접 쓰지 말고 이 토큰을 참조한다.
enum Theme {
    enum Color {
        static let bg = SwiftUI.Color(hex: 0x0A0B0A)
        static let surface = SwiftUI.Color(hex: 0x141714)
        static let surface2 = SwiftUI.Color(hex: 0x101210)
        static let surface3 = SwiftUI.Color(hex: 0x181B18)
        static let border = SwiftUI.Color.white.opacity(0.08)
        static let border2 = SwiftUI.Color.white.opacity(0.18)
        static let text = SwiftUI.Color(hex: 0xF3F4F1)
        static let textSoft = SwiftUI.Color(hex: 0xCDD6C5)
        static let textMuted = SwiftUI.Color(hex: 0x9AA399)
        static let textFaint = SwiftUI.Color(hex: 0x7E857D)
        static let heroTop = SwiftUI.Color(hex: 0x6A7D68)
        static let heroMid = SwiftUI.Color(hex: 0x46553F)
        static let heroBottom = SwiftUI.Color(hex: 0x28321F)
        static let accent = SwiftUI.Color(hex: 0x8FBF94)
        static let accentStrong = SwiftUI.Color(hex: 0x2E7D52)
        static let badgeBg = SwiftUI.Color(hex: 0x243124)
        static let badgeText = SwiftUI.Color(hex: 0xBCD0BB)
        static let danger = SwiftUI.Color(hex: 0xE08A7E)
    }

    static let heroGradient = LinearGradient(
        stops: [
            .init(color: Color.heroTop, location: 0),
            .init(color: Color.heroMid, location: 0.42),
            .init(color: Color.heroBottom, location: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 커버 사진이 없는 여행의 기본 썸네일. 웹 homeTokens.projectPalette 와 같은 순서·색.
    static let projectPalette: [(SwiftUI.Color, SwiftUI.Color)] = [
        (SwiftUI.Color(hex: 0x7A9A7E), SwiftUI.Color(hex: 0x3F5A45)), // sage
        (SwiftUI.Color(hex: 0x5F9097), SwiftUI.Color(hex: 0x2F5A60)), // teal
        (SwiftUI.Color(hex: 0x6F86AD), SwiftUI.Color(hex: 0x3B4D6E)), // dusty blue
        (SwiftUI.Color(hex: 0x8F78A3), SwiftUI.Color(hex: 0x54436A)), // plum
        (SwiftUI.Color(hex: 0xB07A86), SwiftUI.Color(hex: 0x6E4450)), // rose
        (SwiftUI.Color(hex: 0xBB7F5F), SwiftUI.Color(hex: 0x74472F)), // terracotta
        (SwiftUI.Color(hex: 0xC29D5E), SwiftUI.Color(hex: 0x7A5C2C)), // ochre
        (SwiftUI.Color(hex: 0x93965C), SwiftUI.Color(hex: 0x575A2F)), // olive
    ]

    enum Radius {
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
    }

    enum Font {
        /// 웹의 Noto Serif KR 제목 역할. 폰트 번들 전까지 시스템 serif 로 대체.
        static func serif(_ size: CGFloat, weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .serif)
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
