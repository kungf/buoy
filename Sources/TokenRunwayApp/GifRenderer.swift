import AppKit
import ImageIO
import SwiftUI
import TokenRunwayCore
import UniformTypeIdentifiers

/// Animated GIF renderer (replaces the static snapshot PNGs): drives `BallScene(time:)` over a
/// deterministic time sequence and encodes the frames as a looping GIF via ImageIO.
/// Zero dependency on a physical screen; invoked from `main.swift` via the `--gif` flag.
///
/// Two README demos:
/// - `ball_volcano.gif`  — windowed ball (outer ring 30d / middle ring 7d / core 5h) next to its
///   hover card, so the 月 / 周 / 5h windows are labeled explicitly.
/// - `ball_deepseek.gif` — balance-only ball (¥ in the center + currency badge).
enum GifRenderer {
    // MARK: Seamless-loop math
    //
    // `BallScene` animates with exactly two time-driven terms:
    //   wave phase   = time * 1.8                    (one cycle = 2π/1.8)
    //   breathing    = sin(time·π/period), period = 2.4 − 1.7·urgency  (one full breath = 2·period)
    // A GIF loops seamlessly when `frameCount × delay` is an integer number of BOTH cycles.
    // Setting the two cycle lengths equal — 2π/1.8 = 2·(2.4 − 1.7·urgency) — gives
    // urgency = (2.4 − π/1.8)/1.7 ≈ 0.3851 and a shared cycle ≈ 3.4907 s. 105 frames at
    // delay = cycle/105 renders exactly one wave cycle + two breaths, pixel-perfect loop.

    /// Shared breathing urgency making the wave and breath cycles identical (~0.385).
    private static let breathUrgency = (2.4 - .pi / 1.8) / 1.7
    /// One wave cycle (also two full breaths) in seconds.
    private static let cycle = 2 * Double.pi / 1.8
    /// Frames per loop; `frameCount × frameDelay = cycle` exactly.
    private static let frameCount = 105
    private static let frameDelay = cycle / Double(frameCount)
    private static let outputDir = "assets"

    @MainActor
    static func renderAll() async {
        // Force the light appearance so NSColor-based panel colors are deterministic.
        NSApp.appearance = NSAppearance(named: .aqua)

        let store = UsageStore()
        store.installDemoReport(volcanoReport())
        // Ingest a declining balance series so the hover card's "Spent (last 5h)" row
        // computes ¥0.32 from the samples (the last report stays as the current one).
        for report in deepseekReports() { store.installDemoReport(report) }
        // Self-check: the hover card's 5h spend must equal the ball's demo constant (−¥0.32).
        if let spent = store.consumed5h(for: "deepseek") {
            print("   deepseek demo spent(5h): ¥\(String(format: "%.2f", spent)) (ball shows −¥0.32)")
        }

        let scenes: [(name: String, makeScene: (Double) -> AnyView)] = [
            ("ball_volcano.gif", { time in
                AnyView(volcanoScene(store: store, time: time))
            }),
            ("ball_deepseek.gif", { time in
                AnyView(deepseekScene(store: store, time: time))
            }),
        ]

        for spec in scenes {
            await renderGIF(name: spec.name, makeScene: spec.makeScene)
        }
        print("✅ GIFs saved to \(outputDir)/")
    }

    // MARK: - Scenes

