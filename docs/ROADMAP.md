# Buoy 后续路线图（2026-07-28）

> 基于 DESIGN.md 的 M0–M3 路线与代码现状逐行核对得出。每条缺口都标注了**代码证据**与**DESIGN 锚点**。

## 现状盘点（已完成 vs 未完成）

### ✅ 已完成

| 里程碑 | 内容 | 证据 |
|---|---|---|
| M0 骨架 | SPM 四 target、浮动球（NSPanel + 外环 + 核心液面 + 呼吸/波形动画）、总面板手风琴、手势（拖动吸附/点击/滚轮/hover）、mock 场景、`make-app.sh` 打包 | `BallView.swift` / `DashboardView.swift` / `M0-ACCEPTANCE.md` |
| M1 双适配器 | DeepSeek（bearer/余额）真联调、火山（volcSignature/GetAFPUsage 5h·7d·30d）真联调、VolcSigner V4 + 参考向量单测 | `DeepSeekProvider.swift` / `VolcanoProvider.swift` / `VolcSignerTests.swift` |
| M1 轮询接真数据 | `UsageStore` 已从 `CredentialStore.load()` 拉真数据并发轮询（非仅 mock）；`buoyctl` 联调 harness | `UsageStore.swift:50-82` |
| M2 预测（代码就绪） | `BurnRateEstimator`（最小二乘 + reset 跨界/睡眠空洞丢弃）、`HealthScore`，含单测 | `BurnRateEstimator.swift` / `HealthScore.swift` |

构建：`swift build` ✅ / `swift test` 21/21 ✅。

### ⚠️ 已完成但偏离设计 / 留有尾巴

- 凭证存 `~/.buoy/config.json`（明文 JSON，chmod 600）--DESIGN §10 要求 **Keychain**，M0 doc 自标注 "M2 迁 Keychain"。
- `UsageStore` 用**单一 300s timer** 覆盖全部 provider--DESIGN §6 要求 per-provider 间隔 + 错峰 + 退避。
- `BurnRateEstimator` / `HealthScore` 已实现但**未接入 UI**（详见缺口 #1）。

---

## 缺口清单（按代码证据核对）

| # | 缺口 | 代码证据 | DESIGN 锚点 |
|---|---|---|---|
| 1 | **预测未接 UI**（死代码） | `UsageStore.displayHealth` 传 `etas: [:]` 永远空 -> balance 型健康度恒 nil；无采样点收集/环形 buffer；无 ETA 展示；球呼吸固定 `sin(time*.pi/1.6)` 未绑燃烧率；总面板无 sparkline/ETA | §7、§8.4 |
| 2 | **PollScheduler 缺失** | `UsageStore.pollTimer` 单一 300s；无 per-provider 间隔（5h:2min / 余额:5min / 月度:10-15min）、无错峰、无 429/5xx 指数退避、无 lastGoodReport+stale 降级 | §6 |
| 3 | **无持久化** | 重启即冷启动，丢全部历史样本与 lastGoodReport；DESIGN 要求本地 JSON 缓存 + 样本环形 buffer（短窗 ~120 点 / 长窗日级聚合） | §6 |
| 4 | **Keychain 未迁移** | `CredentialStore` 读写 `config.json`；无 `SecretStore`（`SecItemAdd/Copy`） | §10 |
| 5 | **预警通知缺失** | 无 `AlertEngine`、无 `UserNotifications`、无 cooldown 持久化（燃烧率突变 / ETA 临界 / 见底 三类） | §7 |
| 6a | **DeepSeek 上球渲染坏** | `ringQuota`/`coreQuota` 对 balance 型返回 nil -> 球显示 `--`；DESIGN 要求余额球（液面=ETA 健康度、中央 ¥余额、ETA 小字、货币角标） | §8.4 |
| 6b | **展示模式未实现** | 当前 `displayProviderId` 由 Picker 手动切；DESIGN 要求 固定/最紧(默认)/轮播 三模式 + 换脸过渡 | §8.1 |
| 6c | **逃逸徽标半成品** | 仅红点（`BallView.showAlertBadge`）；缺 provider 主题色 + 微脉冲 + 点击徽章切到该 provider | §8.1 |
| 6d | **双击/穿透/pin 未做** | `BallEventView.mouseUp` 单击双击均 `onClick()`；总面板是 `NSWindow` 非 pinable `NSPanel`；无穿透模式开关 | §8.2、§8.5 |
| 6e | **状态动画粒度不足** | `Theme.healthColor` 仅 green/orange/red；缺 fast-burn(黄+热气粒子) / near-depleted(橙抖动) / depleted(红慢闪) / error(灰脉冲虚线) | §8.4 |
| 6f | **sparkline 未做** | 总面板展开态无燃烧率曲线 | §8.2 |
| 7 | **Manifest/Registry 不完整** | `ProviderManifest` 缺 `icon`/`consoleSession`；`Credential` 缺 `consoleSession` case；providers 硬编码在 `UsageStore.init`，无 `ProviderRegistry` | §4 |
| 8 | **consoleSession 模式未做** | 无 `ConsoleSessionController`（WKWebView + XHR hook）--MiMo 兜底需要 | §4 |
| 9 | **配置 UI 缺失** | 无 `SettingsView`/`ProviderForm`（当前靠手编 config.json） | §9 |
| 10 | **菜单栏缺失** | 无 menu bar item | §9 |
| 11 | **开机自启缺失** | - | §9 |
| 12 | **沙盒/签名** | `make-app.sh` 无 App Sandbox / ATS / entitlements / 代码签名 | §10 |
| 13 | **测试覆盖** | 21 个全 BuoyCore 单测；无 UI 测试、无 adapter 集成（recorded fixture）。真联调靠 `buoyctl` 手动 | §11 |
| 14 | **未纳入 git** | `.gitignore` 已就绪但 `git init` 未执行 | - |

