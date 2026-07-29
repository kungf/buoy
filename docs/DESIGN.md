# Buoy（浮标）- 设计文档

> macOS 常驻桌面悬浮小球，一眼呈现多 provider 的 API token / 额度消耗，并在额度被快速烧掉时预警。
> 技术栈：SwiftUI + AppKit（原生）。Buoy = 浮标：浮在桌面上的球，液面随额度起伏，危险时闪红光——不是隐喻，是直译。

---

## 0. 概述

### 0.1 一句话定位
把"打开 5 个 provider 官网查额度"压缩成"瞥一眼桌面小球"。

### 0.2 核心价值
- **Glanceable**：一眼知消耗，无需打开浏览器、无需切走当前工作。
- **多 provider 统一视图**：火山（5h / 周 / 月 三级滚动）、DeepSeek（纯余额）、MiMo（月度）、OpenAI / Anthropic（各有计费周期与额度）--同构呈现：球面单 provider 聚焦（同一时刻只展示一个），单击开总面板纵览全部（见 §8.1）。
- **预测优于报数**：基于燃烧率给出 ETA（"5h 额度按当前速度还剩 12 分钟"），直击"5 小时额度 10 分钟烧完才发现"的痛点。
- **常驻低耗**：原生 SwiftUI，常驻内存与 CPU 占用极小；不抢焦点；点击穿透为可切换模式（穿透 / 交互，见 §8.5）。

### 0.3 竞品坐标（2026-07 调研）

AI 额度监控赛道已拥挤，但形态趋同——**全是菜单栏 / CLI / 系统托盘，无人做悬浮球**：

| 项目 | 形态 | 覆盖 | 备注 |
|---|---|---|---|
| Claude-Code-Usage-Monitor（8.5k⭐） | Python CLI | 仅 Claude | 已有燃烧率预测，"预测"非独有卖点 |
| ClaudeBar（1.4k⭐） | Swift 菜单栏 | Claude/Codex/Gemini | 多助手 |
| TokenEater（442⭐） | 原生 macOS overlay | 仅 Claude | 形态最接近 Buoy |
| ClaudeMeter（125⭐） | Swift 菜单栏 | Claude 5h 会话 + 7d 周额度 | 窗口概念与火山 AFP 同构 |

**Buoy 差异化**：① 悬浮球形态独占（液面 + 呼吸节奏）；② 中国 provider 真空（火山 ARK / DeepSeek / MiMo 无人覆盖）；③ 统一 Quota 模型 + adapter-first（现有工具均为单 provider 硬编码解析）。
**撞名检查**：App Store 无精确同名；GitHub 有 Buoy-gg（React Native 调试工具，Electron），受众不重叠，发布时靠 icon / 域名区分。

### 0.4 非目标（MVP 阶段）
- 不做请求级实时监控（不拦截 / 代理 API 调用），仅靠 provider 官方用量 / 计费 API 周期性拉取。
- 不做跨平台（仅 macOS；决策于 2026-07：Windows 托盘赛道已有竞品，Buoy 的空位是 macOS 原生 + 中国 provider。逃生通道：`Core/` 层只依赖 Foundation、零 AppKit/SwiftUI import，将来若做 Windows——首选 Tauri——只需重写 UI 与平台能力层，Core 逻辑照本设计移植）。
- 不做团队 / 多账号管理（单机单用户）。
- 不做 provider 网关或聚合服务（纯本地客户端直连）。

---

## 1. 核心理念与设计原则

1. **Adapter-first**：provider 差异全部收敛在适配层；上层 UI / 调度 / 预测只认统一模型，不感知 provider 细节。
2. **统一额度模型（核心抽象）**：用一组正交的 `QuotaType`（时间窗 / 余额 / 速率限制）描述所有计费形态；一个 provider 一次返回 0~N 个 `Quota`。
3. **预测 > 报数**：不只显示"已用 X / Y"，更算出燃烧率与 ETA，把"快"做成可感知的节奏。
4. **优雅降级**：拉取失败时显示上次成功值 + stale 标记，不让小球"瞎跳"。
5. **常驻克制**：低频轮询、错峰调度、本地缓存、不抢焦点。
6. **密钥零落盘**：API key 仅存 Keychain，永不明文写盘、永不进日志、永不上传第三方。

---

## 2. 系统架构

### 2.1 分层与数据流

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

