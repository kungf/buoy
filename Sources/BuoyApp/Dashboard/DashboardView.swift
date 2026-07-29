import SwiftUI
import BuoyCore

/// 总面板：手风琴布局（DESIGN.md §8.2）。顶部 = 刷新 + 球上展示 provider 切换。
struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Buoy 总面板").font(.headline)
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
                .help("立即刷新")
                Picker("球上展示", selection: $store.displayProviderId) {
                    ForEach(store.reports, id: \.providerId) { report in
                        Text(report.providerId).tag(report.providerId)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
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
                    // 有错误但从未拿到数据的 provider（不出现在 reports 里）
                    ForEach(store.providerErrors.keys.sorted().filter { id in
                        !store.reports.contains { $0.providerId == id }
                    }, id: \.self) { id in
                        HStack(spacing: 8) {
                            Circle().fill(.gray).frame(width: 8, height: 8)
                            Text(id).font(.subheadline.weight(.medium))
                            Spacer()
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

/// 单个 provider 的手风琴分区：头部 = 名称 + 健康点 + 主指标；展开 = 各 quota 行 + 抓取时间。
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
                    Text(report.providerId).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(primaryMetric)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
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
                            Text("余额（赠送 \(formatAmount(balance.granted)) / 充值 \(formatAmount(balance.toppedUp))）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(formatAmount(balance.total)) \(balance.currency)")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    HStack {
                        Text("更新于 \(report.fetchedAt, style: .relative)")
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

/// 单条 quota：label + 进度条 + 用量文本 + reset 时刻。
private struct QuotaRow: View {
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
            return "剩 \(quota.effectiveRemaining.map { formatNumber($0) } ?? "--")"
        }
        return "\(used) / \(limit)"
    }

    private func formatNumber(_ value: Double) -> String {
        if value >= 10_000 { return String(format: "%.1fk", value / 1000) }
        return String(format: "%.0f", value)
    }
}
