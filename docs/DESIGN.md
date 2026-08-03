# TokenRunway (formerly Buoy) - Design Document

> A persistent floating ball on the macOS desktop that shows API token / quota consumption across multiple providers at a glance, and raises an alert when quota is being burned through quickly.
> Tech stack: SwiftUI + AppKit (native). TokenRunway = token remaining runway; early codename Buoy: a ball floating on the desktop, its water line rising and falling with quota, flashing red when in danger - not a metaphor, but the literal description.

---

## 0. Overview

### 0.1 One-Sentence Positioning
Compress "opening 5 provider websites to check quota" into "a glance at the desktop ball".

### 0.2 Core Value
- **Glanceable**: know consumption at a glance, without opening a browser or leaving current work.
- **Unified multi-provider view**: Volcano (three-tier rolling 5h / week / month), DeepSeek (pure balance), MiMo (monthly), OpenAI / Anthropic (each with its own billing cycle and quota) - presented homogeneously: the ball surface focuses on a single provider (showing only one at a time), a single click opens the overview panel to survey all (§8.1).
- **Prediction over reporting**: give an ETA based on burn rate ("5h quota has 12 minutes left at the current rate"), directly hitting the pain point of "only noticing after 5 hours of quota is burned through in 10 minutes".
- **Persistent and low-overhead**: native SwiftUI, tiny resident memory and CPU usage; never steals focus; click-through is a toggleable mode (pass-through / interactive, see §8.5).

### 0.3 Competitor Landscape (2026-07 research)

The AI quota monitoring space is crowded, but the form factors converge - **all of them are menu bar / CLI / system tray, nobody does a floating ball**:

| Project | Form | Coverage | Notes |
|---|---|---|---|
| Claude-Code-Usage-Monitor (8.5k⭐) | Python CLI | Claude only | Already has burn rate prediction; "prediction" is not a unique selling point |
| ClaudeBar (1.4k⭐) | Swift menu bar | Claude/Codex/Gemini | Multiple assistants |
| TokenEater (442⭐) | Native macOS overlay | Claude only | Form factor closest to TokenRunway |
| ClaudeMeter (125⭐) | Swift menu bar | Claude 5h session + 7d weekly quota | Window concept isomorphic to Volcano AFP |

**TokenRunway differentiation**: (1) exclusive floating-ball form factor (water line + breathing rhythm); (2) a vacuum for Chinese providers (Volcano ARK / DeepSeek / MiMo are covered by nobody); (3) unified Quota model + adapter-first (all existing tools do single-provider hardcoded parsing).
**Name-collision check**: no exact same name on the App Store; GitHub has Buoy-gg (a React Native debugging tool, Electron), audiences do not overlap; differentiate via icon / domain at release.

