import AppKit
import CoreGraphics
import CoreText

// 앱 아이콘 렌더러 — 확정안 O1-didot-sage (2026-10-07). 실행: swift Tools/IconRender/render.swift <출력폴더>
// 결과 O1-didot-sage.png 를 Nadeliv/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png 로 복사한다.
// "Nv" 겹친 모노그램. v 둘레에 배경을 다시 칠한 틈(knockout)을 둬서 두 글자가 엮인 것처럼 보이게 한다.
let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func canvas() -> CGContext {
    CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
}

func save(_ ctx: CGContext, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

let heroTop: UInt32 = 0x6A7D68, heroMid: UInt32 = 0x46553F, heroBottom: UInt32 = 0x28321F
let text: UInt32 = 0xF3F4F1, badgeText: UInt32 = 0xBCD0BB, accent: UInt32 = 0x8FBF94, textSoft: UInt32 = 0xCDD6C5

func background(_ ctx: CGContext) {
    let stops: [(UInt32, CGFloat)] = [(heroTop, 0), (heroMid, 0.42), (heroBottom, 1)]
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { rgb($0.0) } as CFArray,
                       locations: stops.map { $0.1 })!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func font(_ name: String, _ pt: CGFloat) -> CTFont {
    if name == "serif-system" {
        let d = NSFont.systemFont(ofSize: pt, weight: .semibold).fontDescriptor.withDesign(.serif)!
        return NSFont(descriptor: d, size: pt)! as CTFont
    }
    return CTFontCreateWithName(name as CFString, pt, nil)
}

/// 글자 하나의 윤곽 (원점 = 기준선 왼쪽)
func glyphPath(_ ch: String, _ f: CTFont) -> CGPath {
    var chars = Array(ch.utf16), glyphs = [CGGlyph](repeating: 0, count: chars.count)
    CTFontGetGlyphsForCharacters(f, &chars, &glyphs, chars.count)
    return CTFontCreatePathForGlyph(f, glyphs[0], nil)!
}

struct Spec {
    let name: String
    let nFont: String, vFont: String
    let pt: CGFloat
    let vScale: CGFloat
    /// v 의 왼쪽 끝을 N 의 오른쪽 끝에서 얼마나 안쪽으로 넣을지 (N 너비 비율)
    let overlap: CGFloat
    /// v 를 기준선에서 얼마나 내릴지 (pt 비율)
    let drop: CGFloat
    let vColor: UInt32
    let gapWidth: CGFloat
}

func render(_ s: Spec) {
    let c = canvas()
    background(c)
    let n = glyphPath("N", font(s.nFont, s.pt))
    let v = glyphPath("v", font(s.vFont, s.pt * s.vScale))
    let nb = n.boundingBoxOfPath, vb = v.boundingBoxOfPath

    // 배치: v 의 왼쪽 끝 = N 오른쪽 끝 - overlap, v 는 기준선에서 drop 만큼 내린다
    let vx = nb.maxX - nb.width * s.overlap - vb.minX
    let vy = -s.pt * s.drop
    var vt = CGAffineTransform(translationX: vx, y: vy)
    let vMoved = v.copy(using: &vt)!
    let all = n.boundingBoxOfPath.union(vMoved.boundingBoxOfPath)
    // 묶음 전체를 시각적 가운데로
    var center = CGAffineTransform(translationX: (size - all.width) / 2 - all.minX, y: (size - all.height) / 2 - all.minY)
    let nPath = n.copy(using: &center)!, vPath = vMoved.copy(using: &center)!

    c.setFillColor(rgb(text)); c.addPath(nPath); c.fillPath()
    // knockout: v 윤곽을 두껍게 그린 영역에 배경을 다시 칠해 N 과의 사이에 틈을 만든다
    c.saveGState()
    c.addPath(vPath.copy(strokingWithWidth: s.gapWidth * 2, lineCap: .round, lineJoin: .round, miterLimit: 10))
    c.addPath(vPath)
    c.clip()
    background(c)
    c.restoreGState()
    c.setFillColor(rgb(s.vColor)); c.addPath(vPath); c.fillPath()
    save(c, s.name)
}

for s in [
    Spec(name: "O1-didot-sage", nFont: "Didot-Bold", vFont: "Didot-Bold", pt: 600, vScale: 1.0, overlap: 0.28, drop: 0.0, vColor: badgeText, gapWidth: 14),
    Spec(name: "O2-didot-accent", nFont: "Didot-Bold", vFont: "Didot-Bold", pt: 600, vScale: 1.0, overlap: 0.28, drop: 0.0, vColor: accent, gapWidth: 14),
    Spec(name: "O3-bodoni-italic", nFont: "BodoniSvtyTwoITCTT-Bold", vFont: "BodoniSvtyTwoITCTT-BookIta", pt: 600, vScale: 1.05, overlap: 0.26, drop: 0.0, vColor: badgeText, gapWidth: 14),
    Spec(name: "O4-newyork", nFont: "serif-system", vFont: "serif-system", pt: 560, vScale: 1.0, overlap: 0.26, drop: 0.0, vColor: badgeText, gapWidth: 14),
    Spec(name: "O5-didot-drop", nFont: "Didot-Bold", vFont: "Didot-Bold", pt: 600, vScale: 1.0, overlap: 0.30, drop: 0.14, vColor: badgeText, gapWidth: 14),
] { render(s) }
