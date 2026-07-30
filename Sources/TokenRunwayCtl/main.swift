import Foundation
import TokenRunwayCore

/// trwyctl — 适配器联调 harness。
/// 凭证来源（优先级从高到低；绝不打印、不写盘、不入仓库）：
///   DeepSeek: env TRWY_DEEPSEEK_TOKEN → ~/.trwy/config.json（CredentialStore）
///   火山:     env TRWY_VOLC_AK / TRWY_VOLC_SK → ~/.trwy/config.json
/// 用法: trwyctl deepseek | volcano | all

func credential(for providerId: String, config: TokenRunwayConfigFile?) -> Credential? {
    let env = ProcessInfo.processInfo.environment
    switch providerId {
    case "deepseek":
        if let t = env["TRWY_DEEPSEEK_TOKEN"], !t.isEmpty { return .bearer(t) }
    case "volcano":
        if let ak = env["TRWY_VOLC_AK"], let sk = env["TRWY_VOLC_SK"], !ak.isEmpty, !sk.isEmpty {
            return .volcAccessKey(ak: ak, sk: sk)
        }
    default:
        break
    }
    return CredentialStore.credential(for: providerId, from: config)
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

do {
    if arg == "deepseek" || arg == "all" {
        guard let cred = credential(for: "deepseek", config: config) else {
            print("deepseek: 未找到凭证（env TRWY_DEEPSEEK_TOKEN 或 ~/.trwy/config.json）")
            exit(1)
        }
        print("== DeepSeek ==")
        printReport(try await DeepSeekProvider().fetchUsage(credential: cred))
    }

    if arg == "volcano" || arg == "all" {
        guard let cred = credential(for: "volcano", config: config) else {
            print("== 火山 ==")
            print("跳过：缺少 IAM AK/SK（方舟控制台右上角头像 → API 访问密钥 → 新建密钥，")
            print("      填入 ~/.trwy/config.json 的 providers.volcano.ak/sk 或 env TRWY_VOLC_AK/SK）")
            if arg == "volcano" { exit(2) }
            exit(0)
        }
        print("== 火山 ==")
        printReport(try await VolcanoProvider().fetchUsage(credential: cred))
    }
} catch {
    print("ERROR: \(error)")
    exit(1)
}