### 2.2 进程模型
单进程。一个常驻 `NSPanel`（浮动球）+ 一个 menu bar item + 一个用于设置的 `Window`。
后台拉取用 `async/await` + `URLSession`，由 `PollScheduler` 驱动；MVP 不引入后台 daemon。

---

## 3. 统一额度模型（核心抽象）

把所有计费形态归一为一组 `Quota`。一个 provider 一次返回 0~N 个 quota，上层完全不需要知道"这是火山还是 DeepSeek"。

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

### 3.4 各 provider -> Quota 映射（对应你的描述）

| Provider | 返回的 Quota | 类型 | 备注 |
|---|---|---|---|
| 火山 Volcano | 4 个 timeWindowed（5h / 1d / 7d / 30d，via GetAFPUsage） | AK/SK 签名 | 轮播 5h/7d/30d |
| DeepSeek | 1 个 balance | 账户余额 | 有钱就能用 |
| MiMo | 1 个 timeWindowed（月度） | 自然月 or 30 天滚动（待核实） | 单环 |
| OpenAI | timeWindowed（计费周期）+ balance（grant） | 花费 + 额度 | 可选 rateLimit |
| Anthropic | timeWindowed（计费周期）+ per-day usage | 花费 + 用量 | - |

> "各家 reset 方式不一样"在模型层被彻底消化：上层只见一组 `Quota`，UI / 预测逻辑完全复用。

---

## 4. Provider 适配器接口

```swift
/// 鉴权模式：三种（provider 选其一）
enum AuthMode {
    case bearer            // { baseURL, apiToken }：Bearer 直连（DeepSeek / OpenAI / Anthropic）
    case volcSignature     // { baseURL, accessKey, secretKey }：Volc Signature V4 HMAC（火山）
    case consoleSession    // 控制台浏览器登录态：经内嵌 WKWebView（无 API 的 provider 兜底）
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

**ConsoleSessionController**（console 模式核心组件，Core/Auth）：
- 每个 console provider 持一个隐藏 `WKWebView`，加载 `loginURL`。
- 注入 `WKUserScript` hook 页面自身的 `fetch` / `XHR`，按 `quotaEndpointPattern` 拦截额度接口响应，经 `WKScriptMessageHandler` 把 JSON 回传 Swift，用 `extractors` 解析成 `Quota`。
- 刷新 = 让页面 reload；session 过期（接口 401 / 跳登录页）-> 置 stale 并提示重新登录。
- 用户在 App 内登录一次，2FA / 短信 / 验证码由 WebView 真浏览器上下文自动处理；**App 不接触密码**。

**ProviderRegistry**：编译期注册（或 plist + 反射）；设置窗"添加 provider"时枚举。新增 provider = 新增一个符合 `Provider` 的类型 + 注册一行。

**错误模型**：

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

> volcSignature 模式下 401 需区分"凭证错误"与"本地时钟漂移"（X-Date 超窗导致签名失效）：两者提示文案不同，时钟漂移应引导用户校准系统时间。

---

## 5. 各 Provider 适配器规格

> 基线：**DeepSeek（bearer / 余额）+ 火山（volcSignature / 5h·7d·30d）**，两者接口均已确认。MiMo / OpenAI / Anthropic 后续阶段补。

### 5.1 DeepSeek ✅ 确定（apiKey 模式）

| 项 | 值 |
|---|---|
| AuthMode | `bearer` |
| BaseURL | `https://api.deepseek.com`（可改自建 / 代理） |
| Endpoint | `GET /user/balance` |
| Auth | `Authorization: Bearer <api_key>` |
| Quota 映射 | 1 个 `balance`：id=`deepseek.balance`，remaining=`total_balance`，unit=`.cny` |

响应：
```json
{
  "is_available": true,
  "balance_infos": [
    { "currency": "CNY", "total_balance": "10.00", "granted_balance": "10.00", "topped_up_balance": "0.00" }
  ]
}
```
- `granted_balance` = 赠送额度，`topped_up_balance` = 充值额度，`total_balance` = 合计；详情面板可拆分。
- 无时间窗 -> balance 型；ETA = total_balance / 燃烧率（¥/天）。

### 5.2 火山 Volcano ✅ 确定（volcSignature 模式，AK/SK）

官方有管控面 OpenAPI，**不需要 console 登录 / 抓包**。`GetAFPUsage` 一次返回 5h / 日 / 周 / 月 四个窗口的额度。

