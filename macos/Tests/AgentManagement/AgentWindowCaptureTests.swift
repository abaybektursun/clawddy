import AppKit
import Foundation
import Testing
@testable import Ghostty

/// The harness's pictures (`AgentWindowCapture`) of a real terminal, in an
/// invisible window of the test host, which is never the active app.
@MainActor
struct AgentWindowCaptureTests {
    /// Background swatches the terminal prints, as sRGB.
    private static let swatches: [(Int, Int, Int)] = [(255, 0, 0), (0, 200, 0), (30, 60, 200), (128, 128, 128)]

    /// The picture has the terminal's own pixels, in the colours the
    /// terminal was told to show, at the backing scale, and the terminal
    /// sits on whole pixels. The swatches exist only in Ghostty's IOSurface,
    /// so this also proves `CALayer.render(in:)` draws a layer whose contents
    /// are an IOSurface.
    @Test func pictureHasTheTerminalsPixelsInTheirColours() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let script = folder.appendingPathComponent("swatches.sh")
        var lines = ["#!/bin/sh"]
        for (r, g, b) in Self.swatches {
            lines.append("printf '\\033[48;2;\(r);\(g);\(b)m          \\033[0m\\n'")
        }
        // Text in many colours, so the terminal is more than a few flat blocks.
        lines.append("i=0; while [ $i -lt 16 ]; do printf '\\033[38;2;%d;%d;200mcolour %d\\033[0m\\n' $((i*10)) $((250-i*10)) $i; i=$((i+1)); done")
        lines.append("exec sleep 30")
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = script.path
        let surface = Ghostty.SurfaceView(try #require(ghostty.app), baseConfig: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 640, height: 480),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        // Never ordered in: Ghostty draws its frames all the same, and no
        // other test sees a window on screen.
        defer { window.close() }

        let scale = window.backingScaleFactor
        var picture = try AgentWindowCapture.picture(of: window)
        let deadline = Date() + 10
        while Date() < deadline, Self.swatches.contains(where: { picture.count(near: $0, in: surface, of: window) < 200 }) {
            try await Task.sleep(for: .milliseconds(100))
            picture = try AgentWindowCapture.picture(of: window)
        }
        #expect(picture.pixelsWide == Int(window.frame.width * scale))
        for swatch in Self.swatches {
            #expect(picture.count(near: swatch, in: surface, of: window) >= 200, "swatch \(swatch)")
        }
        #expect(picture.distinctColors(in: surface, of: window) > 16)
        // The terminal's rectangle falls on whole pixels.
        let rect = try #require(AgentWindowCapture.terminalRects(in: window).first)
        #expect(rect.allSatisfy { $0 == $0.rounded() }, "\(rect)")
    }

    /// A frame strip shows a Core Animation transition in progress: a layer
    /// fading out over 200 ms is opaque in the first frame, half way in the
    /// middle and gone in the last, and the window's clock runs again after.
    @Test func framesStepATransition() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = content
        let square = CALayer()
        square.frame = CGRect(x: 50, y: 50, width: 100, height: 100)
        square.backgroundColor = NSColor.white.cgColor
        content.layer?.addSublayer(square)
        defer { window.close() }

        let pictures = try await AgentWindowCapture.frames(of: window, duration: 0.2, step: 0.1) {
            square.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.2
            square.add(fade, forKey: "fade")
        }
        #expect(pictures.count == 3)
        let middle = { (picture: NSBitmapImageRep) -> Int in
            let scale = Int(window.backingScaleFactor)
            let point = (picture.pixelsWide / 2, picture.pixelsHigh - 100 * scale)
            guard let data = picture.bitmapData else { return -1 }
            return Int((data + point.1 * picture.bytesPerRow + point.0 * 4)[0])
        }
        let levels = pictures.map(middle)
        #expect(levels[0] > 240, "\(levels)")
        #expect((90...200).contains(levels[1]), "\(levels)")
        #expect(levels[2] < 15, "\(levels)")
        let root = try #require(window.contentView?.superview?.layer)
        #expect(root.speed == 1)
    }
}

private extension NSBitmapImageRep {
    /// The colours of this picture's pixels where `view` is, from the top left.
    func pixels(in view: NSView, of window: NSWindow) -> [(Int, Int, Int)] {
        guard let data = bitmapData, let frameView = window.contentView?.superview else { return [] }
        let rect = view.convert(view.bounds, to: frameView)
        let scale = CGFloat(pixelsWide) / frameView.bounds.width
        let top = frameView.isFlipped ? rect.minY : frameView.bounds.height - rect.maxY
        var result: [(Int, Int, Int)] = []
        for row in (Int(top * scale)..<Int((top + rect.height) * scale)).clamped(to: 0..<pixelsHigh) {
            for column in (Int(rect.minX * scale)..<Int(rect.maxX * scale)).clamped(to: 0..<pixelsWide) {
                let pixel = data + row * bytesPerRow + column * 4
                result.append((Int(pixel[0]), Int(pixel[1]), Int(pixel[2])))
            }
        }
        return result
    }

    /// How many pixels are within 3 of `colour` in every channel.
    func count(near colour: (Int, Int, Int), in view: NSView, of window: NSWindow) -> Int {
        pixels(in: view, of: window).filter {
            abs($0.0 - colour.0) <= 3 && abs($0.1 - colour.1) <= 3 && abs($0.2 - colour.2) <= 3
        }.count
    }

    func distinctColors(in view: NSView, of window: NSWindow) -> Int {
        Set(pixels(in: view, of: window).map { $0.0 << 16 | $0.1 << 8 | $0.2 }).count
    }
}
