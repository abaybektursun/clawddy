import SwiftUI

struct CommandOption: Identifiable, Hashable {
    /// Unique identifier for this option.
    let id: UUID
    /// The primary text displayed for this command.
    let title: String
    /// Secondary text displayed below the title.
    let subtitle: String?
    /// Tooltip text shown on hover.
    let description: String?
    /// Keyboard shortcut symbols to display.
    let symbols: [String]?
    /// SF Symbol name for the leading icon.
    let leadingIcon: String?
    /// Color for the leading indicator circle.
    let leadingColor: Color?
    /// Badge text displayed as a pill.
    let badge: String?
    /// Additional semantic terms used for filtering but not displayed.
    let searchTerms: [String]
    /// Whether to visually emphasize this option.
    let emphasis: Bool
    /// Sort key for stable ordering when titles are equal.
    let sortKey: AnySortKey?
    /// The action to perform when this option is selected.
    let action: () -> Void

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        symbols: [String]? = nil,
        leadingIcon: String? = nil,
        leadingColor: Color? = nil,
        badge: String? = nil,
        searchTerms: [String] = [],
        emphasis: Bool = false,
        sortKey: AnySortKey? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.symbols = symbols
        self.leadingIcon = leadingIcon
        self.leadingColor = leadingColor
        self.badge = badge
        self.searchTerms = searchTerms
        self.emphasis = emphasis
        self.sortKey = sortKey
        self.action = action
    }

    static func == (lhs: CommandOption, rhs: CommandOption) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    var options: [CommandOption]
    /// Search-field placeholder text.
    var placeholder: String = "Execute a command…"
    /// Maximum height of the results table. Increase for larger pickers.
    var tableMaxHeight: CGFloat = 200
    /// Whether to draw the rounded stroke around the palette card.
    /// Stock Ghostty uses true; floating panels over the desktop look cleaner with false.
    var showsBorder: Bool = true
    /// Whether to draw the palette's own material card + shadow + divider.
    /// Set false when an external surface (a Liquid Glass panel) provides the
    /// background — avoids stacking a second material over the glass.
    var showsBackground: Bool = true
    @State private var query = ""
    @State private var selectedIndex: UInt? = 0
    @State private var hoveredOptionID: UUID?
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The options that we should show, taking into account any filtering from
    // the query.
    var filteredOptions: [CommandOption] {
        if query.isEmpty {
            return options
        } else {
            return options.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                ($0.subtitle?.localizedCaseInsensitiveContains(query) ?? false) ||
                $0.searchTerms.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            }
        }
    }

    var selectedOption: CommandOption? {
        guard let selectedIndex else { return nil }
        return if selectedIndex < filteredOptions.count {
            filteredOptions[Int(selectedIndex)]
        } else {
            filteredOptions.last
        }
    }

    var body: some View {
        let scheme: ColorScheme = if OSColor(backgroundColor).isLightColor {
            .light
        } else {
            .dark
        }

        VStack(alignment: .leading, spacing: 0) {
            CommandPaletteQuery(query: $query, placeholder: placeholder) { event in
                switch event {
                case .exit:
                    isPresented = false

                case .submit:
                    isPresented = false
                    selectedOption?.action()

                case .move(.up):
                    if filteredOptions.isEmpty { break }
                    let current = selectedIndex ?? UInt(filteredOptions.count)
                    selectedIndex = (current == 0)
                        ? UInt(filteredOptions.count - 1)
                        : current - 1

                case .move(.down):
                    if filteredOptions.isEmpty { break }
                    let current = selectedIndex ?? UInt.max
                    selectedIndex = (current >= UInt(filteredOptions.count - 1))
                        ? 0
                        : current + 1

                case .move:
                    // Unknown, ignore
                    break
                }
            }
            .onChange(of: query) {
                selectedIndex = filteredOptions.isEmpty ? nil : 0
            }

            if showsBackground {
                Divider()
            }

            CommandTable(
                options: filteredOptions,
                selectedIndex: $selectedIndex,
                hoveredOptionID: $hoveredOptionID,
                maxHeight: tableMaxHeight) { option in
                    isPresented = false
                    option.action()
            }
        }
        .frame(maxWidth: 500)
        .background(
            Group {
                if showsBackground {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                        Rectangle()
                            .fill(backgroundColor)
                            .blendMode(.color)
                    }
                    .compositingGroup()
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: showsBackground ? 10 : 0))
        .overlay(
            Group {
                if showsBorder {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.75))
                }
            }
        )
        .shadow(radius: showsBackground ? 32 : 0, x: 0, y: showsBackground ? 12 : 0)
        .padding(showsBackground ? 16 : 12)
        .scaleEffect(appeared ? 1 : 0.97)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { appeared = true }
            }
        }
        .environment(\.colorScheme, scheme)
        .onChange(of: isPresented) { _, newValue in
            if !newValue {
                // This is optional, since most of the time
                // there will be a delay before the next use.
                // To keep behavior the same as before, we reset it.
                query = ""
                selectedIndex = options.isEmpty ? nil : 0
            }
        }
    }
}

