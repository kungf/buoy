import Foundation
import TokenRunwayCore

/// trwyctl - 适配器联调 harness。
/// 凭证来源（优先级从高到低；绝不打印、不写盘、不入仓库）：
///   bearer:        env TRWY_<envPrefix>_TOKEN
///   volcSignature: env TRWY_<envPrefix>_AK / TRWY_<envPrefix>_SK
///   -> ~/.trwy/config.json（CredentialStore）
/// envPrefix 取自 manifest（DeepSeek=DEEPSEEK，火山=VOLC）；用法: trwyctl <id> | all

/// 拼出 env 变量前缀，如 "TRWY_DEEPSEEK_" / "TRWY_VOLC_"。
private func envVarPrefix(for provider: any Provider) -> String {
    "TRWY_\(provider.manifest.envPrefix)_"
}

func envCredential(for provider: any Provider) -> Credential? {
    let env = ProcessInfo.processInfo.environment
    let prefix = envVarPrefix(for: provider)
    switch provider.manifest.authMode {
    case .bearer:
        if let t = env[prefix + "TOKEN"], !t.isEmpty { return .bearer(t) }
    case .volcSignature:
        if let ak = env[prefix + "AK"], let sk = env[prefix + "SK"],
           !ak.isEmpty, !sk.isEmpty {
            return .volcAccessKey(ak: ak, sk: sk)
        }
    case .consoleSession:
        break
    case .localCLI:
        // 无 env 变量：登录态直接来自本机 CLI 凭证文件
        break
    }
    return nil
}

func envHint(for provider: any Provider) -> String {
    let prefix = envVarPrefix(for: provider)
    switch provider.manifest.authMode {
    case .bearer: return "env \(prefix)TOKEN"
    case .volcSignature: return "env \(prefix)AK / \(prefix)SK"
    case .consoleSession: return "console session"
    case .localCLI: return "local \(provider.manifest.displayName) CLI login (~/.kimi-code)"
    }
}

func credential(for provider: any Provider, config: TokenRunwayConfigFile?) -> Credential? {
    if provider.manifest.authMode == .localCLI {
        return CredentialStore.localCLICredential()
    }
    return envCredential(for: provider) ?? CredentialStore.credential(for: provider.manifest.id, from: config)
}

func printReport(_ report: ProviderReport) {
    print("provider: \(report.providerId)  fetchedAt: \(report.fetchedAt)")
    for q in report.quotas {
        var parts = ["\(q.id) [\(q.label)]"]
        if let used = q.used { parts.append("used=\(used)") }
        if let limit = q.limit { parts.append("limit=\(limit)") }
        if let remaining = q.effectiveRemaining { parts.append("remaining=\(remaining)") }
        if let pct = q.percentUsed { parts.append(String(format: "%.1f%%", pct * 100)) }
        if let reset = q.resetsAt { parts.append("reset=\(reset)") }
        print("  " + parts.joined(separator: "  "))
    }
    if let b = report.balance {
        print("  balance: \(b.total) \(b.currency) (granted \(b.granted) / toppedUp \(b.toppedUp))")
    }
}

let arg = CommandLine.arguments.dropFirst().first ?? "all"
let config = CredentialStore.load()

let targets: [any Provider]
if arg == "all" {
    targets = ProviderRegistry.all
} else if let provider = ProviderRegistry.provider(for: arg) {
    targets = [provider]
} else {
    print("unknown provider: \(arg). Known: \(ProviderRegistry.ids.joined(separator: ", "))")
    exit(2)
}

var failed = false
for provider in targets {
    print("== \(provider.manifest.displayName) ==")
    guard let cred = credential(for: provider, config: config) else {
        // Missing credentials: fatal for a single-provider invocation, non-fatal
        // (best-effort skip) for `all` - mirrors the original harness semantics.
        print("跳过：缺少凭证（\(envHint(for: provider)) 或 ~/.trwy/config.json）")
        if arg != "all" { exit(1) }
        continue
    }
    do {
        printReport(try await provider.fetchUsage(credential: cred))
    } catch {
        print("ERROR: \(error)")
        failed = true
    }
}

if failed { exit(1) }