| 项 | 值 |
|---|---|
| AuthMode | `volcSignature`（AccessKey + SecretKey + HMAC-SHA256，Volc Signature V4） |
| Host | `https://open.volcengineapi.com`（通用开放网关；⚠️ 不是 `ark.cn-beijing.volces.com`——那是推理端点，其鉴权层不认 IAM AK/SK，实测 401） |
| Endpoint | `POST /?Action=GetAFPUsage&Version=2024-01-01` |
| 请求 body | `{}`（空） |
| 请求头 | `Content-Type: application/json`、`X-Date`、`X-Content-Sha256`、`Authorization: HMAC-SHA256 Credential=AK/.../cn-beijing/ark/request, SignedHeaders=host;x-content-sha256;x-date, Signature=...` |
| 凭证 | 用户的火山 **AccessKey + SecretKey**（IAM 凭证，非 ARK API Key） |

响应（节选）：
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
- 每个窗口对象：`Quota`(总配额=limit)、`Used`(已用)、`SubscribeTime`(窗口起，epoch ms)、`ResetTime`(下次重置，epoch ms)。AFP = 套餐额度单位（点数）。
- **Quota 映射**：4 个 `timeWindowed`：
  - `volcano.5h` ← `AFPFiveHour`
  - `volcano.1d` ← `AFPDaily`（bonus，默认隐藏）
  - `volcano.7d` ← `AFPWeekly`
  - `volcano.30d` ← `AFPMonthly`
  - `used=Used`、`limit=Quota`、`windowStart=SubscribeTime`、`resetsAt=ResetTime`、`unit=.credits`
- **Quota=0 语义**：某窗口返回 `Quota: 0`（如示例中的 Weekly/Monthly）表示该套餐**未开通此窗口** -> 不生成对应 Quota（而非生成 limit=0 的 quota），避免除零与误导性的"0%"。
- 球面轮播主显 `5h / 7d / 30d`；日窗口进详情面板。
- **燃烧率 / ETA**：每 ~2 min 轮询快照，用相邻 `Used` 差值算燃烧率，`remaining = Quota − Used`，`ETA = remaining / 燃烧率` -> 完美支撑"5h 额度 10 分钟烧完"预警。

### 5.3 后续 provider（M3）
MiMo / OpenAI / Anthropic 暂留；OpenAI / Anthropic 大概率 bearer（用量 / 计费 API），MiMo 视情况 consoleSession。

---

## 6. 数据获取与轮询策略

- **轮询间隔**：per-provider 可配，默认按"窗口越短、频率越高"：
  - 火山 5h 窗：默认 2 分钟（窗口短、变化快）
  - DeepSeek 余额：5 分钟
  - 月度类（MiMo / OpenAI / Anthropic）：10~15 分钟
- **调度**：`PollScheduler` 为每个 provider 持有一个 timer，**错峰**（避免齐刷刷打满网络）；App 回到前台立即刷新一次。
- **退避**：429 / 5xx 指数退避（上限 5 次），失败不丢 UI。
- **降级**：拉取失败 -> 显示 `lastGoodReport`（本地缓存）+ 球面 stale 脉冲；连续失败 N 次切 error 态。
- **缓存**：本地 JSON 存最近一次成功 report + 燃烧率样本环形 buffer。buffer 按窗口长度适配：短窗（5h / 1d）保留最近 ~120 个原始采样点；长窗（7d / 30d / 月度）额外维护日级聚合点，避免"月度 ETA 实际只反映最近一天"。

---

## 7. 燃烧率与预警（直击痛点）

- **燃烧率**：基于最近 K 个采样点拟合斜率 -> `tokens/min`、`$/hour`。参与拟合的相邻样本对必须满足两个条件：① **未跨过 `resetsAt`**（窗口 reset 后 Used 跳回 0，跨 reset 的样本对产生负 delta，必须丢弃）；② **相邻 `fetchedAt` 间隔 < 3× 轮询周期**（系统睡眠 / 唤醒产生的大空洞样本对丢弃，避免"睡醒一觉"被误判为暴烧）。
- **ETA**：`remaining / burnRate` -> "按当前速度，5h 额度还剩 12 分钟"。
- **冷启动**：样本不足 K 个时 ETA 显示 `--`（"数据收集中"），且不触发燃烧率类预警（尚无历史 P95 基线）。
- **Health score（跨 quota 统一紧急度）**：windowed = `remaining / limit`；balance = ETA 健康度归一（>7 天 = 1.0，<1 天 ≈ 0）。provider 紧急度取其所有 quota 的最小值；error / stale 状态不参与排序。用于"最紧"展示模式（§8.1）与预警排序。
- **预警触发**（macOS `UserNotifications`）：
  1. **燃烧率突变**：当前速率 > 历史 P95 的 N 倍 -> "你正在快速烧 5h 额度"。
  2. **ETA 临界**：5h 窗 ETA < 15min 且仍在烧 -> "5h 额度即将耗尽"。
  3. **见底**：percent > 90% -> 轻提示。
