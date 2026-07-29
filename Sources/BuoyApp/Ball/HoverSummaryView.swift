import SwiftUI
import BuoyCore

/// Hover overlay: one row per window for the displayed provider (DESIGN.md §8.5 hover=popover).
struct HoverSummaryView: View {
    @ObservedObject var store: UsageStore
    let providerId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(providerId)
                .font(.headline)
            if let report = store.reports.first(where: { $0.providerId == providerId }) {
                ForEach(report.quotas) { quota in
                    HStack {
                        Circle()
                            .fill(Theme.healthColor(HealthScore.score(quota: quota, etaSeconds: nil)))
                            .frame(width: 6, height: 6)
                        Text(quota.label)
                            .font(.caption)
                        Spacer()
                        Text(summary(quota))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let balance = report.balance {
                    HStack {
                        Text("余额").font(.caption)
                        Spacer()
                        Text(String(format: "¥%.2f", balance.total))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 220)
    }

    private func summary(_ quota: Quota) -> String {
        if let percent = quota.percentUsed {
            return String(format: "%.0f%% used", percent * 100)
        }
        if let remaining = quota.effectiveRemaining {
            return String(format: "%.2f left", remaining)
        }
        return "--"
    }
}