**开放问题（DESIGN §13 仍悬而未决）**：MiMo 窗口类型（自然月 vs 30 天滚动）、OpenAI/Anthropic 用量 API 粒度、通知权限申请时机、火山 GetAFPUsage 限流配额（720 次/天）、DeepSeek `granted_balance` 到期跳崖的燃烧率基线重置。

---

## 后续计划（按优先级分阶段）

优先级排序的依据是 Buoy 的核心价值主张--**"预测优于报数"** 与 **"5h 额度 10 分钟烧完才发现"** 的痛点。已就绪但未接线的预测能力（缺口 #1）是最高 ROI：代码大半写好了，只差接线。

### Phase 1 - 接通预测（M2 核心，最高优先级）✅ 完成（2026-07-28）

把 `BurnRateEstimator` 从死代码变成球面上的呼吸节奏与 ETA。这是 Buoy 区别于竞品的命门。

- [x] **1.1 采样收集**：新增 `ForecastEngine`（BuoyCore），每次成功拉取对每个 quota 追加 `UsageSample`，内存环形 buffer（cap 120）。
- [x] **1.2 ETA 计算**：`UsageStore` 经 `ForecastEngine.eta(for:)` 算 ETA 并喂给 `HealthScore`（修复 balance 型恒 nil）；冷启动返回 nil -> UI `--`。
- [x] **1.3 球呼吸绑燃烧率**：`BallView` 新增 `breathUrgency`（由 core ETA 映射），呼吸周期 2.4s→0.7s、幅度随紧迫度上升。
- [x] **1.4 总面板 ETA + sparkline**：新增 `Sparkline`（Canvas）；`QuotaRow` 展示 ETA 文本 + 采样走势线。
- [x] **1.5 单测**：新增 `ForecastEngineTests`（6 例：windowed ETA / 冷启动 / 环形 buffer / balance ETA / 充值断段 / rateLimit 不追踪）。`swift test` 27/27 ✅。

**关键设计**：balance 型用 `-remaining` 作采样代理量，复用 `BurnRateEstimator` 已有 reset 启发式，顺带实现了 DESIGN §13 的"充值跳崖基线重置"（Phase 2.4 提前达成），未改动 estimator 一行。

### Phase 2 - 调度与持久化（预测的基础设施）✅ 基本完成（2026-07-28）

预测要跨重启有意义，必须有样本持久化与 per-provider 调度。

- [x] **2.1 PollScheduler**：per-provider `Task` 轮询 + 错峰（5s 起步偏移）+ `BackoffPolicy` 指数退避（2^n，上限 5x，5 次进 error 态）；回前台 `didBecomeActiveNotification` 立即刷新。
- [x] **2.2 降级**：拉取失败保留旧 report（lastGoodReport）+ 球面 stale 变暗（`displayIsStale`）；连续失败次数驱动退避。⚠️ "N 次切 error 态"的独立球面视觉（虚线脉冲）留待 Phase 5 状态动画。
- [x] **2.3 持久化**：`CacheStore` 存 `~/.buoy/cache.json`（`BuoyCache = reports + ForecastEngine`）；启动加载，每次成功拉取后保存。重启不冷启动。
- [x] **2.4 DeepSeek 跳崖识别**：Phase 1 已用 `-remaining` 代理量 + reset 启发式实现（充值回升 -> 断段重置基线）。

新增 `BackoffPolicy` / `CacheStore` / `BuoyCache`（BuoyCore Store/），`ForecastEngine`/`BurnRateEstimator`/`UsageSample` 加 `Codable`。`swift test` 33/33 ✅。