- **节流**：同一预警在 cooldown 内不重复推送；cooldown 状态持久化，避免重启 App 后重复轰炸。

---

## 8. 悬浮小球 UI / 动画

### 8.1 多 provider 展示模型：多选小球簇 + 总面板

**球面展示哪些 provider 由用户在总面板多选决定**——选中几个就在悬浮球上横向排列几个独立小球（小球簇）；每个球各自承载一个 provider 的环+核+数字，信息不丢。全部启用 provider 的轮询与预警仍在后台照常运行。

- **多选上球**：总面板每个 provider 卡片有“眼睛”开关，勾选即上球、取消即移除；选中数量 = 球面小球数量。选中集合持久化到 UserDefaults，重启保留。
- **默认选择**：首次打开（未配置）默认仅选中第一个 provider（按 provider 初始化顺序，当前 = 火山）；用户调整后按其配置显示。
- **突破徽章（alert badge）**：任一**未选中** provider 进入 fast-burn / near-depleted / depleted / error 时，簇右上角出现该 provider 主题色小圆点 + 微脉冲；点击徽章把该 provider 加入簇（冒出新球）。这是“默认只选第一个”下漏警的最后一道保险（系统通知不受影响，照常推送）。
- **总面板**：单击球（或菜单栏图标）打开。每个启用 provider 一张卡片：环+核缩略图、各窗口百分比 + ETA、sparkline、上球开关；点卡片进入该 provider 详情页。布局与交互详见 §8.2。

### 8.2 总面板布局：手风琴列表

**窗口形态**：默认是附着在球上的瞬态 `NSPopover`（点外自动关闭，扫一眼就走）；右上角 pin 按钮可撕下成独立浮窗（`NSPanel`）常驻盯盘。宽度 ~340pt，高度随内容自适应（上限 ~70% 屏高，超出滚动）。