### 0.4 Non-Goals (MVP phase)
- No request-level real-time monitoring (no interception / proxying of API calls); rely only on periodic pulls from provider official usage / billing APIs.
- No cross-platform (macOS only; decided 2026-07: the Windows tray space already has competitors, TokenRunway's opening is native macOS + Chinese providers. Escape hatch: the `Core/` layer only depends on Foundation with zero AppKit/SwiftUI imports, so if Windows is ever pursued - Tauri the first choice - only the UI and platform capability layers need rewriting; Core logic ports per this design).
- No team / multi-account management (single machine, single user).
- No provider gateway or aggregation service (pure local client, direct connection).

---

## 1. Core Concepts and Design Principles

1. **Adapter-first**: all provider differences converge in the adapter layer; the upper UI / scheduling / prediction layers only recognize the unified model and never sense provider details.
2. **Unified quota model (core abstraction)**: describe every billing shape with a set of orthogonal `QuotaType` (time window / balance / rate limit); one provider returns 0~N `Quota` at a time.
3. **Prediction > reporting**: not just "used X / Y", but computing burn rate and ETA, making "fast" a perceivable rhythm.
4. **Graceful degradation**: on fetch failure show the last successful values + a stale marker, so the ball doesn't "jump blindly".
5. **Restrained persistence**: low-frequency polling, staggered scheduling, local caching, never steals focus.
6. **Keys never touch disk**: API keys live only in the Keychain, never written to disk in plaintext, never in logs, never uploaded to third parties.

---

## 2. System Architecture

### 2.1 Layers and Data Flow

```
┌──────────────────────────────────────────────────┐
│  UI 层   FloatingBallView (NSPanel, .floating)    │
│          Popover 详情 / 菜单栏 / 设置窗           │
└───────────────────▲──────────────────────────────┘
                    │ 订阅 @Published
┌───────────────────┴──────────────────────────────┐
│  应用服务层   UsageStore (ObservableObject)      │
│    • 聚合各 provider 的 ProviderReport           │
│    • 计算燃烧率 / ETA / 预警                      │
│    • 持久化本地缓存（上次成功值 + 样本序列）     │
└───────────▲───────────────────────▲──────────────┘
            │ 调度                   │ 读取凭证
┌───────────┴───────────┐   ┌────────┴──────────────┐
│  调度器 PollScheduler │   │  凭证 / 会话层         │
│   per-provider        │   │  • SecretStore(Keychain) bearer/volc 凭证
│   interval + 退避     │   │  • ConsoleSessionCtrl(WKWebView) console 模式
└───────────▲───────────┘   └───────────────────────┘
            │ async fetch
┌───────────┴──────────────────────────────────────┐
│  Provider 适配层 (protocol Provider)             │
│   Volcano / DeepSeek / MiMo / OpenAI / Anthropic │
│   bearer/volcSignature 直连 HTTP；consoleSession 经 WebView    │
└──────────────────────────────────────────────────┘
```

### 2.2 Process Model
Single process. One persistent `NSPanel` (floating ball) + one menu bar item + one `Window` for settings.
Background fetching uses `async/await` + `URLSession`, driven by `PollScheduler`; no background daemon in the MVP.

---

## 3. Unified Quota Model (core abstraction)

Normalize all billing shapes into one set of `Quota`. One provider returns 0~N quotas per fetch, and the upper layers never need to know "is this Volcano or DeepSeek".

### 3.1 QuotaType

```swift
enum QuotaType {
    case timeWindowed   // 滚动时间窗：有 windowStart/End，到点 reset
                        //   火山 5h / 7d / 30d；MiMo 月度；OpenAI/Anthropic 计费周期
    case balance        // 余额型：纯账户余额，无时间窗 reset
                        //   DeepSeek 账户余额（有钱就能用）
    case rateLimit      // 速率限制：TPM/RPM（次要，MVP 可不接）
}
```

### 3.2 Quota

```swift
enum Unit { case tokens, credits, usd, cny }   // 火山 AFP 点数=.credits；DeepSeek 余额=.cny

struct Quota: Identifiable {
    let id: String              // "volcano.5h" / "deepseek.balance" / "openai.cycle"
    let type: QuotaType
    let label: String           // "5 小时额度" / "账户余额" / "本月花费"
    let unit: Unit              // .tokens / .credits / .usd / .cny

    let used: Double?           // 已用（部分 provider 只给 used，无 limit）
    let limit: Double?           // 上限（nil = 无上限 / 未知）
    let remaining: Double?      // 剩余（部分 provider 直接给）

    let windowStart: Date?      // 仅 timeWindowed
    let resetsAt: Date?         // 窗口结束 / reset 时刻
}
// 派生量（percent / eta / healthScore）由 UsageStore 计算，不存原始 Quota，保持值类型纯净。
// 注意：不同 unit 之间禁止跨 provider 聚合求和（AFP 点数与人民币无可比性），UI 只在同 provider 内展示。
```

### 3.3 ProviderReport

```swift
struct ProviderReport {
    let providerId: String
    let fetchedAt: Date
    let quotas: [Quota]
    let balance: BalanceInfo?   // 余额型附加（货币、赠送 vs 充值拆分）
}
```

### 3.4 Provider -> Quota Mapping (corresponding to your description)

| Provider | Quota returned | Type | Notes |
|---|---|---|---|
| Volcano | 4 timeWindowed (5h / 1d / 7d / 30d, via GetAFPUsage) | AK/SK signature | Carousel 5h/7d/30d |
| DeepSeek | 1 balance | Account balance | Use as long as you have money |
| Kimi Code | 1 timeWindowed (7d weekly quota) + N timeWindowed (rolling rate-limit windows, e.g. 300m) + optional balance (booster pack, only STATUS_ENABLED) | localCLI (local CLI OAuth login state) | Zero config, reuses `kimi` CLI login |
| MiMo | 1 timeWindowed (monthly) | Calendar month or 30-day rolling (to be verified) | Single ring |
| OpenAI | timeWindowed (billing cycle) + balance (grant) | Spend + quota | Optional rateLimit |
| Anthropic | timeWindowed (billing cycle) + per-day usage | Spend + usage | - |

> "Each provider resets differently" is fully digested at the model layer: the upper layers only see a set of `Quota`, and UI / prediction logic is completely reused.

---

## 4. Provider Adapter Interface

```swift
/// 鉴权模式：三种（provider 选其一）
enum AuthMode {
    case bearer            // { baseURL, apiToken }：Bearer 直连（DeepSeek / OpenAI / Anthropic）
    case volcSignature     // { baseURL, accessKey, secretKey }：Volc Signature V4 HMAC（火山）
    case consoleSession    // 控制台浏览器登录态：经内嵌 WKWebView（无 API 的 provider 兜底）
    case localCLI          // 本机 CLI OAuth 登录态：读 CLI 凭证文件（Kimi Code），无需用户配置
}

/// console 模式取数规格（每个控制台一份，内置；用户不可见）
struct ConsoleSessionSpec {
    let loginURL: String               // 控制台登录页 / 额度页（如火山 subscription/agent-plan）
    let quotaEndpointPattern: String    // 拦截 XHR 的 URL 模式（子串 / 正则）
    let extractors: [QuotaExtractor]     // 响应 JSON -> used / limit / reset 的 jsonPath 映射
}

struct ProviderManifest {
    let id: String
    let displayName: String
    let icon: ImageAsset
    let authMode: AuthMode
    let defaultBaseURL: String?            // bearer / volcSignature 预填（自建 / 代理可改）
    let allowsBaseURLOverride: Bool
    let consoleSession: ConsoleSessionSpec?    // 仅 console 模式
    // 用户配置：bearer = { baseURL, token }；volcSignature = { baseURL, AK, SK }；console = { 一次 App 内登录 }
}

/// 凭证（注入式，适配器不持有）
enum Credential {
    case bearer(String)                       // DeepSeek/OpenAI/Anthropic，来自 Keychain
    case volcAccessKey(ak: String, sk: String) // 火山 AK/SK，来自 Keychain
    case consoleSession(SessionHandle)         // 来自 ConsoleSessionController
}

protocol Provider: Identifiable {
    var manifest: ProviderManifest { get }   // id / displayName / icon / authMode 的唯一事实源
    var id: String { get }                   // = manifest.id
    var supportedQuotaTypes: [QuotaType] { get }

    func fetchUsage(credential: Credential) async throws -> ProviderReport
}

protocol ProviderConfig {
    static var manifest: ProviderManifest { get }
    static func make() -> Provider
}
```

**ConsoleSessionController** (core component of console mode, Core/Auth):
- Each console provider holds a hidden `WKWebView` loading `loginURL`.
- Inject `WKUserScript` to hook the page's own `fetch` / `XHR`, intercept quota endpoint responses per `quotaEndpointPattern`, hand the JSON back to Swift via `WKScriptMessageHandler`, and parse it into `Quota` with `extractors`.
- Refresh = reload the page; session expiry (API 401 / redirected to login page) -> mark stale and prompt to log in again.
- The user logs in once inside the app; 2FA / SMS / verification codes are handled automatically by the WebView's real browser context; **the app never touches passwords**.

**ProviderRegistry**: compile-time registration (or plist + reflection); enumerated by the settings window's "add provider". Adding a provider = adding a `Provider`-conforming type + one registration line.

**Error model**:

```swift
enum ProviderError: Error {
    case missingCredential
    case unauthorized        // 401
    case rateLimited         // 429
    case network(Error)
    case parse(String)       // 响应结构变更
    case unknown             // 5xx 等
}
```

> In volcSignature mode, a 401 must distinguish "credential error" from "local clock drift" (X-Date out of window invalidates the signature): the two need different message copy, and clock drift should guide the user to calibrate the system time.

---

## 5. Per-Provider Adapter Specs

> Baseline: **DeepSeek (bearer / balance) + Volcano (volcSignature / 5h·7d·30d)**, both APIs already confirmed. MiMo / OpenAI / Anthropic to be added in later phases.

### 5.1 DeepSeek ✅ Confirmed (apiKey mode)

| Item | Value |
|---|---|
| AuthMode | `bearer` |
| BaseURL | `https://api.deepseek.com` (changeable to self-hosted / proxy) |
| Endpoint | `GET /user/balance` |
| Auth | `Authorization: Bearer <api_key>` |
| Quota mapping | 1 `balance`: id=`deepseek.balance`, remaining=`total_balance`, unit=`.cny` |

Response:
```json
{
  "is_available": true,
  "balance_infos": [
    { "currency": "CNY", "total_balance": "10.00", "granted_balance": "10.00", "topped_up_balance": "0.00" }
  ]
}
```
- `granted_balance` = granted balance, `topped_up_balance` = topped-up balance, `total_balance` = total; the detail panel can break these out.
- No time window -> balance type; ETA = total_balance / burn rate (¥/day).

### 5.2 Volcano ✅ Confirmed (volcSignature mode, AK/SK)

Official control-plane OpenAPI exists, **no console login / packet capture needed**. `GetAFPUsage` returns quota for the four windows 5h / day / week / month in one call.

| Item | Value |
|---|---|
| AuthMode | `volcSignature` (AccessKey + SecretKey + HMAC-SHA256, Volc Signature V4) |
| Host | `https://open.volcengineapi.com` (general open gateway; ⚠️ not `ark.cn-beijing.volces.com` - that is the inference endpoint, whose auth layer does not accept IAM AK/SK; verified 401 in practice) |
| Endpoint | `POST /?Action=GetAFPUsage&Version=2024-01-01` |
| Request body | `{}` (empty) |
| Request headers | `Content-Type: application/json`, `X-Date`, `X-Content-Sha256`, `Authorization: HMAC-SHA256 Credential=AK/.../cn-beijing/ark/request, SignedHeaders=host;x-content-sha256;x-date, Signature=...` |
| Credentials | User's Volcano **AccessKey + SecretKey** (IAM credentials, not ARK API Key) |

Response (excerpt):
```json
{
  "ResponseMetadata": { "Action": "GetAFPUsage", "Service": "ark", "Region": "cn-beijing" },
  "Result": {
    "PlanType": "Large",
    "AFPFiveHour": { "Quota": 50.0,  "Used": 12.5, "SubscribeTime": 1778788800000, "ResetTime": 1778806800000 },
    "AFPDaily":   { "Quota": 100.0, "Used": 22.5, "SubscribeTime": 1778716800000, "ResetTime": 1778803200000 },
    "AFPWeekly":  { "Quota": 0, "Used": 0, "SubscribeTime": 0, "ResetTime": 0 },
    "AFPMonthly": { "Quota": 0, "Used": 0, "SubscribeTime": 0, "ResetTime": 0 }
  }
}
```
- Each window object: `Quota` (total quota = limit), `Used` (used), `SubscribeTime` (window start, epoch ms), `ResetTime` (next reset, epoch ms). AFP = plan quota unit (points).
- **Quota mapping**: 4 `timeWindowed`:
  - `volcano.5h` ← `AFPFiveHour`
  - `volcano.1d` ← `AFPDaily` (bonus, hidden by default)
  - `volcano.7d` ← `AFPWeekly`
  - `volcano.30d` ← `AFPMonthly`
  - `used=Used`, `limit=Quota`, `windowStart=SubscribeTime`, `resetsAt=ResetTime`, `unit=.credits`
- **Quota=0 semantics**: a window returning `Quota: 0` (like Weekly/Monthly in the example) means the plan **does not include this window** -> do not generate the corresponding Quota (rather than generating a quota with limit=0), avoiding division by zero and a misleading "0%".
- The ball carousel primarily shows `5h / 7d / 30d`; the daily window goes into the detail panel.
- **Burn rate / ETA**: poll snapshots every ~2 min, compute burn rate from the delta between adjacent `Used` values, `remaining = Quota − Used`, `ETA = remaining / burn rate` -> perfectly supports the "5h quota burned through in 10 minutes" alert.

### 5.3 Kimi Code ✅ Confirmed (localCLI mode, zero config)

No control-plane OpenAPI, and no manually-filled token from the user: **reuse the local Kimi Code CLI's OAuth login state** (sharing the same credential file as the CLI).

| Item | Value |
|---|---|
| AuthMode | `localCLI` (new fourth auth mode: read the local CLI credential file, no user config needed) |
| Credential file | `$KIMI_CODE_HOME/credentials/kimi-code.json` (default `~/.kimi-code`), containing `access_token` / `refresh_token` / `expires_at` |
| Usage endpoint | `GET https://api.kimi.com/coding/v1/usages`, `Authorization: Bearer <access_token>` |
| Refresh endpoint | `POST https://auth.kimi.com/api/oauth/token` (form-urlencoded `grant_type=refresh_token`; when `~/.kimi-code/device_id` exists, send the `X-Msh-Device-Id` header) |
| Quota details page | `https://www.kimi.com/membership/subscription?tab=quota` |

- **Token lifecycle**: access_token is valid for only 15 minutes. Use directly when `expires_at > now + 60s`; otherwise refresh and **write back atomically** (tmp + rename, chmod 0600, preserving unknown fields like `scope` / `token_type`; `refresh_token` is updated from the response when rotated).
- **Multi-process coordination** (consistent with the CLI protocol): re-read the credential file before refreshing; if `refresh_token` has been rotated externally (the CLI just refreshed), use the new access_token from the file directly and abandon this refresh.
- **Not logged in**: credential file missing, or refresh returns 401/403/`invalid_grant` -> `unauthorized`; prompt the user to run `kimi` and execute `/login`.
- **Quota mapping** (response values are all string numbers; `resetTime` is ISO8601 with fractional seconds):
  - `kimi.7d` ← `usage`: **weekly quota** (7-day window), value is a **percentage** (limit is always 100), `windowStart = resetTime − 7d`
  - `kimi.rate.<duration><unit>` ← `limits[]`: rolling rate-limit windows (e.g. 300 minutes = 5-hour window, `kimi.rate.300m`), supports `TIME_UNIT_MINUTE/HOUR/DAY/WEEK`, `windowStart = detail.resetTime − window duration`
  - `kimi.booster` ← `boosterWallet`: booster pack, mapped to `balance` **only when `STATUS_ENABLED`** (unit `.cny`, `priceInCents` in cents); disabled / absent / missing values all skipped, nothing hardcoded
- **Polling**: default 300s (token valid for 15 minutes; no need to poll more often).
- Implementation: `Providers/KimiProvider.swift` (adapter) + `Auth/KimiCLICredentialStore.swift` (credential read / refresh / write-back; HTTPClient injectable; covered by unit tests).

### 5.4 Later Providers (M3)
MiMo / OpenAI / Anthropic deferred; OpenAI / Anthropic most likely bearer (usage / billing APIs), MiMo consoleSession depending on the situation.

---

## 6. Data Fetching and Polling Strategy

- **Polling interval**: per-provider configurable; default follows "shorter window, higher frequency":
  - Volcano 5h window: 2 minutes by default (short window, fast-changing)
  - DeepSeek balance: 5 minutes
  - Monthly types (MiMo / OpenAI / Anthropic): 10~15 minutes
- **Scheduling**: `PollScheduler` holds one timer per provider, **staggered** (avoid all hitting the network at the same time); refresh immediately once when the app returns to the foreground.
- **Backoff**: exponential backoff for 429 / 5xx (max 5 attempts); failures never break the UI.
- **Degradation**: fetch failure -> show `lastGoodReport` (local cache) + stale pulse on the ball surface; switch to error state after N consecutive failures.
- **Cache**: local JSON stores the last successful report + a ring buffer of burn rate samples. The buffer adapts to window length: short windows (5h / 1d) keep the last ~120 raw sample points; long windows (7d / 30d / monthly) additionally maintain daily aggregated points, avoiding a "monthly ETA that actually only reflects the last day".

---

## 7. Burn Rate and Alerts (directly addressing the pain point)

- **Burn rate**: fit a slope over the recent K sample points -> `tokens/min`, `$/hour`. Adjacent sample pairs participating in the fit must satisfy two conditions: (1) **must not cross `resetsAt`** (after a window reset Used jumps back to 0; pairs crossing a reset produce a negative delta and must be discarded); (2) **the gap between adjacent `fetchedAt` < 3x the polling period** (pairs with large holes from system sleep / wake are discarded, so "waking up from a sleep" is not misjudged as blazing burn).
- **ETA**: `remaining / burnRate` -> "at the current rate, the 5h quota has 12 minutes left".
- **Cold start**: with fewer than K samples, ETA shows `--` ("collecting data"), and burn-rate alerts are not triggered (no historical P95 baseline yet).
- **Health score (unified urgency across quotas)**: windowed = `remaining / limit`; balance = normalized ETA health (>7 days = 1.0, <1 day ≈ 0). A provider's urgency takes the minimum across all its quotas; error / stale states do not participate in ranking. Used for the "tightest" display mode (§8.1) and alert ordering.
- **Alert triggers** (macOS `UserNotifications`):
  1. **Burn rate spike**: current rate > N times the historical P95 -> "you are burning through the 5h quota fast".
  2. **ETA critical**: 5h window ETA < 15min and still burning -> "5h quota about to run out".
  3. **Near depletion**: percent > 90% -> gentle notice.
- **Throttling**: the same alert is not re-pushed within its cooldown; cooldown state is persisted, avoiding a re-bombardment after restarting the app.

---

## 8. Floating Ball UI / Animation

### 8.1 Multi-Provider Display Model: Multi-Select Ball Cluster + Overview Panel

**Which providers appear on the ball surface is decided by the user's multi-select in the overview panel** - each selected provider gets one independent ball arranged horizontally on the floating ball (ball cluster); each ball carries one provider's ring + core + numbers, so no information is lost. Polling and alerts for all enabled providers keep running in the background as usual.

- **Multi-select onto the ball**: every provider card in the overview panel has an "eye" toggle; checking it puts the provider on the ball, unchecking removes it; the selected count = the number of balls on the surface. The selected set is persisted to UserDefaults and survives restarts.
- **Default selection**: on first launch (unconfigured), only the first provider is selected by default (in provider initialization order, currently Volcano); after user adjustment, display follows their configuration.
- **Breakout badge (alert badge)**: when any **unselected** provider enters fast-burn / near-depleted / depleted / error, a small dot in that provider's theme color with a subtle pulse appears at the top-right of the cluster; clicking the badge adds that provider to the cluster (a new ball pops out). This is the last line of defense against missed alerts under the "only the first selected by default" setup (system notifications are unaffected and push as usual).
- **Overview panel**: opened by a single click on the ball (or the menu bar icon). One card per enabled provider: ring + core thumbnail, each window's percentage + ETA, sparkline, on-ball toggle; clicking a card enters that provider's detail page. Layout and interaction details in §8.2.

### 8.2 Overview Panel Layout: Accordion List

**Window form**: by default a transient `NSPopover` attached to the ball (auto-closes on outside click, glance and go); the pin button at the top-right can tear it off into a standalone floating window (`NSPanel`) for persistent watching. Width ~340pt, height adapts to content (capped at ~70% of screen height, scrolls beyond that).

```
┌─ TokenRunway ────────────── ⟳ ⚙ ┐
│ 🔥 火山 5h 消耗过快 (2.3× 常态) │ ← 预警条：仅在有活跃预警时出现
├────────────────────────────────┤
│ 🌋 火山引擎     5h 73%  ⏱12m ▾ │ ← 展开中的 provider 卡
│ ┌──┐ 5h  ███████░░ 73% ⏱12m   │
│ │◯◉│ 7d  ███░░░░░░ 41%        │
│ │  │ 30d ██████░░░ 62% R 3h2m │
│ └──┘ ▁▂▅█▇▅▂ 燃烧率 spike     │
│      [刷新] [暂停] [设置]      │
├────────────────────────────────┤
│ 🐋 DeepSeek   ¥42.50  ≈3.2天 ▸ │ ← 收起态：一行
├────────────────────────────────┤
│ 🌙 MiMo       月度 45%       ▸ │
└────────────────────────────────┘
```

**Three-part structure**:

1. **Header** (always present): app name, refresh all ⟳, settings ⚙, pin 📌; the subtitle line shows "updated at HH:MM:SS" (turns yellow when data is stale).
2. **Alert bar** (conditional, multiple can stack): shown only when there are active fast-burn / ETA critical / near-depletion alerts; background color follows the most severe level (yellow / orange / red); clicking locates the corresponding provider card and auto-expands it. With no alerts it is fully collapsed and takes no space.
3. **Provider accordion list**:
   - **Sorting**: ascending by health score (§7), most urgent on top; error / stale do not participate in sorting, sink to the bottom grayed out.
   - **Collapsed state (one line, ~36pt)**: icon + name | most urgent quota label + percentage (balance type shows the amount) | ETA | status dot (green / yellow / red / gray) | ▸.
   - **Expanded state**: ring + core thumbnail on the left (same visual language as the ball), one row per window on the right: progress bar + percent + used/limit + ETA + reset countdown (`R 3h2m`); a sparkline below (recent N points of Used trend, marking burn rate spikes); balance type (DeepSeek) switches to a large balance number + granted / topped-up breakdown + ETA; action row at the bottom: refresh / pause polling / settings.
   - The accordion is **not mutually exclusive**: multiple cards can be expanded at the same time; the expanded state is remembered within the current session.
   - **Single click** on the row header expands / collapses; **double click** on the row header = that provider's detail panel (consistent with the ball's double-click gesture).

