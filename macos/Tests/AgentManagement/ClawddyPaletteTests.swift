import Foundation
import Testing
@testable import Ghostty

/// The chrome's colours computed from the terminal theme (native-look.md
/// 2.1).
struct ClawddyPaletteTests {
    typealias RGB = ClawddyPalette.RGB

    /// A tile's screen text is dimmed to contrast ratios, not opacities:
    /// the prototype's foreground #d7dae0 gives its own 62 %, 100 %, 50 %,
    /// 30 % and 20 %; a white foreground is dimmed further to the same
    /// ratios.
    @Test func tileTextKeepsItsContrastWithAnyForeground() {
        let prototype = ClawddyPalette.prototype
        let expected: [(ClawddyPalette.TileTone, Float)] = [(.litNewest, 1), (.litOlder, 0.62), (.selected, 0.5), (.working, 0.3), (.quiet, 0.2)]
        for (tone, opacity) in expected {
            #expect(abs(prototype.tileTextOpacity(tone) - opacity) < 0.03, "\(tone)")
        }
        let white = ClawddyPalette(background: .init(hex: 0x282C34), foreground: .init(hex: 0xFFFFFF))
        for tone in [ClawddyPalette.TileTone.litNewest, .litOlder, .selected, .working, .quiet] {
            let screen = tone == .litNewest || tone == .litOlder ? white.screenLit : white.screenOff
            let shown = screen.blended(with: white.tileText, opacity: Double(white.tileTextOpacity(tone)))
            #expect(abs(shown.contrast(with: screen) - tone.rawValue) < 0.05, "\(tone)")
            #expect(white.tileTextOpacity(tone) < 1)
        }
    }

    @Test func contrastIsWCAG() {
        let black = RGB(hex: 0x000000)
        let white = RGB(hex: 0xFFFFFF)
        #expect(abs(black.contrast(with: white) - 21) < 0.001)
        #expect(white.contrast(with: black) == black.contrast(with: white))
        #expect(abs(RGB(hex: 0x767676).contrast(with: white) - 4.54) < 0.01)
    }

    @Test func oklchRoundTrips() {
        for hex: UInt32 in [0x282C34, 0x000000, 0x44475A, 0xE3B458, 0xFFFFFF] {
            #expect(ClawddyPalette.OKLCH(RGB(hex: hex)).rgb.hex == hex)
        }
    }

    /// The prototype's theme gives the prototype's colours, within one unit
    /// per channel.
    @Test func thePrototypeThemeGivesThePrototypesColours() {
        let palette = ClawddyPalette(background: RGB(hex: 0x282C34), foreground: RGB(hex: 0xD7DAE0))
        let expected: [(RGB, UInt32)] = [
            (palette.canvas, 0x1B1E24), (palette.panel, 0x21242A), (palette.screenOff, 0x23262C),
            (palette.raised, 0x292C33), (palette.pop, 0x2F323A), (palette.ink, 0xE7E9ED),
            (palette.text2, 0xA8ABB2), (palette.text3, 0x858890), (palette.text4, 0x54575E),
        ]
        for (color, hex) in expected {
            let other = RGB(hex: hex)
            #expect(abs(color.red - other.red) <= 1.5 / 255, "\(String(color.hex, radix: 16)) \(String(hex, radix: 16))")
            #expect(abs(color.green - other.green) <= 1.5 / 255, "\(String(color.hex, radix: 16)) \(String(hex, radix: 16))")
            #expect(abs(color.blue - other.blue) <= 1.5 / 255, "\(String(color.hex, radix: 16)) \(String(hex, radix: 16))")
        }
        #expect(palette.screenLit == RGB(hex: 0x282C34))
        #expect(palette.tileText == RGB(hex: 0xD7DAE0))
        #expect(palette.signal == RGB(hex: 0xE3B458))
        #expect(palette.problem == RGB(hex: 0xEF7F86))
    }

    /// A very dark theme holds the canvas at L 0.155; a lighter dark one caps
    /// it at 0.25, so the chrome stays dark. Text keeps its contrast table.
    @Test func surfacesAreHeldBetweenTheirLimits() {
        let black = ClawddyPalette(background: RGB(hex: 0x000000), foreground: RGB(hex: 0xFFFFFF))
        #expect(black.canvas.hex == 0x0C0C0C)
        #expect(black.raised.hex == 0x191919)
        let dracula = ClawddyPalette(background: RGB(hex: 0x44475A), foreground: RGB(hex: 0xF8F8F2))
        #expect(ClawddyPalette.OKLCH(dracula.canvas).lightness <= 0.2501)
        for palette in [black, dracula, ClawddyPalette.prototype] {
            #expect(palette.text3.contrast(with: palette.canvas) >= 4.4)
            #expect(palette.text2.contrast(with: palette.raised) >= 5.5)
        }
    }

    @Test func increaseContrastRaisesTheTextTones() {
        let normal = ClawddyPalette(background: RGB(hex: 0x282C34), foreground: RGB(hex: 0xD7DAE0))
        let more = ClawddyPalette(background: RGB(hex: 0x282C34), foreground: RGB(hex: 0xD7DAE0), increasesContrast: true)
        #expect(more.text3.contrast(with: more.canvas) > normal.text3.contrast(with: normal.canvas))
        #expect(more.text2.contrast(with: more.canvas) > normal.text2.contrast(with: normal.canvas))
        #expect(more.rimAlpha > normal.rimAlpha)
    }

    @Test func paletteReadsTheTerminalColoursFromGhosttysConfiguration() throws {
        let config = try TemporaryConfig("background = #171a21\nforeground = #e9e7e2")
        let palette = ClawddyPalette(config: config)
        #expect(palette.screenLit == RGB(hex: 0x171A21))
        #expect(palette.tileText == RGB(hex: 0xE9E7E2))
    }
}
