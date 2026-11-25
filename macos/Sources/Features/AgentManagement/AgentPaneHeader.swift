import AppKit

/// The one-line header over the terminal (native-look.md 3.7): the shown
/// agent's mark, name and sentence, and at the right its change count and
/// time, or for 6 s the news of another agent that came to wait on the
/// person. Every text in it shares one baseline with the back row's. It
/// follows its agent itself: a change of its state, name, sentence or counts
/// sets the layers that changed.
final class AgentPaneHeader: NSView, AgentActivationClickSafeRegion, AgentNameHost {
    static let height: CGFloat = 42

    private let mark = AgentMarkLayer()
    private let name = AgentTextLayer()
    private let sentence = AgentTextLayer()
    private let changes = AgentTextLayer()
    private let time = AgentTextLayer()
    let news = AgentButton()
    private let newsMark = AgentMarkLayer()
    private let newsName = AgentTextLayer()
    private let newsSentence = AgentTextLayer()

    private weak var agent: AgentInstance?
    private var observer: AgentObserver?
    private weak var newsAgent: AgentInstance?
    private var newsObserver: AgentObserver?
    private var newsEnd: DispatchWorkItem?
    private(set) var palette: ClawddyPalette = .prototype
    /// The time, which the window's clock asks for again.
    var now: () -> Date = Date.init

    /// A click on the news: enters that agent.
    var onNews: ((UUID) -> Void)?
    /// A double-click on the name: rename in place (flows.md 6.9).
    var onRename: (() -> Void)?
    /// Where the name may run while it is edited: from the name's place to
    /// the change count or the news.
    private var nameRoom = CGRect.zero

    var nameFrame: CGRect { nameRoom }
    var nameFont: NSFont { AgentMetrics.bodySemibold }

    /// The name is being edited: the drawn name hides under the field,
    /// and the sentence moves on past the field's room.
    var editsName = false {
        didSet {
            name.isHidden = editsName
            needsLayout = true
        }
    }

    /// Each news shown or ended bumps it: an older fade's end does nothing.
    private var newsMotion = 0

    /// The news takes the pointer only while there is news, also while it
    /// fades out.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        if newsAgent == nil, let view, view === news || view.isDescendant(of: news) { return self }
        return view
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, name.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onRename?()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for part in [mark, name, sentence, changes, time] as [CALayer] { layer?.addSublayer(part) }
        addSubview(news)
        news.fills = (0.06, 0.10, 0.14)
        news.layer?.borderWidth = 1
        for part in [newsMark, newsName, newsSentence] as [CALayer] { news.layer?.addSublayer(part) }
        news.isHidden = true
        news.onPress = { [weak self] in
            guard let id = self?.newsAgent?.id else { return }
            self?.onNews?(id)
        }
        news.setAccessibilityHelp("Opens it")
        // The agent shown, read as one line; a double-click on its name
        // renames it.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }

    /// Shows `agent`, or nothing.
    func show(_ agent: AgentInstance?, palette: ClawddyPalette) {
        let changed = agent !== self.agent || palette != self.palette
        self.palette = palette
        guard changed else { return }
        self.agent = agent
        // At home the header is not seen: its mark does not turn.
        mark.onScreen = agent != nil
        observer?.cancel()
        observer = agent.map { _ in AgentObserver { [weak self] in self?.refresh() } }
        if agent == nil { refresh() }
        if newsAgent != nil { refreshNews() }
    }

