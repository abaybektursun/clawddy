import Foundation
import Testing
@testable import Ghostty

/// Home's pure parts: where tiles go, what the selection does, and which
/// terminal lines a tile shows.
struct AgentHomeTests {
    // MARK: Layout

    private static func layout(_ width: CGFloat, _ height: CGFloat, density: Int = 0) -> AgentHomeLayout {
        AgentHomeLayout(width: width, visibleHeight: height, density: density, scale: 2)
    }

    /// Columns come from the width alone (flows.md "Home", limits 9).
    @Test func columnsComeFromTheWidth() {
        #expect(Self.layout(900, 500).columns == 2)
        #expect(Self.layout(1440, 776).columns == 4)
        #expect(Self.layout(3000, 776).columns == 9)
        #expect(abs(Self.layout(3000, 776).tileWidth - 317.3) < 1)
    }

    /// The default is max(2, round(H / 290)) rows; at 1440 × 900 about 250
    /// pt each; ⌘− twice gives 5 rows of about 145 pt, the most at that
    /// height; a row stays at least 132 pt; the row after those that fit
    /// never peeks into view.
    @Test func rowsComeFromTheHeightAndTheDensity() {
        let normal = Self.layout(1440, 794)
        #expect(normal.rows == 3)
        #expect(normal.rowHeight == 252)
        for height in stride(from: 500.0, through: 1400.0, by: 7) {
            for density in -2...3 {
                let layout = Self.layout(1440, height, density: density)
                let next = layout.frame(at: layout.rows * layout.columns)
                #expect(next.minY >= height, "\(height) \(density)")
                #expect(layout.frame(at: layout.rows * layout.columns - 1).maxY <= height, "\(height) \(density)")
            }
        }
        let dense = Self.layout(1440, 794, density: 2)
        #expect(dense.rows == 5)
        #expect(abs(dense.rowHeight - 145) <= 1)
        #expect(Self.layout(1440, 794, density: 9).rows == 5)
        #expect(Self.layout(1440, 794, density: -9).rows == 1)
        #expect(normal.clamped(9) == 2)
        #expect(normal.clamped(-9) == -2)
        for density in -3...3 { #expect(Self.layout(1440, 794, density: density).rowHeight >= AgentHomeLayout.leastRow) }
    }

    /// A tile's frame is a function of its place and the window alone: the
    /// first tile's rectangle never changes as agents are added, and each
    /// place keeps its rectangle. Columns keep one pitch on whole pixels.
    @Test func aTilesFrameDoesNotDependOnHowManyThereAre() {
        let layout = Self.layout(1440, 794)
        let frames = (0..<40).map(layout.frame(at:))
        #expect(frames[0] == CGRect(x: 24, y: 4, width: frames[0].width, height: 252))
        #expect(Set(frames.map(\.width)).count <= 2)
        for frame in frames {
            #expect((frame.minX * 2).rounded() == frame.minX * 2)
            #expect((frame.maxX * 2).rounded() == frame.maxX * 2)
        }
        #expect(frames[1].minX - frames[0].minX == frames[2].minX - frames[1].minX)
        #expect(Double(frames[4].minY) == 268)
        // Rows that do not fit scroll: the grid grows, the tiles do not.
        #expect(layout.contentHeight(count: 7) == 794)
        let tall: CGFloat = 4 + 2640 - 12 + 12
        #expect(layout.contentHeight(count: 40) == tall)
    }

    // MARK: Selection

    private static let ids = (0..<7).map { _ in UUID() }

    /// With nothing selected, Down or Right selects the first tile, Up or
    /// Left the last (ruling 2); arrows move one tile; at an edge nothing.
    @Test func arrowsMoveTheCursorWithoutWrapping() {
        let ids = Self.ids
        for (direction, expected) in [(AgentTileSelection.Direction.down, 0), (.right, 0), (.up, 6), (.left, 6)] {
            var selection = AgentTileSelection()
            selection.move(direction, extend: false, in: ids, columns: 4)
            #expect(selection.cursor == ids[expected], "\(direction)")
            #expect(selection.selected == [ids[expected]])
        }
        var selection = AgentTileSelection.only(ids[0])
        selection.move(.left, extend: false, in: ids, columns: 4)
        #expect(selection.cursor == ids[0])
        selection.move(.up, extend: false, in: ids, columns: 4)
        #expect(selection.cursor == ids[0])
        selection.move(.down, extend: false, in: ids, columns: 4)
        #expect(selection.cursor == ids[4])
        selection.move(.right, extend: false, in: ids, columns: 4)
        selection.move(.right, extend: false, in: ids, columns: 4)
        #expect(selection.cursor == ids[6])
        selection.move(.right, extend: false, in: ids, columns: 4)
        #expect(selection.cursor == ids[6])
        // Up from the second row's fourth place: no tile below it in a
        // short last row matters only going down.
        var third = AgentTileSelection.only(ids[3])
        third.move(.down, extend: false, in: ids, columns: 4)
        #expect(third.cursor == ids[3])
    }

    /// Shift-arrows select a range from the anchor, as in Finder: moving
    /// back toward the anchor deselects (ruling 4).
    @Test func shiftArrowsSelectARangeFromTheAnchor() {
        let ids = Self.ids
        var selection = AgentTileSelection.only(ids[1])
        selection.move(.right, extend: true, in: ids, columns: 4)
        selection.move(.right, extend: true, in: ids, columns: 4)
        #expect(selection.selected == Set(ids[1...3]))
        #expect(selection.cursor == ids[3])
        selection.move(.left, extend: true, in: ids, columns: 4)
        #expect(selection.selected == Set(ids[1...2]))
        selection.move(.down, extend: true, in: ids, columns: 4)
        #expect(selection.selected == Set(ids[1...6]))
        selection.move(.up, extend: true, in: ids, columns: 4)
        selection.move(.left, extend: true, in: ids, columns: 4)
        #expect(selection.selected == [ids[1]])
        selection.move(.left, extend: true, in: ids, columns: 4)
        #expect(selection.selected == Set(ids[0...1]))
        #expect(selection.anchor == ids[1])
    }

    /// ⌘A selects every tile, the cursor on the first when none was; Escape
    /// collapses several to the cursor, then clears; with none it does
    /// nothing (ruling 3).
    @Test func selectAllAndEscape() {
        let ids = Self.ids
        var selection = AgentTileSelection()
        selection.escape()
        #expect(selection.isEmpty)
        selection.selectAll(ids)
        #expect(selection.selected == Set(ids))
        #expect(selection.cursor == ids[0])
        selection.escape()
        #expect(selection.selected == [ids[0]])
        selection.escape()
        #expect(selection.isEmpty)
    }

    /// A press selects the tile alone; one already in a selection of several
    /// keeps it; ⇧/⌘ toggle, and removing the cursor makes the first
    /// remaining selected tile the cursor.
    @Test func pressesSelectAndToggle() {
        let ids = Self.ids
        var selection = AgentTileSelection()
        selection.press(ids[2], toggles: false, in: ids)
        #expect(selection == .only(ids[2]))
        selection.press(ids[4], toggles: true, in: ids)
        selection.press(ids[0], toggles: true, in: ids)
        #expect(selection.selected == [ids[0], ids[2], ids[4]])
        selection.press(ids[2], toggles: false, in: ids)
        #expect(selection.selected.count == 3)
        #expect(selection.cursor == ids[2])
        selection.press(ids[2], toggles: true, in: ids)
        #expect(selection.cursor == ids[0])
        selection.press(ids[0], toggles: true, in: ids)
        selection.press(ids[4], toggles: true, in: ids)
        #expect(selection.isEmpty)
        var kept = AgentTileSelection.only(ids[3])
        kept.keep(Array(ids.prefix(3)))
        #expect(kept.isEmpty)
    }

    // MARK: Tail

    /// Claude Code's screen, as the stand-ins draw it from real captures
    /// (cli-facts.md; probes.md P2): the transcript, its spinner, then the
    /// input between two full-width rules and the footer.
    static let claudeWorking = """
        ⏺ Read(Tests/OfflineTests.swift)
          ⎿  88 lines

        ⏺ Bash(xcodebuild test -only-testing:OfflineTests)
          ⎿  291 passed

        ✽ Splitting the chart tile index… (14m 59s · ↓ 120 tokens)

        \(String(repeating: "─", count: 110))
        ❯\u{00A0}
        \(String(repeating: "─", count: 110))
          ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt

        """

    /// Claude Code asking: the question and its menu under the last rule.
    static let claudeAsks = """
        ⏺ Edit(Sources/AnchorView.swift)
          ⎿  +31 −1

        \(String(repeating: "─", count: 110))
         ☐ Anchor alarm

        Sound the siren even on silent, or vibrate only when silent?

        ❯ 1. Siren, even with the phone silent
          2. Vibrate only when it is silent

        Enter to select · ↑/↓ to navigate · Esc to cancel
          ⏵⏵ bypass permissions on (shift+tab to cycle)
        """

    /// Codex 0.169.0's screen (probes.md P2): the composer is the last row
    /// starting with "›", above two footer rows; braille spinner characters
    /// scattered over it before the first prompt.
    static let codex = """
        › reply with the single word ok

        • ok

        › Ask⠁ Codex to do anything

          gpt-5 high · ~/work/scratch
          ← for agents · ? for shortcuts
        """

    /// Cut above the input box, with no blank rows: the blank rows a CLI
    /// leaves between steps would take a third of a small tile.
    @Test func theTailStopsAboveTheInputBox() {
        #expect(AgentTail.lines(Self.claudeWorking, provider: .claudeCode) == [
            "⏺ Read(Tests/OfflineTests.swift)",
            "  ⎿  88 lines",
            "⏺ Bash(xcodebuild test -only-testing:OfflineTests)",
            "  ⎿  291 passed",
            "✽ Splitting the chart tile index… (14m 59s · ↓ 120 tokens)",
        ])
        #expect(AgentTail.lines(Self.claudeAsks, provider: .claudeCode) == [
            "⏺ Edit(Sources/AnchorView.swift)", "  ⎿  +31 −1",
        ])
        #expect(AgentTail.lines(Self.codex, provider: .codex) == ["› reply with the single word ok", "• ok"])
    }

    /// With no input box it recognises, the raw last rows show, blank rows
    /// dropped (plan R5); Codex's update dialog is not its composer.
    @Test func withoutAnInputBoxTheRawRowsShow() {
        #expect(AgentTail.lines("one\n\ntwo\n\n  \n", provider: .claudeCode) == ["one", "two"])
        let dialog = "Update available\n› 1. Update now\n  2. Skip\n"
        #expect(AgentTail.lines(dialog, provider: .codex) == ["Update available", "› 1. Update now", "  2. Skip"])
    }

    /// The row that repeats the sentence word for word is left out.
    @Test func theRowRepeatingTheSentenceIsLeftOut() {
        let screen = "⏺ Read(a)\n⏺ Fixed the crash.\n"
        #expect(AgentTail.lines(screen, provider: .claudeCode, sentence: "Fixed the crash.") == ["⏺ Read(a)"])
        #expect(AgentTail.lines(screen, provider: .claudeCode) == ["⏺ Read(a)", "⏺ Fixed the crash."])
    }

    // MARK: Moving

    /// ⌥← ⌥→ move the selected agents one place together; at either end
    /// nothing (flows.md 3.5).
    @Test func optionArrowsMoveTheSelectedOnePlace() {
        let ids = Array(Self.ids.prefix(5))
        #expect(AgentReorder.step(ids, moving: [ids[2]], by: -1) == [ids[0], ids[2], ids[1], ids[3], ids[4]])
        #expect(AgentReorder.step(ids, moving: [ids[1], ids[2]], by: 1) == [ids[0], ids[3], ids[1], ids[2], ids[4]])
        #expect(AgentReorder.step(ids, moving: [ids[0], ids[3]], by: -1) == nil)
        #expect(AgentReorder.step(ids, moving: [ids[4]], by: 1) == nil)
        #expect(AgentReorder.step(ids, moving: [], by: 1) == nil)
    }

    /// Dropped tiles land side by side in the gap, in their order.
    @Test func droppedTilesLandSideBySideInTheGap() {
        let ids = Array(Self.ids.prefix(5))
        #expect(AgentReorder.drop(ids, moving: [ids[0]], at: 4) == [ids[1], ids[2], ids[3], ids[4], ids[0]])
        #expect(AgentReorder.drop(ids, moving: [ids[3], ids[1]], at: 0) == [ids[1], ids[3], ids[0], ids[2], ids[4]])
        #expect(AgentReorder.drop(ids, moving: [ids[0]], at: 0) == nil)
    }
}
