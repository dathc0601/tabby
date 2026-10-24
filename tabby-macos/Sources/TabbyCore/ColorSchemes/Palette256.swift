import Foundation

/// Tabby's `generatePalette` (tabby-terminal/src/generatePalette.ts): the 240 colours from
/// index 16 up, interpolated in CIELAB between the background, the foreground and the first
/// eight scheme colours. Colours a scheme defines beyond index 15 are kept.
public enum Palette256 {
    struct LAB { var l, a, b: Double }

    public static func generate(colors: [String], background: String, foreground: String, harmonious: Bool) -> [String] {
        let base = (0..<8).map { lab(colors.indices.contains($0) ? colors[$0] : "#000000") }
        let bg = lab(background), fg = lab(foreground)
        let invert = fg.l < bg.l && !harmonious
        let corner0 = invert ? fg : bg, corner7 = invert ? bg : fg
        var palette: [String] = []
        var index = 16
        func own() -> String? { colors.indices.contains(index) ? colors[index] : nil }
        for ri in 0..<6 {
            let tr = Double(ri) / 5
            let c0 = lerp(tr, corner0, base[1]), c1 = lerp(tr, base[2], base[3])
            let c2 = lerp(tr, base[4], base[5]), c3 = lerp(tr, base[6], corner7)
            for gi in 0..<6 {
                let tg = Double(gi) / 5
                let c4 = lerp(tg, c0, c1), c5 = lerp(tg, c2, c3)
                for bi in 0..<6 {
                    palette.append(own() ?? hex(lerp(Double(bi) / 5, c4, c5)))
                    index += 1
                }
            }
        }
        for i in 0..<24 {
            palette.append(own() ?? hex(lerp(Double(i + 1) / 25, corner0, corner7)))
            index += 1
        }
        return palette
    }

    static func lab(_ hexString: String) -> LAB {
        let rgb = RGBColor(hex: hexString) ?? RGBColor(r: 0, g: 0, b: 0)
        func linear(_ c: Double) -> Double {
            // Tabby parses whole bytes; RGBColor keeps them as byte / 255.
            let v = (c * 255).rounded() / 255
            return v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92
        }
        let r = linear(rgb.r), g = linear(rgb.g), b = linear(rgb.b)
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        let x = f((r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047)
        let y = f(r * 0.2126729 + g * 0.7151522 + b * 0.0721750)
        let z = f((r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883)
        return LAB(l: 116 * y - 16, a: 500 * (x - y), b: 200 * (y - z))
    }

    static func hex(_ lab: LAB) -> String {
        let y = (lab.l + 16) / 116, x = lab.a / 500 + y, z = y - lab.b / 200
        func back(_ t: Double) -> Double { let t3 = t * t * t; return t3 > 0.008856 ? t3 : (t - 16 / 116) / 7.787 }
        let xf = back(x) * 0.95047, yf = back(y), zf = back(z) * 1.08883
        func gamma(_ c: Double) -> Int {
            let v = c > 0.0031308 ? 1.055 * pow(c, 1 / 2.4) - 0.055 : 12.92 * c
            return Int((min(max(v, 0), 1) * 255).rounded(.toNearestOrAwayFromZero))
        }
        let r = gamma(xf * 3.2404542 - yf * 1.5371385 - zf * 0.4985314)
        let g = gamma(-xf * 0.9692660 + yf * 1.8760108 + zf * 0.0415560)
        let b = gamma(xf * 0.0556434 - yf * 0.2040259 + zf * 1.0572252)
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    static func lerp(_ t: Double, _ a: LAB, _ b: LAB) -> LAB {
        LAB(l: a.l + t * (b.l - a.l), a: a.a + t * (b.a - a.a), b: a.b + t * (b.b - a.b))
    }
}
