import Foundation

/// An sRGB colour with helpers matching the `color` npm package that Tabby's theme code
/// uses (`darken`/`lighten` scale HSL lightness, `fade` scales alpha).
public struct RGBColor: Hashable, Sendable, CustomStringConvertible {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
        self.a = min(max(a, 0), 1)
    }

    /// Parses `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(r, g, b)` and `rgba(r, g, b, a)`.
    public init?(hex input: String) {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("rgb") {
            guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
            let parts = s[s.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else { return nil }
            let a = parts.count > 3 ? Double(parts[3]) ?? 1 : 1
            self.init(r: r / 255, g: g / 255, b: b / 255, a: a)
            return
        }
        var hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 8 {
            self.init(r: Double((v >> 24) & 0xff) / 255, g: Double((v >> 16) & 0xff) / 255,
                      b: Double((v >> 8) & 0xff) / 255, a: Double(v & 0xff) / 255)
        } else {
            self.init(r: Double((v >> 16) & 0xff) / 255, g: Double((v >> 8) & 0xff) / 255, b: Double(v & 0xff) / 255)
        }
    }

    public var hex: String {
        let ri = Int((r * 255).rounded()), gi = Int((g * 255).rounded()), bi = Int((b * 255).rounded())
        if a < 1 {
            return String(format: "#%02x%02x%02x%02x", ri, gi, bi, Int((a * 255).rounded()))
        }
        return String(format: "#%02x%02x%02x", ri, gi, bi)
    }

    public var description: String { hex }

    // MARK: WCAG

    public var luminance: Double {
        func ch(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
    }

    public func contrast(with other: RGBColor) -> Double {
        let l1 = luminance, l2 = other.luminance
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    // MARK: HSL

    var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    init(h: Double, s: Double, l: Double, a: Double) {
        func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        if s == 0 {
            self.init(r: l, g: l, b: l, a: a)
        } else {
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            self.init(r: hue(p, q, h + 1 / 3), g: hue(p, q, h), b: hue(p, q, h - 1 / 3), a: a)
        }
    }

    /// `Color(x).darken(f)`: lightness × (1 − f).
    public func darken(_ f: Double) -> RGBColor {
        let c = hsl
        return RGBColor(h: c.h, s: c.s, l: min(max(c.l - c.l * f, 0), 1), a: a)
    }

    /// `Color(x).lighten(f)`: lightness × (1 + f).
    public func lighten(_ f: Double) -> RGBColor {
        let c = hsl
        return RGBColor(h: c.h, s: c.s, l: min(max(c.l + c.l * f, 0), 1), a: a)
    }

    /// `Color(x).fade(f)`: alpha × (1 − f).
    public func fade(_ f: Double) -> RGBColor {
        RGBColor(r: r, g: g, b: b, a: a * (1 - f))
    }

    public func mix(_ other: RGBColor, _ t: Double) -> RGBColor {
        RGBColor(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a + (other.a - a) * t)
    }

    /// Moves lightness away from `background` until the WCAG contrast reaches `ratio`.
    public func ensuringContrast(_ ratio: Double, against background: RGBColor) -> RGBColor {
        if contrast(with: background) >= ratio { return self }
        let towardsWhite = background.luminance < 0.5
        var c = self
        for step in 1...20 {
            let t = Double(step) / 20
            c = mix(towardsWhite ? RGBColor(r: 1, g: 1, b: 1) : RGBColor(r: 0, g: 0, b: 0), t)
            if c.contrast(with: background) >= ratio { break }
        }
        return c
    }

    public func withAlpha(_ alpha: Double) -> RGBColor { RGBColor(r: r, g: g, b: b, a: alpha) }

    // MARK: OKLab (the phase 2 design mixes colours like CSS `color-mix(in oklab, …)`)

    public struct OKLab: Hashable, Sendable {
        public var l: Double
        public var a: Double
        public var b: Double
    }

    /// Björn Ottosson's OKLab, from linear sRGB.
    public var oklab: OKLab {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let lr = linear(r), lg = linear(g), lb = linear(b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return OKLab(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    public init(oklab c: OKLab, alpha: Double = 1) {
        let l = pow(c.l + 0.3963377774 * c.a + 0.2158037573 * c.b, 3)
        let m = pow(c.l - 0.1055613458 * c.a - 0.0638541728 * c.b, 3)
        let s = pow(c.l - 0.0894841775 * c.a - 1.2914855480 * c.b, 3)
        func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        self.init(r: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                  g: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                  b: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
                  a: alpha)
    }

    /// `color-mix(in oklab, self (1 − t), other t)`.
    public func mixOKLab(_ other: RGBColor, _ t: Double) -> RGBColor {
        let p = oklab, q = other.oklab
        return RGBColor(oklab: OKLab(l: p.l + (q.l - p.l) * t, a: p.a + (q.a - p.a) * t, b: p.b + (q.b - p.b) * t),
                        alpha: a + (other.a - a) * t)
    }

    public static let white = RGBColor(r: 1, g: 1, b: 1)
    public static let black = RGBColor(r: 0, g: 0, b: 0)
}