### 8.3 Form: Ring + Core (monthly at a glance + flipping through 5h)
One ball per selected provider (diameter ~64pt, adjustable), arranged horizontally into a ball cluster (§8.1); a single ball carries two time scales in two layers:

- **Outer ring (Ring) = monthly 30d, always on**
  - Progress ring = 30d used %, color follows % green->yellow->red; slow variable, ambient.
  - At a glance you know "this month is comfortable / tight"; a "today" tick can be marked on the ring (days elapsed in the month vs used %) to see whether you are ahead of schedule.
- **Inner core (Core / water line) = active window, default 5h**
  - Water line = active window remaining %, color follows %.
  - Breathing / pulse frequency ↔ that window's burn rate (the faster it burns, the faster the breathing).
  - Scroll wheel: switch the core between `5h ↔ 7d` (outer ring unchanged).
- **Color only by default** (ring color + core color + core breathing), no cramped text; numbers only on hover (`30d 62%` / `5h 73%`).
- **Balance type (DeepSeek)**: no multiple windows; the ring degenerates into a single-layer balance ball (water line = balance / observed high point remaining/highWater, showing ¥ balance at the center).
- Non-interfering: 5h burned out but monthly OK -> ring green, core red slow flash ("wait for the 5h reset"); month nearly gone but 5h is a fresh window -> ring red, core green ("month almost at the top").