/// The text field for building the query for the command palette.
private struct CommandPaletteQuery: View {
    @Binding var query: String
    var placeholder: String
    var onEvent: ((KeyboardEvent) -> Void)?
    @FocusState private var isTextFieldFocused: Bool

    init(query: Binding<String>, placeholder: String = "Execute a command…", onEvent: ((KeyboardEvent) -> Void)? = nil) {
        _query = query
        self.placeholder = placeholder
        self.onEvent = onEvent
    }

    enum KeyboardEvent {
        case exit
        case submit
        case move(MoveCommandDirection)
    }

    var body: some View {
        ZStack {
            Group {
                Button { onEvent?(.move(.up)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button { onEvent?(.move(.down)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.downArrow, modifiers: [])

                Button { onEvent?(.move(.up)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.init("p"), modifiers: [.control])
                Button { onEvent?(.move(.down)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.init("n"), modifiers: [.control])
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(placeholder, text: $query)
                    .font(.system(size: 18))
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .accessibilityLabel("Search")
                    .onExitCommand { onEvent?(.exit) }
                    .onMoveCommand { onEvent?(.move($0)) }
                    .onSubmit { onEvent?(.submit) }

                if !query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") {
                        query = ""
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .onAppear {
                DispatchQueue.main.async {
                    isTextFieldFocused = true
                }
            }
        }
    }
}

private struct CommandTable: View {
    var options: [CommandOption]
    @Binding var selectedIndex: UInt?
    @Binding var hoveredOptionID: UUID?
    var maxHeight: CGFloat = 200
    var action: (CommandOption) -> Void
    @AccessibilityFocusState private var accessibilityFocusedOptionID: UUID?

    private var selectedOptionID: UUID? {
        guard let selectedIndex, !options.isEmpty else { return nil }
        return options[min(Int(selectedIndex), options.count - 1)].id
    }

    var body: some View {
        if options.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
                .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(options.enumerated()), id: \.1.id) { index, option in
                            CommandRow(
                                option: option,
                                isSelected: {
                                    if let selected = selectedIndex {
                                        return selected == index ||
                                            (selected >= options.count &&
                                                index == options.count - 1)
                                    } else {
                                        return false
                                    }
                                }(),
                                hoveredID: $hoveredOptionID
                            ) {
                                action(option)
                            }
                            .accessibilityFocused(
                                $accessibilityFocusedOptionID,
                                equals: option.id)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: maxHeight)
                .onChange(of: selectedOptionID, initial: true) { _, optionID in
                    guard let optionID else { return }
                    proxy.scrollTo(optionID)
                    accessibilityFocusedOptionID = optionID
                }
            }
        }
    }
}

/// A single row in the command palette.
private struct CommandRow: View {
    let option: CommandOption
    var isSelected: Bool
    @Binding var hoveredID: UUID?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let color = option.leadingColor {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }

                if let icon = option.leadingIcon {
                    Image(systemName: icon)
                        .foregroundStyle(option.emphasis ? Color.accentColor : .secondary)
                        .font(.system(size: 14, weight: .medium))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .fontWeight(option.emphasis ? .medium : .regular)

                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let badge = option.badge, !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.15))
                        )
                        .foregroundStyle(Color.accentColor)
                }

                if let symbols = option.symbols {
                    ShortcutSymbolsView(symbols: symbols)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.2)
                    : (hoveredID == option.id
                       ? Color.secondary.opacity(0.2)
                       : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(option.emphasis && !isSelected ? 0.3 : 0), lineWidth: 1.5)
            )
            .cornerRadius(5)
        }
        .help(option.description ?? "")
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? option.id : nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(option.badge ?? "")
    }
}

/// A row of Text representing a shortcut.
private struct ShortcutSymbolsView: View {
    let symbols: [String]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .frame(minWidth: 13)
            }
        }
    }
}
