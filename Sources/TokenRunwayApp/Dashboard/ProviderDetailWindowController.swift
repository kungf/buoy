import AppKit
import SwiftUI
import TokenRunwayCore

/// Single-provider detail panel (double-click ball, DESIGN.md §8.5).
@MainActor
final class ProviderDetailWindowController {
    private let panel: NSPanel

    init(store: UsageStore, providerId: String) {
        let hosting = NSHostingController(
            rootView: ProviderDetailView(store: store, providerId: providerId))
        let panel = NSPanel(contentViewController: hosting)
        panel.title = providerId
        panel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()
        self.panel = panel
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ProviderDetailView: View {
    @ObservedObject var store: UsageStore
    let providerId: String

    var body: some View {
        if let report = store.reports.first(where: { $0.providerId == providerId }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ProviderTheme.theme(for: providerId).makeImage()
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 18)
                    Text(store.providerDisplayName(for: providerId))
                        .font(.headline)
                    Spacer()
                    Text("Updated \(report.fetchedAt, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Divider()
                ForEach(report.quotas) { quota in
                    QuotaRow(quota: quota, eta: store.eta(for: quota), samples: store.samples(for: quota.id))
                }
                if let balance = report.balance {
                    Text("Balance \(formatAmount(balance.total)) \(balance.currency) (granted \(formatAmount(balance.granted)) / topped-up \(formatAmount(balance.toppedUp)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.providerErrors[providerId] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(16)
            .frame(width: 320)
        } else {
            VStack(spacing: 6) {
                Text("No data for \(providerId)").foregroundStyle(.secondary)
                if let error = store.providerErrors[providerId] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
            .frame(width: 280)
        }
    }

    private func formatAmount(_ value: Double) -> String { String(format: "%.2f", value) }
}