    /// Volcano demo: the windowed ball (月 30d outer ring, 周 7d middle ring, 5h core) with its
    /// hover card alongside — mirrors `UsageStore.windowedBallModel` values (5h 68% / 7d 42% / 30d 76%).
    private static func volcanoScene(store: UsageStore, time: Double) -> some View {
        let model = BallModel(
            mode: .windowed,
            ringUsed: 0.76,        // 月(30d)环:已用 76% (环 = used-progress)
            midRingUsed: 0.42,     // 周(7d)环:已用 42% (环 = used-progress)
            coreLevel: 0.32,       // 5h 核液体:剩余 32% (核 = remaining water level)
            ringHealth: 0.24, midRingHealth: 0.58, coreHealth: 0.32,
            centerText: "32%", subText: "5h",
            spentRecentText: nil, currencyBadge: nil,
            state: .consuming, breathUrgency: breathUrgency, isStale: false, alertBadges: [])
        return HStack(alignment: .center, spacing: Theme.hoverPanelGap) {
            BallScene(model: model, providerId: "volcano", time: time)
            HoverSummaryView(store: store, providerId: "volcano")
                .padding(Theme.hoverPanelPadding)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: Theme.hoverPanelCornerRadius))
                .shadow(color: .black.opacity(0.15), radius: 10, y: -3)
        }
    }

    /// DeepSeek demo: balance-only ball (¥ amount, currency badge) next to its hover card —
    /// mirrors `UsageStore.balanceBallModel` with a healthy ¥42.50 balance. The ball shows
    /// only the last-5h spend amount ("−¥0.32", no window label); the hover card labels it
    /// as "Spent (last 5h)". Breathing urgency is the seamless-loop value so the GIF wraps
    /// without a visible pop.
    private static func deepseekScene(store: UsageStore, time: Double) -> some View {
        let model = BallModel(
            mode: .balance,
            ringUsed: nil, midRingUsed: nil, coreLevel: 0.62,
            ringHealth: nil, midRingHealth: nil, coreHealth: 0.62,
            centerText: "42.50", subText: "",
            spentRecentText: "−¥0.32", currencyBadge: "¥",
            state: .idle, breathUrgency: breathUrgency, isStale: false, alertBadges: [])
        return HStack(alignment: .center, spacing: Theme.hoverPanelGap) {
            BallScene(model: model, providerId: "deepseek", time: time)
            HoverSummaryView(store: store, providerId: "deepseek")
                .padding(Theme.hoverPanelPadding)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: Theme.hoverPanelCornerRadius))
                .shadow(color: .black.opacity(0.15), radius: 10, y: -3)
        }
    }

    /// Volcano report backing the hover card (same percentages as the ball above).
    private static func volcanoReport() -> ProviderReport {
        let now = Date()
        return ProviderReport(
            providerId: "volcano",
            fetchedAt: now,
            quotas: [
                Quota(id: "volcano.5h", type: .timeWindowed, label: "5 小时额度", unit: .credits,
                      used: 6800, limit: 10000,
                      windowStart: now.addingTimeInterval(-2 * 3600),
                      resetsAt: now.addingTimeInterval(3 * 3600)),
                Quota(id: "volcano.7d", type: .timeWindowed, label: "每周额度", unit: .credits,
                      used: 14700, limit: 35000,
                      windowStart: now.addingTimeInterval(-3 * 86400),
                      resetsAt: now.addingTimeInterval(4 * 86400)),
                Quota(id: "volcano.30d", type: .timeWindowed, label: "每月额度", unit: .credits,
                      used: 76000, limit: 100000,
                      windowStart: now.addingTimeInterval(-12 * 86400),
                      resetsAt: now.addingTimeInterval(18 * 86400)),
            ])
    }

    /// DeepSeek demo: a declining balance series (42.50 -> 42.18, 5 samples over 4h) so the
    /// hover card computes "Spent (last 5h) ¥0.32" — matching the ball's "−¥0.32" — and the
    /// sparkline shows a steady upward consumption curve.
    ///
    /// The first sample sits at `now - 4h`, NOT `now - 5h`: `consumed` filters samples with
    /// `at >= now - 5h` evaluated at render time (a few ms after construction), so a sample
    /// exactly at `now - 5h` falls just outside the window and the spend reads 0.26 instead
    /// of 0.32. Balance samples store `used = -remaining` (ForecastEngine convention).
    private static func deepseekReports() -> [ProviderReport] {
        let now = Date()
        let balance = BalanceInfo(currency: "CNY", total: 42.50, granted: 0, toppedUp: 42.50)
        func report(at: Date, remaining: Double) -> ProviderReport {
            ProviderReport(
                providerId: "deepseek",
                fetchedAt: at,
                quotas: [Quota(id: "deepseek.balance", type: .balance, label: "账户余额",
                               unit: .cny, used: -remaining, remaining: remaining)],
                balance: balance)
        }
        return [
            report(at: now.addingTimeInterval(-4 * 3600), remaining: 42.50),
            report(at: now.addingTimeInterval(-3 * 3600), remaining: 42.42),
            report(at: now.addingTimeInterval(-2 * 3600), remaining: 42.34),
            report(at: now.addingTimeInterval(-1 * 3600), remaining: 42.26),
            report(at: now, remaining: 42.18),
        ]
    }

    // MARK: - Frame pipeline

    @MainActor
    private static func renderGIF(name: String, makeScene: (Double) -> AnyView) async {
        var frames: [CGImage] = []
        frames.reserveCapacity(frameCount)

        for i in 0..<frameCount {
            let time = Double(i) * frameDelay
            guard let flattened = renderFrame(makeScene(time)) else {
                print("⚠️  Failed to render frame \(i) of \(name)")
                return
            }
            frames.append(flattened)
        }

        // Seamless-loop self-check: a wrap-around frame exactly one cycle later must be
        // pixel-identical to frame 0 (1 wave cycle + 2 breaths). Proves the GIF loops cleanly.
        // A control render of frame 0 again isolates renderer nondeterminism from loop math
        // (ImageRenderer can dither blur/AA by 1/255 between runs, e.g. the hover-card shadow).
        if let wrap = renderFrame(makeScene(cycle)),
           let again = renderFrame(makeScene(0)) {
            let wrapDiff = pixelDiff(wrap, frames[0])
            let controlDiff = pixelDiff(again, frames[0])
            // At most a few pixels at 1/255 on both the wrap and the control = renderer noise,
            // not loop drift — the loop is as seamless as the renderer can produce.
            let isSeamless = wrapDiff.count == 0 ||
                (wrapDiff.maxDelta <= 1 && wrapDiff.count <= max(controlDiff.count, 1))
            if isSeamless {
                print("   ✓ \(name): wrap-around frame == frame 0 (seamless loop\(wrapDiff.count > 0 ? ", noise \(wrapDiff.count)px @1/255" : ""))")
            } else {
                print("   ⚠️  \(name): wrap differs \(wrapDiff.count)px (maxΔ \(wrapDiff.maxDelta)/255); control: \(controlDiff.count)px")
            }
        }

        let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
        writeGIF(frames, to: url)
    }

    /// Render one scene at a fixed time onto a white background, at 2x scale.
    @MainActor
    private static func renderFrame(_ scene: AnyView) -> CGImage? {
        let renderer = ImageRenderer(content: scene.environment(\.colorScheme, .light))
        renderer.scale = 2.0
        guard let image = renderer.nsImage else { return nil }
        return flattenOntoWhite(image)
    }

    /// Deterministic PNG bytes of a frame (same pixels -> same bytes), for the loop check.
    private static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// Count of pixels that differ between two frames (per-channel, >1/255) and the max channel delta.
    private static func pixelDiff(_ a: CGImage, _ b: CGImage) -> (count: Int, maxDelta: Int) {
        let ra = NSBitmapImageRep(cgImage: a)
        let rb = NSBitmapImageRep(cgImage: b)
        guard ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh else {
            return (-1, -1)
        }
        var count = 0
        var maxDelta = 0
        for y in 0..<ra.pixelsHigh {
            for x in 0..<ra.pixelsWide {
                guard let ca = ra.colorAt(x: x, y: y), let cb = rb.colorAt(x: x, y: y) else { continue }
                let dR = abs(ca.redComponent - cb.redComponent)
                let dG = abs(ca.greenComponent - cb.greenComponent)
                let dB = abs(ca.blueComponent - cb.blueComponent)
                let d = max(dR, max(dG, dB))
                if d > 1.0 / 255.0 + 1e-9 { count += 1 }
                maxDelta = max(maxDelta, Int(d * 255))
            }
        }
        return (count, maxDelta)
    }

    /// Composite onto a white background (GitHub renders transparent images as black) and return
    /// the flattened RGBA CGImage.
    private static func flattenOntoWhite(_ image: NSImage) -> CGImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: - GIF encoding (ImageIO)

    private static func writeGIF(_ frames: [CGImage], to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            print("⚠️  Failed to create GIF destination for \(url.lastPathComponent)")
            return
        }

        // Loop forever.
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ]
        CGImageDestinationSetProperties(dest, fileProperties as CFDictionary)

        let delay = frameDelay
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: delay,
                kCGImagePropertyGIFDelayTime: delay,
            ],
        ]
        for frame in frames {
            CGImageDestinationAddImage(dest, frame, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(dest) else {
            print("⚠️  Failed to finalize GIF \(url.lastPathComponent)")
            return
        }
        print("   → \(url.lastPathComponent) (\(frames.count) frames, \(url.path))")
    }
}
