import SwiftUI
import TokenRunwayCore

/// Custom-metric management (Dashboard toolbar entry): list + add/edit/delete + test query.
/// Config lives in ~/.trwy/config.json customMetrics (shared with trwyctl); token via providers[<id>].token.
/// Save/delete calls store.reloadCustomMetrics() — hot reload, no restart needed.
struct CustomMetricsSettingsView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss

    @State private var configs: [CustomMetricConfig] = []
    @State private var editing: CustomMetricConfig?
    @State private var showEditor = false
    @State private var error: String?
    @State private var testingId: String?
    @State private var testResults: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自定义指标").font(.headline)
                Spacer()
                Button {
                    editing = nil
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("添加自定义指标")
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            if configs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("还没有自定义指标")
                        .font(.subheadline)
                    Text("添加一个 HTTP 接口，如企业内部的 API 预算用量")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(configs) { config in
                            row(config)
                        }
                    }
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 420, height: 420)
        .onAppear { reload() }
        .sheet(isPresented: $showEditor) {
            CustomMetricEditorView(config: editing) { saved in
                do {
                    try CustomMetricConfigStore.upsert(saved)
                    store.reloadCustomMetrics()
                    Task { await store.refresh() }
                    reload()
                } catch {
                    self.error = "保存失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func row(_ config: CustomMetricConfig) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name).font(.subheadline.weight(.medium))
                Text(querySummary(config))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if testingId == config.id {
                ProgressView().controlSize(.small)
            } else if let result = testResults[config.id] {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(result.contains("失败") ? .red : .green)
            }
            Button("测试") { test(config) }
                .buttonStyle(.borderless)
                .font(.caption)
            Button {
                editing = config
                showEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑")
            Button(role: .destructive) {
                remove(config)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func querySummary(_ config: CustomMetricConfig) -> String {
        var summary = config.url
        if !config.userId.isEmpty { summary += " · user:\(config.userId)" }
        return summary
    }

    /// Test query: fetch once with the current config, show usage / max (or balance)
    private func test(_ config: CustomMetricConfig) {
        testingId = config.id
        testResults.removeValue(forKey: config.id)
        Task {
            defer { testingId = nil }
            let result: String
            do {
                let provider = CustomMetricsProvider(config: config)
                let stored = CredentialStore.credential(for: config.id, from: CredentialStore.load())
                let report = try await provider.fetchUsage(credential: stored ?? .none)
                let quota = report.quotas[0]
                if let limit = quota.limit {
                    let pct = quota.percentUsed.map { String(format: "%.1f%%", $0 * 100) } ?? "--"
                    result = String(format: "%.1f / %.1f (%@)", quota.used ?? 0, limit, pct)
                } else {
                    result = String(format: "剩余 %.1f", quota.remaining ?? 0)
                }
            } catch {
                result = "失败：\(Self.describe(error))"
            }
            testResults[config.id] = result
        }
    }

    private func remove(_ config: CustomMetricConfig) {
        do {
            try CustomMetricConfigStore.remove(id: config.id)
            store.reloadCustomMetrics()
            reload()
        } catch {
            self.error = "删除失败：\(error.localizedDescription)"
        }
    }

    private func reload() {
        configs = CustomMetricConfigStore.load()
    }

    /// Human-readable error text (same as UsageStore; never leaks server free text)
    static func describe(_ error: Error) -> String {
        guard let providerError = error as? ProviderError else { return error.localizedDescription }
        switch providerError {
        case .missingCredential: return "Missing credential"
        case .unauthorized: return "Auth failed (check key)"
        case .rateLimited: return "Rate limited, will retry"
        case .network(let msg): return "Network error: \(msg)"
        case .parse(let msg): return "Parse error: \(msg)"
        case .unknown(let code): return "HTTP \(code)"
        }
    }
}

/// Add/edit custom-metric form. Required: name, endpoint URL; optional: user id, cap, unit, token.
struct CustomMetricEditorView: View {
    /// nil = creating a new one
    let config: CustomMetricConfig?
    let onSave: (CustomMetricConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var urlText = ""
    @State private var userIdText = ""
    @State private var semanticsChoice = 0   // 0 = used (default), 1 = remaining
    @State private var maxText = ""
    @State private var unitChoice = 0
    @State private var customUnit = ""
    @State private var token = ""
    @State private var error: String?
    @State private var isTesting = false
    @State private var testResult: String?

    // Covers every fixed Unit case so edit-save round-trips never lose the unit
    private static let unitOptions = ["无单位", "人民币", "美元", "Tokens", "点数", "自定义"]
    private static let semanticsOptions = ["已使用（用量）", "余额（剩余量）"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(config == nil ? "添加自定义指标" : "编辑自定义指标")
                .font(.headline)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(.caption.weight(.medium))
                TextField("如：本月 API 预算", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("接口地址").font(.caption.weight(.medium))
                TextField("https://api.corp.com/v1/usage?team=data", text: $urlText)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("用户 ID（可选）").font(.caption.weight(.medium))
                TextField("唯一标识当前用户，如 wyang", text: $userIdText)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("语义").font(.caption.weight(.medium))
                Picker("", selection: $semanticsChoice) {
                    ForEach(Self.semanticsOptions.indices, id: \.self) { i in
                        Text(Self.semanticsOptions[i]).tag(i)
                    }
                }
                .labelsHidden()
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(semanticsChoice == 0 ? "上限（可选）" : "总额度（可选）")
                        .font(.caption.weight(.medium))
                    TextField("如：5000", text: $maxText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("单位（可选）").font(.caption.weight(.medium))
                    Picker("", selection: $unitChoice) {
                        ForEach(Self.unitOptions.indices, id: \.self) { i in
                            Text(Self.unitOptions[i]).tag(i)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
            if unitChoice == 5 {
                TextField("自定义单位，如 GBP", text: $customUnit)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("访问令牌（可选）").font(.caption.weight(.medium))
                SecureField("内网公开端点可留空", text: $token)
                    .textFieldStyle(.roundedBorder)
            }

            Text("已使用（默认）：指标 = 用量，填上限水位 = 已用/上限（满 = 耗尽），不填只显示数值。余额：指标 = 剩余量，填上限水位 = 剩余/上限（满 = 健康），不填为余额球。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()

            HStack {
                if isTesting {
                    ProgressView().controlSize(.small)
                } else if let testResult {
                    Text(testResult).font(.caption)
                }
                Spacer()
                Button("测试查询") { testQuery() }
                    .disabled(isTesting || !canTest)
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { loadExisting() }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !urlText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canTest: Bool {
        !urlText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var parsedMax: Double? {
        let trimmed = maxText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Double("nan")/"inf" parse successfully — reject them; non-numeric input gets a hint
        guard let value = Double(trimmed), value.isFinite else {
            error = "上限必须是数字（如 5000；留空 = 余额模式）"
            return nil
        }
        return value
    }

    private func currentConfig(id: String? = nil) -> CustomMetricConfig? {
        let semantics: MetricSemantics = semanticsChoice == 1 ? .remaining : .used
        if let max = parsedMax, max <= 0 {
            error = "上限需大于 0（留空 = 无水位）"
            return nil
        }
        // Foundation also has Unit (NSUnit) — qualify with the module in the App target
        let unit: TokenRunwayCore.Unit?
        switch unitChoice {
        case 1: unit = .cny
        case 2: unit = .usd
        case 3: unit = .tokens
        case 4: unit = .credits
        case 5:
            // Empty custom unit = no unit (avoid storing .custom(""))
            let text = customUnit.trimmingCharacters(in: .whitespaces)
            unit = text.isEmpty ? nil : .custom(text)
        default: unit = nil
        }
        return CustomMetricConfig(
            id: id ?? config?.id ?? "custom-\(UUID().uuidString)",
            name: name.trimmingCharacters(in: .whitespaces),
            url: urlText.trimmingCharacters(in: .whitespaces),
            userId: userIdText.trimmingCharacters(in: .whitespaces),
            max: parsedMax,   // used = consumption cap; remaining = total cap (remaining/total)
            unit: unit,
            semantics: semantics
        )
    }

    /// Validate and clean the token: Authorization headers reject control characters
    /// (incl. \r\n — passing them straight to the header crashes or fails the request),
    /// so reject with a hint
    private func sanitizedToken() -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            error = "令牌包含换行或控制字符，请重新粘贴"
            return nil
        }
        return trimmed
    }

    /// Test query: verify metric/label without saving
    private func testQuery() {
        error = nil
        testResult = nil
        guard let config = currentConfig(id: "custom-test") else { return }
        guard let typed = sanitizedToken() else { return }
        isTesting = true
        Task {
            defer { isTesting = false }
            do {
                let provider = CustomMetricsProvider(config: config)
                // Prefer the in-form token (new configs aren't persisted yet); fall back to the
                // stored one, then bare
                let credential: Credential = typed.isEmpty
                    ? (CredentialStore.credential(for: config.id, from: CredentialStore.load()) ?? .none)
                    : .bearer(typed)
                let report = try await provider.fetchUsage(credential: credential)
                let quota = report.quotas[0]
                if let limit = quota.limit {
                    let pct = quota.percentUsed.map { String(format: "%.1f%%", $0 * 100) } ?? "--"
                    testResult = "✓ usage=\(String(format: "%.2f", quota.used ?? 0)) / max=\(String(format: "%.2f", limit)) (\(pct))"
                } else {
                    testResult = "✓ 剩余 \(String(format: "%.2f", quota.remaining ?? 0))"
                }
            } catch {
                testResult = "✗ \(CustomMetricsSettingsView.describe(error))"
            }
        }
    }

    private func loadExisting() {
        guard let config else { return }
        name = config.name
        urlText = config.url
        userIdText = config.userId
        semanticsChoice = config.semantics == .remaining ? 1 : 0
        if let max = config.max { maxText = String(max) }
        switch config.unit {
        case .some(.cny): unitChoice = 1
        case .some(.usd): unitChoice = 2
        case .some(.tokens): unitChoice = 3
        case .some(.credits): unitChoice = 4
        case .some(.custom(let text)): unitChoice = 5; customUnit = text
        case .some(.none): unitChoice = 0
        case nil: unitChoice = 0
        }
        // Prefill the stored token (display only, not required)
        token = CredentialStore.load()?.providers[config.id]?.token ?? ""
    }

    private func save() {
        error = nil
        guard let config = currentConfig() else { return }
        guard let typed = sanitizedToken() else { return }
        do {
            let url = CredentialStore.defaultURL
            var file = CredentialStore.load(from: url) ?? TokenRunwayConfigFile(providers: [:])
            if !typed.isEmpty {
                // Non-empty token: write providers[<id>].token via the existing bearer channel
                var entry = file.providers[config.id] ?? ProviderCredentials()
                entry.auth = "bearer"
                entry.token = typed
                file.providers[config.id] = entry
            } else if file.providers[config.id]?.token != nil {
                // Emptying the token field removes the stored token (otherwise it lingers forever)
                var entry = file.providers[config.id] ?? ProviderCredentials()
                entry.token = nil
                entry.auth = nil
                file.providers[config.id] = entry
            }
            if file.providers[config.id]?.token == nil && file.providers[config.id]?.ak == nil
                && file.providers[config.id]?.sk == nil && file.providers[config.id]?.apiKey == nil {
                file.providers.removeValue(forKey: config.id)   // don't persist empty entries
            }
            try CredentialStore.save(file, to: url)
            onSave(config)
            dismiss()
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
        }
    }
}
