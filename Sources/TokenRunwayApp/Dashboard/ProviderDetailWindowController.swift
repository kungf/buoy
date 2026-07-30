import AppKit
import SwiftUI
import TokenRunwayCore

/// 单 provider 详情面板（双击球打开，DESIGN.md §8.5 双击=当前 provider 详情）。
@MainActor
final class ProviderDetailWindowController {
    private let panel: NSPanel

    init(store: UsageStore, providerId: String) {
        let hosting = NSHostingController(
            rootView: ProviderDetailView(store: store, providerId: providerId))
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "\(providerId) 详情"
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
                    Image(systemName: ProviderTheme.theme(for: providerId).icon)
                        .foregroundStyle(ProviderTheme.theme(for: providerId).color)
                    Text(report.providerId).font(.headline)
                    Spacer()
                    Text("更新于 \(report.fetchedAt, style: .relative)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Divider()
                ForEach(report.quotas) { quota in
                    QuotaRow(quota: quota, eta: store.eta(for: quota), samples: store.samples(for: quota.id))
                }
                if let balance = report.balance {
                    Text("余额 \(formatAmount(balance.total)) \(balance.currency)（赠送 \(formatAmount(balance.granted)) / 充值 \(formatAmount(balance.toppedUp))）")
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
                Text("暂无 \(providerId) 数据").foregroundStyle(.secondary)
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