    /// Shows `agent` as news for 6 s, replacing any news before it: only an
    /// agent that waits on the person is news.
    func showNews(_ agent: AgentInstance) {
        guard agent.record.isWaitingOnYou else { return }
        let arriving = newsAgent == nil
        newsAgent = agent
        newsObserver?.cancel()
        newsObserver = AgentObserver { [weak self] in self?.refreshNews() }
        if arriving {
            // Back from what is on screen when it was still fading out.
            if news.isHidden { news.layer?.opacity = 0 }
            AgentMotion.fade(news.layer!, to: 1, duration: AgentMotion.small, in: self)
            for part in [changes, time] { AgentMotion.fade(part, to: 0, duration: AgentMotion.small, in: self) }
        }
        news.isHidden = false
        newsMotion += 1
        newsEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in self?.endNews() }
        newsEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: end)
        needsLayout = true
    }

    /// The news goes back to the change count and time.
    func endNews() {
        guard newsAgent != nil else { return }
        newsEnd?.cancel()
        newsAgent = nil
        newsObserver?.cancel()
        newsObserver = nil
        // It takes no pointer from now (motion review ruling 1); it fades
        // out over 200 ms and is hidden as that fade ends, unless news came
        // back meanwhile.
        newsMotion += 1
        let motion = newsMotion
        AgentMotion.run({
            AgentMotion.fade(news.layer!, to: 0, duration: AgentMotion.big, in: self)
        }, then: { [weak self] in
            guard let self, self.newsMotion == motion, self.newsAgent == nil else { return }
            self.news.isHidden = true
        })
        for part in [changes, time] { AgentMotion.fade(part, to: 1, duration: AgentMotion.big, in: self) }
        needsLayout = true
    }

    /// The agent the news shows, if any.
    var newsAgentID: UUID? { newsAgent?.id }
    /// The agent the header shows.
    var agentID: UUID? { agent?.id }

    /// Reads the agent again: its time moves on.
    func refresh() {
        guard let agent else {
            for part in [name, sentence, changes, time] { part.text = nil }
            mark.state = nil
            return
        }
        let state = agent.shownState
        let said = agent.sentence
        mark.palette = palette
        mark.state = state
        name.text = AgentText(string: agent.name, font: AgentMetrics.bodySemibold, color: palette.ink.cgColor())
        sentence.text = AgentText(
            string: said.text,
            font: said.isAppWritten ? AgentMetrics.italic(AgentMetrics.body) : AgentMetrics.body,
            color: palette.text2.cgColor())
        let counts = agent.metadata.flatMap { metadata -> String? in
            guard let added = metadata.linesAdded, let removed = metadata.linesRemoved, added + removed > 0 else { return nil }
            return "+\(added) −\(removed)"
        }
        changes.text = counts.map { AgentText(string: $0, font: AgentMetrics.digits13, color: palette.text3.cgColor(), alignment: .right) }
        let age = now().timeIntervalSince(agent.record.changedAt)
        time.text = AgentText(
            string: AgentAge.header(state, age: age), font: AgentMetrics.digits13,
            color: palette.text3.cgColor(), alignment: .right)
        setAccessibilityLabel("\(agent.name), \(state.name), \(state.agePhrase(age)). \(said.text)")
        needsLayout = true
    }

    private func refreshNews() {
        guard let agent = newsAgent else { return }
        // News of an agent that no longer waits on the person goes.
        guard agent.record.isWaitingOnYou else { return endNews() }
        let state = agent.shownState
        let said = agent.sentence
        newsMark.palette = palette
        newsMark.state = state
        newsName.text = AgentText(string: agent.name, font: AgentMetrics.bodyMedium, color: palette.ink.cgColor())
        newsSentence.text = AgentText(
            string: said.text,
            font: said.isAppWritten ? AgentMetrics.italic(AgentMetrics.body) : AgentMetrics.body,
            color: palette.text2.cgColor())
        news.layer?.borderColor = (state == .problem ? palette.problem : palette.signal).cgColor(alpha: 0.28)
        news.setAccessibilityLabel("\(agent.name) is waiting on you: \(said.text)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let lineTop = ((bounds.height - 18) / 2).rounded()
        let baseline = lineTop + AgentMetrics.baseline(AgentMetrics.body, lineHeight: 18)
        let markTop = baseline - AgentMetrics.markLift - 7
        mark.frame = CGRect(x: 10, y: markTop, width: 14, height: 14)

        // The right side: the news, or the change count and time.
        var right = width - 8
        if let newsAgent {
            _ = newsAgent
            let nameWidth = newsName.text?.width ?? 0
            let sentenceWidth = newsSentence.text?.width ?? 0
            let natural = 10 + 14 + 8 + nameWidth + 8 + sentenceWidth + 10
            let pillWidth = min(natural, (width * 0.5).rounded())
            let pill = NSRect(x: right - pillWidth, y: lineTop - 3, width: pillWidth, height: 24)
            if news.frame != pill { news.frame = pill }
            newsMark.frame = CGRect(x: 10, y: markTop - pill.minY, width: 14, height: 14)
            let nameFrameWidth = min(nameWidth, max(0, pillWidth - 10 - 14 - 8 - 10))
            newsName.frame = CGRect(x: 32, y: 3, width: nameFrameWidth, height: 18)
            let sentenceX = 32 + nameFrameWidth + 8
            newsSentence.frame = CGRect(x: sentenceX, y: 3, width: max(0, pillWidth - sentenceX - 10), height: 18)
            right = pill.minX - 12
        } else {
            let timeWidth = min(time.text?.width ?? 0, width * 0.46)
            time.frame = CGRect(x: right - timeWidth, y: lineTop, width: timeWidth, height: 18)
            right -= timeWidth
            if let changesWidth = changes.text?.width {
                right -= 12
                changes.frame = CGRect(x: right - changesWidth, y: lineTop, width: changesWidth, height: 18)
                right -= changesWidth
            }
            right -= 12
        }

        // The name takes at most 36 % of the width; the sentence the rest.
        let nameX: CGFloat = 34
        let nameWidth = min(name.text?.width ?? 0, (width * 0.36).rounded(), max(0, right - nameX))
        name.frame = CGRect(x: nameX, y: lineTop, width: nameWidth, height: 18)
        // Edited, the name has room to type: at least its own width, at most
        // 320 pt or 36 % of the pane; the sentence goes on after it (final
        // review ruling 9).
        let room = min(max(nameWidth, min(320, (width * 0.36).rounded())), max(nameWidth, right - nameX))
        nameRoom = CGRect(x: nameX, y: lineTop, width: room, height: 18)
        nameField?.place(nameRoom)
        let sentenceX = nameX + (editsName ? room : nameWidth) + 10
        // Under 760 pt of pane width the sentence gives way to news.
        sentence.isHidden = newsAgent != nil && width < 760
        sentence.frame = CGRect(x: sentenceX, y: lineTop, width: max(0, right - sentenceX), height: 18)
    }
}