```
┌─ Buoy ──────────────────── ⟳ ⚙ ┐
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

**三段结构**：

1. **Header**（常驻）：App 名、全部刷新 ⟳、设置 ⚙、pin 📌；副标题行显示"更新于 HH:MM:SS"（数据 stale 时变黄）。
2. **预警条**（条件出现，可多条堆叠）：仅当有活跃 fast-burn / ETA 临界 / 见底预警时显示，底色随最严重级别（黄 / 橙 / 红）；点击定位到对应 provider 卡并自动展开。无预警时完全收起、不占空间。
3. **Provider 手风琴列表**：
   - **排序**：按 health score（§7）升序，最紧急在最上；error / stale 不参与排序，沉底置灰。
   - **收起态（一行，~36pt）**：icon + 名称 ｜ 最紧急 quota 标签 + 百分比（balance 型显示金额）｜ ETA ｜ 状态点（绿 / 黄 / 红 / 灰）｜ ▸。
   - **展开态**：左侧环+核缩略图（与球同一视觉语言），右侧每个窗口一行：进度条 + percent + used/limit + ETA + reset 倒计时（`R 3h2m`）；下方一条 sparkline（最近 N 点 Used 走势，标注燃烧率 spike）；balance 型（DeepSeek）改为余额大字 + 赠送 / 充值拆分 + ETA；底部操作行：刷新 / 暂停轮询 / 设置。
   - 手风琴**不互斥**：可同时展开多张卡；展开状态当次会话内记忆。
   - **单击**行头展开 / 收起；**双击**行头 = 该 provider 详情面板（与球的双击手势一致）。

### 8.3 形态：环 + 核（一眼月度 + 翻阅 5h）
每个选中 provider 一个圆球（直径 ~64pt，可调），横向排成小球簇（§8.1）；单球分两层承载两个时间尺度：

- **外环（Ring）= 月度 30d，常驻**
  - 进度环 = 30d 已用 %，颜色随 % 绿->黄->红；慢变量、ambient。
  - 一眼知"本月大势宽裕 / 紧张"；可在环上标"今日"刻度（当月已过天数 vs 已用 %）看是否超前。
- **内核（Core / 液面）= 活跃窗口，默认 5h**
  - 液面 = 活跃窗口 remaining %，颜色随 %。
  - 呼吸 / 脉冲频率 ↔ 该窗口燃烧率（烧得越快呼吸越急）。
  - 滚轮：内核在 `5h ↔ 7d` 间切（外环不变）。
- **默认只显颜色**（环色 + 核色 + 核呼吸），不挤文字；hover 才显数字（`30d 62%` / `5h 73%`）。
- **余额型（DeepSeek）**：无多窗口，环退化为单层余额球（液面 = ETA 健康度，中央显 ¥余额）。
- 互不干扰：5h 烧空但月度 OK -> 环绿、核红慢闪（"等 5h reset"）；月度将尽但 5h 新窗 -> 环红、核绿（"本月快到顶"）。

### 8.4 视觉编码（颜色 + 节奏）

**统一原则**：液面永远 = "健康度"（剩余时间 / 剩余额度的健康代理），windowed 与 balance 切换时视觉语言一致：
- **timeWindowed**：液面 = remaining%，颜色随已用 percent↑ 绿->红
- **balance（DeepSeek）**：无 limit、无 reset，液面 = "还能撑多久"的 ETA 健康度（按当前燃烧率归一化：>7 天满、<1 天见底）；球中央显示余额数字 `¥42.50`，下方小字 ETA `≈ 3.2 天`，右上角货币角标与百分比型区分
- **环与核各自着色**：外环颜色 = 月度 30d %；内核颜色 = 活跃窗口 %。两者独立 -> "环绿核红"等组合直接表达多尺度状态（如 5h 烧空但月度 OK）。

| 状态 | 触发 | 视觉 |
|---|---|---|
| idle | 近 K 分钟无消耗 | 绿，缓慢呼吸 |
| consuming | 正常速率消耗 | 绿->青，液面缓变 |
| fast-burn | 燃烧率突增 | 黄，呼吸加快，球边"热气"粒子 |
| near-depleted | windowed percent>85% / balance ETA<1天 | 橙，轻微抖动 |
| depleted | 窗口耗尽 / 余额近 0 | 红，慢闪 |
| error | 拉取失败 / stale | 灰，脉冲虚线 |

- **呼吸频率 ↔ 燃烧率**：烧得越快呼吸越急--把"快"做成可感知的节奏，而不只是数字。
- 液面用 `TimelineView` + `Canvas` 绘制波浪 + 微噪声。

### 8.5 交互（翻阅 5h）
手势消歧后的唯一映射（每个手势只有一个含义）。簇内多球时，以下手势均作用到鼠标所在的那颗球对应的 provider：

- **hover**：小 popover（provider 名 + 5h/7d/30d 三百分比 + 各自 ETA）。
- **单击**：打开总面板（所有启用 provider 一览，见 §8.1）。
- **双击**：展开当前 provider 详情面板：
  - 每个窗口一行：百分比 + 已用 / 上限 + reset 倒计时。
  - 每行一条 **sparkline 燃烧率曲线**（最近 N 个采样点 Used 走势）--这就是"翻阅 5h 使用情况"的历史，能看出"刚才那拨是不是烧得特别快"。
- **滚轮**：内核在 `5h ↔ 7d` 间切（外环月度不变）。
- **拖动**：移动球体；靠近屏幕边缘自动吸附并半隐为贴边小条，hover 时展开。
- **right-click**：菜单（刷新 / 暂停轮询 / 穿透模式开关 / 打开总面板 / 打开该 provider 详情 / 从球上移除（或加入）该 provider / 隐藏球）。
- **穿透模式**：设置 / 右键菜单可切换。开启时球体鼠标穿透、不响应任何交互，仅作 ambient 显示；默认关闭（交互模式）。

### 8.6 动画原语
- `TimelineView(.animation)` 驱动呼吸 / 液面。
- `matchedGeometryEffect` 在球 ↔ 详情面板间过渡。
- `PhaseAnimator`（macOS 14+）做状态切换。
- 粒子（热气 / 冒汗）用 `Canvas` + 简易粒子系统。

---

## 9. 配置 UI

- 左侧 provider 列表（+ 添加），右侧表单。
- **bearer 模式**（DeepSeek/OpenAI/Anthropic）：填 Base URL + API Token，token 直接写 Keychain，不进 `TextField` 之外的 state。
- **volcSignature 模式**（火山）：填 Base URL + AccessKey + SecretKey，AK/SK 直接写 Keychain。
- **consoleSession 模式**（无 API 的 provider 兜底）：只预填控制台地址，配一个"登录"按钮 -> 唤起内嵌 WKWebView 完成登录；显示 session 状态。
- 窗口定义 / 解析逻辑内置，不向用户索要额度上限等。
- 外观：球大小、透明度、主题色、是否开机自启、内核默认窗口（5h / 7d）、上球 provider 多选（见 §8.1）、穿透模式开关。
- menu bar：打开总面板、快速开关 provider、查看 ETA。

---

## 10. 安全 / Keychain

- `SecretStore`：`SecItemAdd / Update / Copy` 的薄封装，`kSecClassGenericPassword`，`account = providerId`。
- **API key**：永不落盘明文、永不进日志、永不上传第三方；仅存 Keychain。
- **console session**：session cookie 视同密钥，仅存 WKWebView cookie store（或 Keychain 序列化），不落盘明文、不进日志；**不读取 / 不记录登录密码**（密码只在 WebView 安全上下文）；每个控制台独立 WebView + 独立 cookie，互不串扰；console 模式默认关闭，用户显式开启。
- 网络仅经 HTTPS 直连（ATS + 证书校验），默认只指向 provider 官方域名；用户自定义 baseURL（自建 / 代理）时显式提示并确认其安全性。启用 App Sandbox（注：macOS 沙盒网络权限为布尔开关，无域名级白名单，约束靠 ATS + 代码层域名校验实现）。
- 首次访问 Keychain 走系统授权提示。

---

## 11. 项目结构

> Bundle ID：`com.wyang.buoy`　｜　App 显示名：**Buoy**　｜　副标题：*AI token & quota monitor*

```
Buoy/
├── App/                  BuoyApp, AppDelegate, MenuBar
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