### Phase 3 - Keychain 迁移（安全，M2 并行）

- [ ] **3.1 SecretStore**：`SecItemAdd/Update/Copy` 薄封装，`kSecClassGenericPassword`，`account = providerId`。
- [ ] **3.2 迁移**：首次启动读 `config.json` -> 写 Keychain -> 删除明文文件；`buoyctl` 凭证来源改为 Keychain。
- [ ] **3.3 首次授权**：Keychain 访问走系统授权提示；token 永不进日志/不上传。

### Phase 4 - 预警通知（M2）

- [ ] **4.1 AlertEngine**：三类预警--燃烧率突变（> 历史 P95 的 N 倍）、ETA 临界（5h < 15min 且仍烧）、见底（> 90%）。
- [ ] **4.2 UserNotifications**：申请权限（时机见开放问题）；cooldown 持久化避免重启轰炸。
- [ ] **4.3 接球面**：fast-burn / near-depleted / depleted 触发对应状态动画（缺口 #6e）。

### Phase 5 - UI 补齐（DESIGN §8 收尾）

- [ ] **5.1 余额球**（#6a）：DeepSeek 上球--液面 = ETA 健康度、中央 ¥余额、下方 ETA 小字、货币角标。
- [ ] **5.2 展示模式**（#6b）：固定 / 最紧（默认，按 health score 自动选）/ 轮播；换脸带 `matchedGeometryEffect` 过渡。
- [ ] **5.3 逃逸徽标**（#6c）：provider 主题色 + 微脉冲 + 点击切到该 provider。
- [ ] **5.4 双击/穿透/pin**（#6d）：双击开 provider 详情面板；总面板 pin 成 `NSPanel`；右键菜单加穿透模式开关。
- [ ] **5.5 状态动画**（#6e）：fast-burn 黄+热气粒子（Canvas 粒子）、near-depleted 橙抖动、depleted 红慢闪、error 灰脉冲虚线。

### Phase 6 - 配置 UI + 菜单栏 + 自启（M3 基础设施）

- [ ] **6.1 SettingsView / ProviderForm**（#9）：左 provider 列表 + 右表单；bearer 填 baseURL+token、volcSignature 填 baseURL+AK+SK，token 直写 Keychain。
- [ ] **6.2 menu bar item**（#10）：打开总面板、快速开关 provider、查看 ETA。
- [ ] **6.3 开机自启**（#11）：`SMAppService`（macOS 14+）。
- [ ] **6.4 外观设置**：球大小、透明度、主题色、内核默认窗口、展示模式、穿透开关。

### Phase 7 - 多 provider（M3）

- [ ] **7.1 ProviderRegistry**（#7）：manifest 补 `icon`/`consoleSession`；`Credential` 加 `consoleSession` case；编译期注册，设置窗枚举。
- [ ] **7.2 OpenAI / Anthropic**：bearer，用量/计费 API（先核实粒度，开放问题）。
- [ ] **7.3 MiMo**：视 API 情况走 bearer 或 consoleSession（#8 `ConsoleSessionController`：WKWebView + XHR hook + `extractors`）。
- [ ] **7.4 adapter 集成测试**（#13）：recorded fixture，离线回放，替代手动 `buoyctl` 联调。

### Phase 8 - 打包与发布就绪

- [ ] **8.1 App Sandbox + entitlements**（#12）：网络权限 + Keychain 访问组；ATS 锁官方域名。
- [ ] **8.2 代码签名 + notarization**：Developer ID，`make-app.sh` 集成。
- [ ] **8.3 `git init` + 首次提交**（#14）：`.gitignore` 已就绪。
- [ ] **8.4 icon / 域名 / App Store 撞名复查**（DESIGN §0.3）。

---

## 建议的执行顺序

```
Phase 1 (接通预测)        ← 最高 ROI，代码大半就绪，2-3 天
  └─ Phase 2 (调度+持久化) ← 预测跨重启的前提，2-3 天
       └─ Phase 4 (预警通知) ← 依赖 1+2，1-2 天
Phase 3 (Keychain)        ← 可与 1/2 并行，1 天
Phase 5 (UI 补齐)         ← 依赖 1 的 ETA，2-3 天
Phase 6 (配置 UI/菜单栏)  ← 依赖 3 的 Keychain，2-3 天
Phase 7 (多 provider)     ← 依赖 6 的 Settings + 7.1 Registry，3-5 天
Phase 8 (打包发布)        ← 收尾，1-2 天
```

**MVP 收敛点**：Phase 1+2+3+4 完成即达成 DESIGN 的 M2 全量（预测 + 预警 + 安全 + 持久化），此时 Buoy 已对用户产生核心价值--可考虑先发一个内部测试版，再用 Phase 5-8 打磨上线。
