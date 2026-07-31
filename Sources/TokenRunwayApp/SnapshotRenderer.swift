import AppKit
import SwiftUI
import TokenRunwayCore

/// Virtual screenshot tool: renders DashboardView and BallView to PNGs via SwiftUI ImageRenderer.
/// Zero dependency on physical screen — works even when the Mac is locked.
enum SnapshotRenderer {
    private static let outputDir = "assets"

    @MainActor
    static func renderAll() async {
        let store = UsageStore()
        store.loadMockScenario("mixed")

        // Wait briefly for the store to propagate state
        try? await Task.sleep(for: .seconds(0.1))

        let fm = FileManager.default
        let dir = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(outputDir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Render on main thread (required by ImageRenderer)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                renderDashboard(store: store, to: dir.appendingPathComponent("dashboard.png"))
                renderBall(store: store, providerId: "volcano", to: dir.appendingPathComponent("ball_volcano.png"))
                renderBall(store: store, providerId: "deepseek", to: dir.appendingPathComponent("ball_deepseek.png"))

                // Copy the best ball as the default ball.png
                let ballSrc = dir.appendingPathComponent("ball_volcano.png")
                let ballDst = dir.appendingPathComponent("ball.png")
                try? fm.removeItem(at: ballDst)
                try? fm.copyItem(at: ballSrc, to: ballDst)

                continuation.resume()
            }
        }
        print("✅ Screenshots saved to \(outputDir)/")
    }

    // MARK: - Dashboard

    @MainActor
    private static func renderDashboard(store: UsageStore, to url: URL) {
        let view = SnapshotDashboardView(store: store)
            .background(Color(NSColor.windowBackgroundColor))
        let nsview = NSHostingView(rootView: view)
        nsview.frame = CGRect(x: 0, y: 0, width: 380, height: 460)
        nsview.appearance = NSAppearance(named: .aqua)
        // Force layout pass so SwiftUI sizes everything before ImageRenderer captures
        nsview.layout()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        guard let image = renderer.nsImage else {
            print("⚠️  Failed to render dashboard")
            return
        }
        saveImage(image, to: url)
    }

    // MARK: - Ball

    @MainActor
    private static func renderBall(store: UsageStore, providerId: String, to url: URL) {
        let model = store.ballModel(for: providerId)
        let view = BallView(model: model, providerId: providerId)
            .frame(width: Theme.canvasSize, height: Theme.canvasSize)
        let nsview = NSHostingView(rootView: view)
        nsview.frame = CGRect(x: 0, y: 0, width: Theme.canvasSize, height: Theme.canvasSize)
        nsview.layout()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        guard let image = renderer.nsImage else {
            print("⚠️  Failed to render ball for \(providerId)")
            return
        }
        saveImage(image, to: url)
    }

    // MARK: - Helpers

    private static func saveImage(_ image: NSImage, to url: URL) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("⚠️  Failed to get CGImage")
            return
        }
        let width = cgImage.width
        let height = cgImage.height
        // Composite onto white background so GitHub renders correctly (no transparent black).
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: info) else {
            print("⚠️  Failed to create CGContext")
            return
        }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flattened = ctx.makeImage() else {
            print("⚠️  Failed to flatten image")
            return
        }
        let rep = NSBitmapImageRep(cgImage: flattened)
        rep.size = NSSize(width: width, height: height)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("⚠️  Failed to encode PNG")
            return
        }
        do {
            try data.write(to: url)
            print("   → \(url.lastPathComponent) (\(width)×\(height))")
        } catch {
            print("⚠️  Failed to write \(url.path): \(error)")
        }
    }
}

// MARK: - Dashboard wrapper (pre-expands volcano section for a good screenshot)

/// Dashboard wrapper that pre-expands sections for a visually interesting screenshot.
private struct SnapshotDashboardView: View {
    @ObservedObject var store: UsageStore
    @State private var expanded: Set<String> = ["volcano"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Toolbar
            HStack {
                Spacer()
                Button { } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                Button { } label: {
                    Image(systemName: "pin")
                }
                .buttonStyle(.borderless)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.reports, id: \.providerId) { report in
                        SnapshotProviderSection(
                            store: store,
                            report: report,
                            isExpanded: expanded.contains(report.providerId),
                            onToggle: {
                                if expanded.contains(report.providerId) {
                                    expanded.remove(report.providerId)
                                } else {
                                    expanded.insert(report.providerId)
                                }
                            }
                        )
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 380, height: 460)
    }
}

private struct SnapshotProviderSection: View {
    let store: UsageStore
    let report: ProviderReport
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
                    Image(systemName: "eye.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
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
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(quota.label).font(.caption)
                                Spacer()
                                Text(usageText(for: quota))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let percent = quota.percentUsed {
                                ProgressView(value: percent)
                                    .tint(Theme.healthColor(HealthScore.score(quota: quota, etaSeconds: nil)))
                            }
                        }
                    }
                    HStack {
                        Text("Updated just now")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
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

    private func usageText(for quota: Quota) -> String {
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