## 12. 里程碑 / MVP 路线

- **M0 骨架**：空 app + 浮动球 + 总面板 + 假数据驱动 UI / 动画（验证视觉与交互手势）。
- **M1 双适配器**：DeepSeek（bearer / 余额）+ 火山（volcSignature / GetAFPUsage，5h·7d·30d）跑通真数据。两者接口均已确认。
- **M2 预测**：燃烧率 + ETA + 预警通知。
- **M3 多 provider + 打磨**：MiMo / OpenAI / Anthropic、设置 UI、菜单栏、开机自启。

---

## 13. 开放问题 / 风险

- ✅ **火山 5h / 周 / 月额度**：已确认有官方 OpenAPI `GetAFPUsage`（AK/SK + Volc Signature V4），一次返回 5h/日/周/月四窗口的 `Quota / Used / SubscribeTime / ResetTime`。走 `volcSignature` 模式，**无需 console 登录**。需用户填火山 AccessKey + SecretKey（IAM 凭证，非 ARK API Key）。
  - 待验证项：用户实际套餐是否返回全部四个窗口（示例文档展示了 FiveHour / Daily，Weekly / Monthly 同结构）；AFP 是额度点数单位（非原始 token）。
- ConsoleSession 降级为"无 API provider"的兜底（如 MiMo 若纯控制台）；火山不再需要它。
- DeepSeek 走 bearer（余额 API 直接给 remaining）。
- MiMo 月度窗口是自然月还是 30 天滚动，待核实。
- OpenAI / Anthropic 用量 API 粒度是否足够细（若仅 per-day，对"5h 窗"无效，需 provider 自带窗口）。
- ~~macOS 最低版本~~ 已定：**macOS 14+**（`PhaseAnimator` 直接用；2026 年该基数合理）。
- 火山管控面 OpenAPI 自身限流：GetAFPUsage 按 2min 轮询 ≈ 720 次/天，需确认在调用配额内。
- DeepSeek `granted_balance`（赠送额度）可能到期归零 -> 余额"跳崖"；ETA 外推需识别此类非消耗性突变并重置燃烧率基线。
- 通知权限申请时机。
