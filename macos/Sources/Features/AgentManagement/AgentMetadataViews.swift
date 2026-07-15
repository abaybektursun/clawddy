import SwiftUI

struct AgentMetadataCompactLine: View {
    var agent: AgentInstance

    var body: some View {
        if let metadata = agent.metadata {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    modelAndEffort(metadata)
                    Spacer(minLength: 6)
                    context(metadata, includesGauge: true)
                }
                HStack(spacing: 5) {
                    modelAndEffort(metadata)
                    Spacer(minLength: 6)
                    context(metadata, includesGauge: false)
                }
                context(metadata, includesGauge: false)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        } else if agent.metadataAvailability == .waiting {
            Label("Loading agent details", systemImage: "ellipsis")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func modelAndEffort(_ metadata: AgentSessionMetadata) -> some View {
        if let model = metadata.displayModel {
            Text(model).lineLimit(1)
        }
        if let effort = metadata.displayEffort {
            Text("·")
            Text("\(effort) effort").lineLimit(1)
        }
    }

    @ViewBuilder
    private func context(_ metadata: AgentSessionMetadata, includesGauge: Bool) -> some View {
        if let fraction = metadata.contextFraction,
           let percentage = metadata.contextPercentText {
            HStack(spacing: 5) {
                if includesGauge {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 38)
                }
                Text("\(percentage) context")
                    .monospacedDigit()
                    .lineLimit(1)
            }
        } else if agent.claudeState == .compacting {
            Text("Context updating").lineLimit(1)
        }
    }
}

