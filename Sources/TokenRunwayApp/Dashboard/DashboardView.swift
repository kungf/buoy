import SwiftUI
import TokenRunwayCore

/// Dashboard: accordion layout (DESIGN.md §8.2).
struct DashboardView: View {
    @ObservedObject var store: UsageStore
    var onTogglePin: (Bool) -> Void = { _ in }

    @State private var expanded: Set<String> = []
    @State private var isPinned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Toolbar — no redundant title, just actions
            HStack {
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                Button {
                    isPinned.toggle()
                    onTogglePin(isPinned)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(isPinned ? "Unpin" : "Pin")
            }

            // Alert bar (DESIGN.md §8.2): appears when a non-displayed provider is alerting; tap adds it.
            if !store.alertBadges.isEmpty {
                AlertBar(store: store) { id in
                    store.addToSelection(id)
                    expanded.insert(id)
                }
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.reports, id: \.providerId) { report in
                        ProviderSection(
                            store: store,
                            report: report,
                            error: store.providerErrors[report.providerId],
                            isExpanded: expanded.contains(report.providerId),
                            onToggle: { toggle(report.providerId) }
                        )
                    }
                    // Providers with an error but never fetched (not present in reports)
                    ForEach(store.providerErrors.keys.sorted().filter { id in
                        !store.reports.contains { $0.providerId == id }
                    }, id: \.self) { id in
                        HStack(spacing: 8) {
                            Circle().fill(.gray).frame(width: 8, height: 8)
                            Text(id).font(.subheadline.weight(.medium))
                            Spacer()
                            Button {
                                store.toggleSelection(id)
                            } label: {
                                Image(systemName: store.isSelected(id) ? "eye.fill" : "eye")
                                    .font(.caption)
                                    .foregroundStyle(store.isSelected(id) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(store.isSelected(id) ? "On ball — click to remove" : "Add to ball")
                            Text(store.providerErrors[id] ?? "")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 380, height: 460)
        .onAppear { store.refreshIfStale() }
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expanded.contains(id) {
                expanded.remove(id)
            } else {
                expanded.insert(id)
            }
        }
    }
}

/// Alert bar (DESIGN.md §8.2): stacked active alerts, tinted by severity.
private struct AlertBar: View {
    @ObservedObject var store: UsageStore
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.alertBadges) { badge in
                Button { onTap(badge.id) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(severityColor(badge.severity)).frame(width: 8, height: 8)
                        Text("\(badge.id) \(severityText(badge.severity))")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("Switch ▸").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(severityColor(badge.severity).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func severityColor(_ s: BadgeSeverity) -> Color {
        switch s {
        case .fastBurn: return .yellow
        case .nearDepleted: return .orange
        case .depleted: return .red
        case .error: return .gray
        }
    }

    private func severityText(_ s: BadgeSeverity) -> String {
        switch s {
        case .fastBurn: return "burning fast"
        case .nearDepleted: return "near depleted"
        case .depleted: return "depleted"
        case .error: return "fetch error"
        }
    }
}

/// Accordion section for a single provider: header = name + health dot + primary metric;
/// expanded = per-quota rows + fetch time.
private struct ProviderSection: View {
    let store: UsageStore
    let report: ProviderReport
    let error: String?
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(Theme.healthColor(store.healthScore(for: report)))
                        .frame(width: 8, height: 8)
                    Text(store.providerDisplayName(for: report.providerId))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(primaryMetric)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        store.toggleSelection(report.providerId)
                    } label: {
                        Image(systemName: store.isSelected(report.providerId) ? "eye.fill" : "eye")
                            .font(.caption)
                            .foregroundStyle(store.isSelected(report.providerId) ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(store.isSelected(report.providerId) ? "On ball — click to remove" : "Add to ball")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 10)
                VStack(spacing: 8) {
                    ForEach(report.quotas) { quota in
                        QuotaRow(
                            quota: quota,
                            eta: store.eta(for: quota),
                            samples: store.samples(for: quota.id)
                        )
                    }
                    if let balance = report.balance {
                        HStack {
                            Text("Balance (granted \(formatAmount(balance.granted)) / topped-up \(formatAmount(balance.toppedUp)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(formatAmount(balance.total)) \(balance.currency)")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    HStack {
                        Text("Updated \(report.fetchedAt, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if let error {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var primaryMetric: String {
        if let windowed = report.quotas.first(where: { $0.type == .timeWindowed }),
           let percent = windowed.percentUsed {
            return String(format: "%@ %.0f%%", windowed.label, percent * 100)
        }
        if let balance = report.balance {
            return String(format: "%.2f %@", balance.total, balance.currency)
        }
        return "--"
    }

    private func formatAmount(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

/// Quota row: label + progress bar + usage text + reset time (DESIGN.md §8.5 detail/sparkline).
/// internal so ProviderDetailView can reuse it.
struct QuotaRow: View {
    let quota: Quota
    let eta: TimeInterval?
    let samples: [UsageSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(quota.label).font(.caption)
                Spacer()
                Text(usageText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(formatETA(eta))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let percent = quota.percentUsed {
                ProgressView(value: percent)
                    .tint(Theme.healthColor(HealthScore.score(quota: quota, etaSeconds: eta)))
            }
            if samples.count >= 2 {
                Sparkline(values: samples.map(\.used),
                          color: Theme.healthColor(HealthScore.score(quota: quota, etaSeconds: eta)))
                    .frame(height: 14)
            }
            if let resetsAt = quota.resetsAt {
                Text("reset \(resetsAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var usageText: String {
        let used = quota.used.map { formatNumber($0) } ?? "--"
        let limit = quota.limit.map { formatNumber($0) } ?? "--"
        if quota.type == .balance {
            return "\(quota.effectiveRemaining.map { formatNumber($0) } ?? "--") left"
        }
        return "\(used) / \(limit)"
    }

    private func formatNumber(_ value: Double) -> String {
        if value >= 10_000 { return String(format: "%.1fk", value / 1000) }
        return String(format: "%.0f", value)
    }
}