### 8.4 Visual Encoding (color + rhythm)

**Unified principle**: the water line is always = "health" (a health proxy of remaining time / remaining quota), and the visual language stays consistent when switching between windowed and balance:
- **timeWindowed**: water line = remaining %, color follows used percent↑ green->red
- **balance (DeepSeek)**: no limit, no reset; water line = `remaining / highWater` (remaining ratio relative to the observed high point; a balance jump >10% is treated as a top-up / refresh, re-anchoring the water level back to full; a cliff drop does not re-anchor and keeps the red warning); the balance number `¥42.50` shows at the ball center, with small text above for the last 5h spend `−¥0.32` (time window annotated on the hover card), and a currency badge at the top-right to distinguish from the percentage type
- **Ring and core each get their own color**: outer ring color = monthly 30d %; core color = active window %. The two are independent -> combinations like "green ring, red core" directly express multi-scale states (e.g. 5h burned out but monthly OK).

| State | Trigger | Visual |
|---|---|---|
| idle | No consumption in the recent K minutes | Green, slow breathing |
| consuming | Consuming at a normal rate | Green->cyan, water line changing slowly |
| fast-burn | Burn rate surge | Yellow, faster breathing, "hot air" particles at the ball's edge |
| near-depleted | windowed percent>85% / balance ETA<1 day | Orange, slight jitter |
| depleted | Window exhausted / balance near 0 | Red, slow flash |
| error | Fetch failure / stale | Gray, pulsing dashed outline |