struct AgentMetadataSummaryButton: View {
    var agent: AgentInstance
    @Binding var showsDetails: Bool

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: 8) {
                summary
                Spacer(minLength: 8)
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Agent details for \(agent.name)")
        .accessibilityValue(agent.metadataAccessibilityValue)
        .accessibilityHint("Shows model, reasoning effort, and context-window details")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            AgentMetadataInspectorView(agent: agent)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let metadata = agent.metadata {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    summaryValue("Model", value: metadata.displayModel ?? "Not reported")
                    summaryValue("Effort", value: metadata.displayEffort ?? "Not reported")
                    contextSummary(metadata)
                    freshnessSummary(metadata)
                }
                HStack(spacing: 6) {
                    Text([
                        metadata.displayModel,
                        metadata.displayEffort.map { "\($0) effort" },
                        metadata.contextPercentText.map { "\($0) context" },
                    ].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                    freshnessSummary(metadata)
                }
            }
        } else {
            Label(emptySummary, systemImage: emptySummaryIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func summaryValue(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
    }

    private func contextSummary(_ metadata: AgentSessionMetadata) -> some View {
        HStack(spacing: 6) {
            Text("Context")
                .foregroundStyle(.tertiary)
            if let fraction = metadata.contextFraction,
               let percentage = metadata.contextPercentText {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 68)
                Text(percentage)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if agent.claudeState == .compacting {
                Text("Updating")
                    .foregroundStyle(.secondary)
            } else {
                Text("Not reported")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func freshnessSummary(_ metadata: AgentSessionMetadata) -> some View {
        if agent.processState == .dead || agent.processState == .inactive || agent.metadataAvailability == .waiting {
            Label("Last reported \(metadata.observedAt.formatted(.relative(presentation: .named)))", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var emptySummary: String {
        switch agent.metadataAvailability {
        case .notStarted:
            return "Model, effort, and context appear after the agent starts."
        case .waiting:
            return "Loading agent details…"
        case .available:
            return agent.claudeState == .compacting
                ? "Context estimate updating…"
                : "Agent details have not been reported yet."
        case .unavailable(let reason):
            return reason
        }
    }

    private var emptySummaryIcon: String {
        switch agent.metadataAvailability {
        case .waiting, .available: return "ellipsis"
        case .unavailable: return "exclamationmark.circle"
        case .notStarted: return "info.circle"
        }
    }
}

private struct AgentMetadataInspectorView: View {
    var agent: AgentInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Details")
                    .font(.headline)
                Text(agent.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let metadata = agent.metadata {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                    detailRow("Model", metadata.displayModel ?? "Not reported")
                    detailRow("Model ID", metadata.modelID ?? "Not reported")
                    detailRow("Reasoning effort", metadata.displayEffort ?? "Not reported")
                    detailRow("Extended thinking", metadata.thinkingEnabled.map { $0 ? "On" : "Off" } ?? "Not reported")
                    detailRow("Claude Code", metadata.claudeVersion ?? "Not reported")
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Context window")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(contextDetail(metadata))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let fraction = metadata.contextFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .accessibilityLabel("Context used")
                            .accessibilityValue(contextAccessibilityValue(metadata))
                    } else {
                        Text(agent.claudeState == .compacting
                            ? "Context estimate updating…"
                            : "Context use was not reported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if metadata.totalCostUSD != nil || metadata.durationMilliseconds != nil {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                        if let cost = metadata.totalCostUSD {
                            detailRow("Session cost", cost.formatted(.currency(code: "USD")))
                        }
                        if let duration = metadata.durationMilliseconds {
                            detailRow("Elapsed", Duration.milliseconds(duration).formatted(.time(pattern: .minuteSecond)))
                        }
                        if let input = metadata.totalInputTokens {
                            detailRow("Total input", "\(input.formatted()) tokens")
                        }
                        if let output = metadata.totalOutputTokens {
                            detailRow("Total output", "\(output.formatted()) tokens")
                        }
                    }
                }

                Label(freshnessDetail(metadata), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView {
                    Label("Details Unavailable", systemImage: "info.circle")
                } description: {
                    Text(agent.metadataAccessibilityValue)
                }
                .frame(width: 300, height: 150)
            }
        }
        .padding(18)
        .frame(minWidth: 340, idealWidth: 380)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func contextDetail(_ metadata: AgentSessionMetadata) -> String {
        guard let used = metadata.contextUsedTokens,
              let limit = metadata.contextWindowSize,
              let percent = metadata.contextPercentText
        else { return metadata.contextPercentText ?? "Not reported" }
        return "\(AgentSessionMetadata.formatTokens(used)) of \(AgentSessionMetadata.formatTokens(limit)) · \(percent)"
    }

    private func contextAccessibilityValue(_ metadata: AgentSessionMetadata) -> String {
        guard let used = metadata.contextUsedTokens,
              let limit = metadata.contextWindowSize,
              let percent = metadata.contextPercentText
        else { return metadata.contextPercentText ?? "Not reported" }
        return "\(percent), \(used.formatted()) of \(limit.formatted()) tokens"
    }

    private func freshnessDetail(_ metadata: AgentSessionMetadata) -> String {
        let relative = metadata.observedAt.formatted(.relative(presentation: .named))
        switch agent.processState {
        case .dead: return "Session ended · Last reported \(relative)"
        case .inactive: return "Last reported \(relative)"
        default: return "Updated \(relative)"
        }
    }
}

extension AgentInstance {
    var metadataAccessibilityValue: String {
        guard let metadata else {
            switch metadataAvailability {
            case .notStarted:
                return "Model, reasoning effort, and context are available after the agent starts."
            case .waiting:
                return "Loading agent details."
            case .available:
                return claudeState == .compacting
                    ? "Context estimate is updating."
                    : "Agent details have not been reported."
            case .unavailable(let reason):
                return reason
            }
        }

        var parts = [String]()
        parts.append("Model: \(metadata.displayModel ?? "not reported")")
        parts.append("Reasoning effort: \(metadata.displayEffort ?? "not reported")")
        if let percentage = metadata.contextPercentText {
            parts.append("Context used: \(percentage)")
        } else if claudeState == .compacting {
            parts.append("Context estimate is updating")
        } else {
            parts.append("Context use was not reported")
        }
        if processState == .dead || processState == .inactive || metadataAvailability == .waiting {
            parts.append("Last reported \(metadata.observedAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: ". ") + "."
    }
}
