# Buoy 🛟

> macOS 常驻桌面悬浮小球，一眼看尽多 provider 的 AI token / 额度消耗，烧得太快时预警。

把"打开 5 个 provider 官网查额度"压缩成"瞥一眼桌面小球"。Buoy = 浮标：浮在桌面上的球，液面随额度起伏，危险时闪红光--不是隐喻，是直译。

```
        ╭───╮
        │ ◯ │   外环 = 月度剩余    核心液面 = 当前窗口剩余
        ╰───╯   呼吸频率 ↔ 燃烧率（烧得越快呼吸越急）
```

---

## 为什么

- **Glanceable**：一眼知消耗，不用切走当前工作、不用开浏览器。
- **多 provider 统一视图**：火山（5h / 7d / 30d 三级滚动）、DeepSeek（纯余额）--同构呈现，单击开总面板纵览全部。
- **预测优于报数**：基于燃烧率给出 ETA（"5h 额度按当前速度还剩 12 分钟"），直击"5 小时额度 10 分钟烧完才发现"的痛点。
- **常驻低耗**：原生 SwiftUI + AppKit，常驻内存与 CPU 极小；不抢焦点。

## 现状

🚧 **Pre-release / 开发中**。M0 骨架 + M1 双适配器 + Phase 1 预测已就绪，可真机运行。

| 已完成 | 待完成 |
|---|---|
| 浮动球（外环 + 核心液面 + 呼吸/波形动画） | Keychain 凭证存储（当前 config.json） |
| 总面板手风琴 + ETA + sparkline | 预警通知（AlertEngine + UserNotifications） |
| DeepSeek + 火山 双 provider（真联调通过） | per-provider 轮询调度 + 持久化 |
| 燃烧率 / ETA 接通球面呼吸与面板 | 设置 UI、菜单栏、开机自启 |
| Volc Signature V4 签名 + 统一 Quota 模型 | MiMo / OpenAI / Anthropic、沙盒与签名 |

完整路线图见 [`docs/ROADMAP.md`](docs/ROADMAP.md)。

## 要求

- **macOS 14.0+**（Sonoma；用到 `PhaseAnimator` / `Canvas`）
- Xcode Command Line Tools（Swift 6.0 工具链）

## 快速开始

### 1. 构建

```sh
git clone https://github.com/kungf/buoy.git
cd buoy
swift build
```

### 2. 配置凭证

凭证存于仓库**外**的 `~/.buoy/config.json`（chmod 600，已 gitignore，永不入库）：

```json
{
  "providers": {
    "deepseek": { "token": "sk-你的-deepseek-api-key" },
    "volcano":  { "ak": "你的-火山-AccessKey", "sk": "你的-火山-SecretKey" }
  }
}
```

> **火山注意**：需要的是 IAM **AccessKey + SecretKey**（控制台 -> 访问控制 IAM -> 密钥管理），不是 ARK 推理 API Key（`ark-` 开头的 key 走控制面 OpenAPI 会 401）。

### 3. 联调验证（CLI）

```sh
.build/debug/buoyctl all      # deepseek + volcano 各拉一次，打印额度
```

凭证优先级：环境变量 > `~/.buoy/config.json`：
- `BUOY_DEEPSEEK_TOKEN`
- `BUOY_VOLC_AK` / `BUOY_VOLC_SK`

### 4. 打包运行

```sh
./Scripts/make-app.sh         # 产出 build/Buoy.app（LSUIElement 后台 agent）
open build/Buoy.app
```

球出现在主屏右上角。`BUOY_MOCK=critical|warning|exhausted|mixed|healthy open build/Buoy.app` 可用 mock 场景做视觉测试（不发网络请求）。退出：`pkill -x Buoy`。

## 交互

| 手势 | 动作 |
|---|---|
| hover | 浮层摘要（provider + 各窗口百分比） |
| 单击 | 打开总面板（所有 provider 一览） |
| 滚轮 | 核心液面在 5h ↔ 7d 间切（外环月度不变） |
| 拖动 | 移动球体，松手吸附屏幕边缘 |
| 右键 | 菜单（刷新 / 暂停 / 设置 / 隐藏） |

## 架构

Adapter-first：provider 差异全部收敛在适配层；上层 UI / 调度 / 预测只认统一 `Quota` 模型。

```
UI 层        FloatingBall (NSPanel) · Dashboard (手风琴) · [设置 WIP]
              │ 订阅 @Published
应用服务层    UsageStore (ObservableObject) · ForecastEngine (燃烧率/ETA)
              │ 调度                          │ 凭证
适配层        Provider 协议 · Volcano(V4) · DeepSeek(bearer) · [MiMo/OpenAI/Anthropic WIP]
              │
Core         Quota 模型 · VolcSigner · HTTPClient · CredentialStore
```

SPM 四 target：
- **BuoyCore**（Foundation-only，零 AppKit/SwiftUI）--模型 / 鉴权 / 预测 / 适配器 / 网络
- **BuoyApp**--浮球 + 总面板 UI
- **buoyctl**--适配器联调 CLI
- **BuoyCoreTests**--单测（27/27）

## 安全

- API key 仅存 `~/.buoy/config.json`（chmod 600，仓库外）；**永不落盘明文进仓库、永不进日志、永不上传第三方**（M2 将迁至 Keychain）。
- `Credential` 实现 redacting `CustomStringConvertible`，任何 `print()` 只露前 4 字符。
- 网络仅 HTTPS 直连（ATS + 证书校验）。

## 文档

- [`docs/DESIGN.md`](docs/DESIGN.md)--完整设计文档（理念 / 架构 / provider 规格 / UI / 里程碑）
- [`docs/ROADMAP.md`](docs/ROADMAP.md)--后续路线图与缺口清单
- [`docs/M0-ACCEPTANCE.md`](docs/M0-ACCEPTANCE.md)--M0 验收报告

## License

未定（pre-release）。