- **Breathing frequency ↔ burn rate**: the faster it burns, the faster the breathing - making "fast" a perceivable rhythm, not just a number.
- The water line uses `TimelineView` + `Canvas` to draw the wave + subtle noise.

### 8.5 Interaction (flipping through 5h)
The unique mapping after gesture disambiguation (each gesture has exactly one meaning). With multiple balls in the cluster, all gestures below act on the provider of the ball under the mouse:

- **hover**: small popover (provider name + the three percentages of 5h/7d/30d + each ETA).
- **Single click**: open the overview panel (all enabled providers at a glance, see §8.1).
- **Double click**: expand the current provider's detail panel:
  - One row per window: percentage + used / limit + reset countdown.
  - One **sparkline burn rate curve** per row (recent N sample points of the Used trend) - this is the history for "flipping through 5h usage", showing whether "that recent batch burned especially fast".
- **Scroll wheel**: switch the core between `5h ↔ 7d` (monthly outer ring unchanged).
- **Drag**: move the ball; near a screen edge it snaps and half-hides into a slim edge bar, expanding on hover.
- **right-click**: menu (refresh / pause polling / click-through mode toggle / open overview panel / open this provider's detail / remove (or add) this provider from the ball / hide ball).
- **Click-through mode**: toggleable in settings / the right-click menu. When enabled, the ball is mouse-transparent, responding to no interaction, purely ambient display; off by default (interactive mode).

### 8.6 Animation Primitives
- `TimelineView(.animation)` drives breathing / the water line.
- `matchedGeometryEffect` for transitions between the ball and the detail panel.
- `PhaseAnimator` (macOS 14+) for state transitions.
- Particles (hot air / sweating) use `Canvas` + a simple particle system.

---

## 9. Configuration UI

- Provider list on the left (+ add), form on the right.
- **bearer mode** (DeepSeek/OpenAI/Anthropic): fill in Base URL + API Token; the token is written straight to the Keychain and never enters state beyond `TextField`.
- **volcSignature mode** (Volcano): fill in Base URL + AccessKey + SecretKey; AK/SK written straight to the Keychain.
- **consoleSession mode** (fallback for providers without an API): only prefill the console address, with a "Log in" button -> launch the embedded WKWebView to complete the login; show session status.
- Window definitions / parsing logic are built in; never ask the user for quota limits.
- Appearance: ball size, opacity, theme color, launch at login, default core window (5h / 7d), multi-select of on-ball providers (see §8.1), click-through mode toggle.
- menu bar: open the overview panel, quickly toggle providers, view ETA.

---

## 10. Security / Keychain

- `SecretStore`: a thin wrapper over `SecItemAdd / Update / Copy`, `kSecClassGenericPassword`, `account = providerId`.
- **API key**: never written to disk in plaintext, never in logs, never uploaded to third parties; stored only in the Keychain.
- **console session**: session cookies are treated as secrets, stored only in the WKWebView cookie store (or Keychain-serialized), never in plaintext on disk, never in logs; **login passwords are never read / recorded** (passwords only live in the WebView's secure context); each console gets an independent WebView + independent cookies, never cross-contaminating; console mode is off by default and explicitly enabled by the user.
- Network is HTTPS-only direct connection (ATS + certificate validation), defaulting to provider official domains only; when the user customizes baseURL (self-hosted / proxy), explicitly warn and confirm its safety. App Sandbox enabled (note: macOS sandbox network permission is a boolean switch with no domain-level allowlist; constraints are implemented via ATS + code-level domain validation).
- First Keychain access goes through the system authorization prompt.

---

## 11. Project Structure

> Bundle ID: `com.wyang.tokenrunway` | App display name: **TokenRunway** | Subtitle: *AI token & quota monitor*

```
TokenRunway/
├── App/                  TokenRunwayApp, AppDelegate, MenuBar
├── UI/
│   ├── FloatingBall/     BallView, LiquidCanvas, ParticleLayer
│   ├── Detail/           DetailPanel, BurnRateChart
│   └── Settings/         SettingsView, ProviderForm
├── Core/
│   ├── Model/            Quota, QuotaType, ProviderReport, Unit
│   ├── Store/            UsageStore, PollScheduler
│   ├── Auth/             SecretStore (Keychain), ConsoleSessionController (WKWebView + XHR hook)
│   └── Forecast/         BurnRate, ETA, AlertEngine
├── Providers/
│   ├── Provider.swift    protocol + registry
│   ├── Volcano/
│   ├── DeepSeek/
│   ├── MiMo/
│   ├── OpenAI/
│   └── Anthropic/
├── Networking/           HTTPClient, retry/backoff
├── Resources/            Assets, provider icons
└── Tests/                unit + adapter 集成（recorded fixture）
```

---

## 12. Milestones / MVP Roadmap

- **M0 skeleton**: empty app + floating ball + overview panel + fake-data-driven UI / animation (validate visuals and interaction gestures).
- **M1 dual adapters**: DeepSeek (bearer / balance) + Volcano (volcSignature / GetAFPUsage, 5h·7d·30d) running real data end-to-end. Both APIs already confirmed.
- **M2 prediction**: burn rate + ETA + alert notifications.
- **M3 multi-provider + polish**: MiMo / OpenAI / Anthropic, settings UI, menu bar, launch at login.

---

## 13. Open Questions / Risks

- ✅ **Volcano 5h / weekly / monthly quota**: confirmed official OpenAPI `GetAFPUsage` (AK/SK + Volc Signature V4), returning `Quota / Used / SubscribeTime / ResetTime` for the four windows 5h/day/week/month in one call. Uses `volcSignature` mode, **no console login needed**. Requires the user's Volcano AccessKey + SecretKey (IAM credentials, not ARK API Key).
  - To verify: whether the user's actual plan returns all four windows (the sample doc shows FiveHour / Daily; Weekly / Monthly share the same structure); AFP is a quota point unit (not raw tokens).
- ConsoleSession is demoted to the fallback for "providers without an API" (e.g. MiMo if it is console-only); Volcano no longer needs it.
- DeepSeek goes bearer (the balance API gives remaining directly).
- Whether MiMo's monthly window is a calendar month or a 30-day rolling one, to be verified.
- Whether OpenAI / Anthropic usage API granularity is fine enough (if per-day only, it does not serve the "5h window"; the provider would need its own windows).
- ~~Minimum macOS version~~ decided: **macOS 14+** (`PhaseAnimator` usable directly; a reasonable base in 2026).
- Volcano control-plane OpenAPI rate limits itself: GetAFPUsage polled every 2min ≈ 720 calls/day; need to confirm it stays within the call quota.
- DeepSeek `granted_balance` (granted balance) may expire to zero -> the balance "cliff-drops"; ETA extrapolation must recognize such non-consumption mutations and reset the burn rate baseline.
- Notification permission request timing.
