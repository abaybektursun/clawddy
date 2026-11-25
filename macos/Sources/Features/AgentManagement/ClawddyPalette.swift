import AppKit
import GhosttyKit

/// The chrome's colours, computed from the terminal theme's background `B`
/// and foreground `F` (native-look.md 2.1), so the window reads as one
/// object with its terminals in any dark theme and has no fixed greys. The
/// surfaces are steps of lightness in OKLCH at the background's hue; the
/// text tones are fixed lightnesses; signal and problem are fixed, so amber
/// means one thing everywhere. Dark only.
struct ClawddyPalette: Equatable, Sendable {
    /// A colour in sRGB, each component from 0 to 1.
    struct RGB: Equatable, Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(hex: UInt32) {
            self.init(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255)
        }

        /// WCAG 2 relative luminance.
        var luminance: Double {
            0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
        }

        /// WCAG 2 contrast ratio, from 1 to 21.
        func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// `other` drawn at `opacity` over this colour.
        func blended(with other: RGB, opacity: Double) -> RGB {
            RGB(
                red: red + (other.red - red) * opacity,
                green: green + (other.green - green) * opacity,
                blue: blue + (other.blue - blue) * opacity)
        }

        /// The colour as 0xRRGGBB, each component rounded.
        var hex: UInt32 {
            func byte(_ c: Double) -> UInt32 { UInt32((min(max(c, 0), 1) * 255).rounded()) }
            return byte(red) << 16 | byte(green) << 8 | byte(blue)
        }

        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

