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
        } else if !agent.launchProfile.searchTerms.isEmpty {
            Text([
                agent.launchProfile.modelID,
                agent.launchProfile.displayReasoningEffort.map { "\($0) requested" },
            ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
        } else if let requested = agent.launchProfile.displayReasoningEffort {
            Text("·")
            Text("\(requested) requested").lineLimit(1)
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
        } else if agent.activityState == .compacting {
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
                    summaryValue("Provider", value: agent.provider.displayName)
                    summaryValue("Model", value: metadata.displayModel ?? "Not reported")
                    summaryValue(
                        metadata.displayEffort == nil
                            && agent.launchProfile.displayReasoningEffort != nil
                            ? "Requested effort" : "Effort",
                        value: metadata.displayEffort
                            ?? agent.launchProfile.displayReasoningEffort
                            ?? capabilityValue(
                                agent.provider.capabilities.effortTelemetry,
                                reported: nil))
                    contextSummary(metadata)
                    freshnessSummary(metadata)
                }
                HStack(spacing: 6) {
                    Text([
                        metadata.displayModel,
                        metadata.displayEffort.map { "\($0) effort" }
                            ?? agent.launchProfile.displayReasoningEffort.map {
                                "\($0) requested"
                            },
                        metadata.contextPercentText.map { "\($0) context" },
                    ].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                    freshnessSummary(metadata)
                }
            }
        } else {
            if agent.launchProfile.modelID != nil
                || agent.launchProfile.displayReasoningEffort != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        summaryValue("Provider", value: agent.provider.displayName)
                        if let model = agent.launchProfile.modelID {
                            summaryValue("Requested model", value: model)
                        }
                        if let effort = agent.launchProfile.displayReasoningEffort {
                            summaryValue("Requested effort", value: effort)
                        }
                    }
                    Label(emptySummary, systemImage: emptySummaryIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Label(emptySummary, systemImage: emptySummaryIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
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
            } else if agent.activityState == .compacting {
                Text("Updating")
                    .foregroundStyle(.secondary)
            } else {
                Text(capabilityValue(
                    agent.provider.capabilities.contextTelemetry,
                    reported: nil))
                    .foregroundStyle(.secondary)
                    .help(agent.provider.capabilities.contextTelemetry.explanation ?? "")
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func freshnessSummary(_ metadata: AgentSessionMetadata) -> some View {
        if agent.processState == .exited || agent.surfaceState == .inactive
            || agent.metadataAvailability == .waiting {
            Label("Last reported \(metadata.observedAt.formatted(.relative(presentation: .named)))", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var emptySummary: String {
        switch agent.metadataAvailability {
        case .notStarted:
            return "\(agent.provider.displayName) details appear after the agent starts."
        case .waiting:
            return "Loading agent details…"
        case .available:
            return agent.activityState == .compacting
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

    private func capabilityValue(
        _ support: AgentCapabilitySupport,
        reported: String?
    ) -> String {
        if let reported { return reported }
        switch support {
        case .supported: return "Not reported"
        case .unavailable: return "Unavailable"
        case .unsupported: return "Not supported"
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

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                detailRow("Provider", agent.provider.displayName)
                if let metadata = agent.metadata {
                    detailRow("Model", metadata.displayModel ?? "Not reported")
                    detailRow("Model ID", metadata.modelID ?? "Not reported")
                    detailRow(
                        "Reasoning effort",
                        detailValue(
                            agent.provider.capabilities.effortTelemetry,
                            reported: metadata.displayEffort))
                    if let requested = agent.launchProfile.displayReasoningEffort {
                        detailRow("Requested effort", requested)
                    }
                    if agent.provider == .claudeCode {
                        detailRow(
                            "Extended thinking",
                            metadata.thinkingEnabled.map { $0 ? "On" : "Off" }
                                ?? "Not reported")
                    }
                    if let permission = metadata.permissionMode {
                        detailRow("Permissions", permission)
                    }
                    detailRow("Runtime", metadata.runtimeVersion ?? "Not reported")
                } else {
                    detailRow("Model", "Not reported")
                    if let requestedModel = agent.launchProfile.modelID {
                        detailRow("Requested model", requestedModel)
                    }
                    detailRow(
                        "Reasoning effort",
                        detailValue(
                            agent.provider.capabilities.effortTelemetry,
                            reported: nil))
                    if let requested = agent.launchProfile.displayReasoningEffort {
                        detailRow("Requested effort", requested)
                    }
                    detailRow("Runtime", "Not reported")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Context window")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let metadata = agent.metadata {
                        Text(contextDetail(metadata))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text(detailValue(
                            agent.provider.capabilities.contextTelemetry,
                            reported: nil))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let metadata = agent.metadata, let fraction = metadata.contextFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Context used")
                        .accessibilityValue(contextAccessibilityValue(metadata))
                } else if agent.activityState == .compacting {
                    Text("Context estimate updating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let metadata = agent.metadata {
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
                Label(agent.metadataAccessibilityValue, systemImage: emptyInspectorIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var emptyInspectorIcon: String {
        if case .unavailable = agent.metadataAvailability {
            return "exclamationmark.circle"
        }
        return "info.circle"
    }

    private func contextDetail(_ metadata: AgentSessionMetadata) -> String {
        guard let used = metadata.contextUsedTokens,
              let limit = metadata.contextWindowSize,
              let percent = metadata.contextPercentText
        else {
            return detailValue(
                agent.provider.capabilities.contextTelemetry,
                reported: metadata.contextPercentText)
        }
        return "\(AgentSessionMetadata.formatTokens(used)) of \(AgentSessionMetadata.formatTokens(limit)) · \(percent)"
    }

    private func contextAccessibilityValue(_ metadata: AgentSessionMetadata) -> String {
        guard let used = metadata.contextUsedTokens,
              let limit = metadata.contextWindowSize,
              let percent = metadata.contextPercentText
        else {
            return detailValue(
                agent.provider.capabilities.contextTelemetry,
                reported: metadata.contextPercentText)
        }
        return "\(percent), \(used.formatted()) of \(limit.formatted()) tokens"
    }

    private func freshnessDetail(_ metadata: AgentSessionMetadata) -> String {
        let relative = metadata.observedAt.formatted(.relative(presentation: .named))
        switch agent.processState {
        case .exited: return "Session ended · Last reported \(relative)"
        case .notStarted: return "Last reported \(relative)"
        default: return "Updated \(relative)"
        }
    }

    private func detailValue(
        _ support: AgentCapabilitySupport,
        reported: String?
    ) -> String {
        if let reported { return reported }
        switch support {
        case .supported: return "Not reported"
        case .unavailable(let reason), .unsupported(let reason): return reason
        }
    }
}

extension AgentInstance {
    var metadataAccessibilityValue: String {
        guard let metadata else {
            var configured = ["Provider: \(provider.displayName)"]
            if let model = launchProfile.modelID {
                configured.append("Requested model: \(model)")
            }
            if let effort = launchProfile.displayReasoningEffort {
                configured.append("Requested effort: \(effort)")
            }
            let availability: String
            switch metadataAvailability {
            case .notStarted:
                availability = "Reported model, reasoning effort, and context are available after the agent starts."
            case .waiting:
                availability = "Loading reported agent details."
            case .available:
                availability = activityState == .compacting
                    ? "Context estimate is updating."
                    : "Agent details have not been reported."
            case .unavailable(let reason):
                availability = reason
            }
            configured.append(availability)
            return configured.joined(separator: ". ")
        }

        var parts = [String]()
        parts.append("Provider: \(provider.displayName)")
        parts.append("Model: \(metadata.displayModel ?? "not reported")")
        parts.append("Reasoning effort: \(metadata.displayEffort ?? "not reported")")
        if let requested = launchProfile.displayReasoningEffort {
            parts.append("Requested effort: \(requested)")
        }
        if let percentage = metadata.contextPercentText {
            parts.append("Context used: \(percentage)")
        } else if activityState == .compacting {
            parts.append("Context estimate is updating")
        } else {
            parts.append("Context use was not reported")
        }
        if processState == .exited || surfaceState == .inactive || metadataAvailability == .waiting {
            parts.append("Last reported \(metadata.observedAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: ". ") + "."
    }
}
