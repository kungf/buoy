import SwiftUI
import TokenRunwayCore

/// Hover card: clean single-provider summary with thin progress bars and
/// a single accent colour drawn from the provider theme.
struct HoverSummaryView: View {
    @ObservedObject var store: UsageStore
    let providerId: String

    private var theme: ProviderTheme { ProviderTheme.theme(for: providerId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if let report = store.reports.first(where: { $0.providerId == providerId }) {
                // Quota list — no dividers, whitespace separates rows
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.quotas) { quota in
                        quotaRow(quota)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

                // Balance
                if report.balance != nil || !report.quotas.isEmpty {
                    Divider()
                        .padding(.horizontal, 14)
                }
                if let balance = report.balance {
                    balanceRow(balance)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
        .frame(width: 220)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            theme.makeImage()
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 16)

            Text(store.providerDisplayName(for: providerId))
                .font(.system(size: 12, weight: .semibold))

            Spacer()

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
            HStack(alignment: .firstTextBaseline) {
                Text(quota.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(percentText(quota))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.healthColor(health))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.08))
                        .frame(height: 2.5)
                    Capsule()
                        .fill(Theme.healthColor(health))
                        .frame(
                            width: max(geo.size.width * percent, geo.size.height),
                            height: 2.5)
                }
            }
            .frame(height: 2.5)
        }
    }

    // MARK: - Balance

    private func balanceRow(_ balance: BalanceInfo) -> some View {
        HStack {
            Text("Balance")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "¥%.2f", balance.total))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
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