        func cgColor(alpha: Double = 1) -> CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }

        static func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }

        static func encoded(_ c: Double) -> Double {
            let value = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return min(max(value, 0), 1)
        }
    }

    /// A colour in OKLCH: lightness, chroma, hue in radians (Björn
    /// Ottosson's OKLab, in polar form).
    struct OKLCH: Equatable, Sendable {
        var lightness: Double
        var chroma: Double
        var hue: Double

        init(lightness: Double, chroma: Double, hue: Double) {
            self.lightness = lightness
            self.chroma = chroma
            self.hue = hue
        }

        init(_ rgb: RGB) {
            let r = RGB.linear(rgb.red), g = RGB.linear(rgb.green), b = RGB.linear(rgb.blue)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            let okL = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
            let okA = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
            let okB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
            self.init(lightness: okL, chroma: (okA * okA + okB * okB).squareRoot(), hue: atan2(okB, okA))
        }

        var rgb: RGB {
            let okA = chroma * cos(hue), okB = chroma * sin(hue)
            let l = pow(lightness + 0.3963377774 * okA + 0.2158037573 * okB, 3)
            let m = pow(lightness - 0.1055613458 * okA - 0.0638541728 * okB, 3)
            let s = pow(lightness - 0.0894841775 * okA - 1.2914855480 * okB, 3)
            return RGB(
                red: RGB.encoded(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                green: RGB.encoded(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                blue: RGB.encoded(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
        }
    }

    /// The terminal background: a lit screen and the terminal's frame.
    let screenLit: RGB
    /// The terminal foreground: a tile's screen text.
    let tileText: RGB
    /// The window.
    let canvas: RGB
    /// A tile at rest.
    let panel: RGB
    /// A tile's screen while off.
    let screenOff: RGB
    /// The selected tile, the line's slab, the current row.
    let raised: RGB
    /// Floating surfaces: the keys panel, the palette, an edge pill.
    let pop: RGB
    /// The dim behind the palette, drawn at `veilAlpha`.
    let veil: RGB
    let ink: RGB
    let text2: RGB
    let text3: RGB
    /// Disabled only.
    let text4: RGB
    let increasesContrast: Bool

    /// Waiting on you, and nothing else.
    static let signal = RGB(hex: 0xE3B458)
    /// A problem's mark and top edge.
    static let problem = RGB(hex: 0xEF7F86)
    static let veilAlpha = 0.55

    var signal: RGB { Self.signal }
    var problem: RGB { Self.problem }

    init(background: RGB, foreground: RGB, increasesContrast: Bool = false) {
        let base = OKLCH(background)
        let neutral = base.chroma < 0.005
        let surfaceChroma = neutral ? 0 : min(base.chroma, 0.0125)
        let textChroma = neutral ? 0 : min(base.chroma, 0.012)
        let s0 = min(max(base.lightness - 0.058, 0.155), 0.25)
        func surface(_ step: Double) -> RGB { OKLCH(lightness: s0 + step, chroma: surfaceChroma, hue: base.hue).rgb }
        func text(_ lightness: Double, _ chroma: Double) -> RGB {
            OKLCH(lightness: lightness, chroma: chroma, hue: base.hue).rgb
        }
        screenLit = background
        tileText = foreground
        canvas = surface(0)
        panel = surface(0.025)
        screenOff = surface(0.0335)
        raised = surface(0.058)
        pop = surface(0.083)
        veil = surface(-0.03)
        ink = text(0.934, textChroma / 2)
        text2 = text(increasesContrast ? 0.80 : 0.741, textChroma)
        text3 = text(increasesContrast ? 0.70 : 0.627, textChroma)
        text4 = text(0.457, textChroma)
        self.increasesContrast = increasesContrast
    }

    /// White at `alpha`: hairlines, rims, top lights and the hover and
    /// pressed fills.
    static func white(_ alpha: Double) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

    /// A tile's and the settled place's 1 pt rim.
    var rimAlpha: Double { increasesContrast ? 0.13 : 0.05 }

    /// The window's appearance: dark, always.
    static let appearance = NSAppearance(named: .darkAqua)

    /// How a tile's screen text reads, as a contrast ratio against its
    /// screen (native-look.md 2.1, "Tile text"): the prototype's opacities
    /// on its foreground #d7dae0, kept as ratios so that any theme's own
    /// foreground reads the same.
    enum TileTone: Double {
        /// Lit: the newest three lines, and the older ones.
        case litNewest = 10.0, litOlder = 4.8
        /// Off: a selected tile, a working one, any other.
        case selected = 3.8, working = 2.3, quiet = 1.7
    }

    /// The opacity of the foreground (`tileText`) that gives `tone` on the
    /// screen's background (lit: `screenLit`; else `screenOff`), at most 1.
    func tileTextOpacity(_ tone: TileTone) -> Float {
        let screen = tone == .litNewest || tone == .litOlder ? screenLit : screenOff
        guard tileText.contrast(with: screen) > tone.rawValue else { return 1 }
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if screen.blended(with: tileText, opacity: mid).contrast(with: screen) < tone.rawValue { low = mid } else { high = mid }
        }
        return Float(high)
    }
}

extension ClawddyPalette {
    /// The palette of a Ghostty configuration's terminal colours, under the
    /// system's Increase Contrast setting unless told otherwise.
    init(
        config: Ghostty.Config,
        increasesContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    ) {
        self.init(
            background: config.terminalColor("background"),
            foreground: config.terminalColor("foreground"),
            increasesContrast: increasesContrast)
    }

    /// The prototype's theme: the palette until the window has read the
    /// configuration's.
    static let prototype = ClawddyPalette(
        background: RGB(hex: 0x282C34),
        foreground: RGB(hex: 0xD7DAE0))
}

private extension Ghostty.Config {
    /// A terminal colour, read as `backgroundColor` reads the background.
    func terminalColor(_ key: String) -> ClawddyPalette.RGB {
        var color = ghostty_config_color_s()
        guard let config,
              ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8)))
        else { preconditionFailure("Ghostty's configuration has no \(key) colour") }
        return ClawddyPalette.RGB(
            red: Double(color.r) / 255,
            green: Double(color.g) / 255,
            blue: Double(color.b) / 255)
    }
}
