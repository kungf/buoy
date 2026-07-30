import SwiftUI
import TokenRunwayCore

/// Hover overlay: one row per window for the displayed provider (DESIGN.md §8.5 hover=popover).
struct HoverSummaryView: View {
    @ObservedObject var store: UsageStore
    let providerId: String

    private var theme: ProviderTheme { ProviderTheme.theme(for: providerId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerView
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            if let report = store.reports.first(where: { $0.providerId == providerId }) {
                // Quota rows
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(report.quotas) { quota in
                        quotaRow(quota)
                        if quota.id != report.quotas.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .padding(.vertical, 4)

                // Balance
                if let balance = report.balance {
                    Divider()
                    balanceRow(balance)
                        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
        }
        .frame(width: 240)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 6) {
            Image(systemName: theme.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.color)
                .frame(width: 18, height: 18)
                .background(theme.color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(store.providerDisplayName(for: providerId))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            // Status dot
            Circle()
                .fill(theme.color)
                .frame(width: 5, height: 5)
        }
    }

    // MARK: - Quota row

    private func quotaRow(_ quota: Quota) -> some View {
        let percent = quota.percentUsed ?? 0
        let health = HealthScore.score(quota: quota, etaSeconds: nil)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(quota.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(percentText(quota))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.healthColor(health))
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.primary.opacity(0.1))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.healthColor(health))
                        .frame(width: max(geo.size.width * percent, 4), height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Balance

    private func balanceRow(_ balance: BalanceInfo) -> some View {
        HStack {
            Text("余额")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "¥%.2f", balance.total))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Helpers

    private func percentText(_ quota: Quota) -> String {
        if let percent = quota.percentUsed {
            return String(format: "%.0f%%", percent * 100)
        }
        if let remaining = quota.effectiveRemaining {
            return String(format: "%.1f", remaining)
        }
        return "--"
    }
}
