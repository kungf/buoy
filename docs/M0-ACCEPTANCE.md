# M0 验收报告（2026-07-28）

## 结论：M0 完成 ✅

浮标球 + 总面板已在真机跑通（mock 数据），BuoyCore 16/16 单测通过，DeepSeek 适配器真联调成功。

## 交付物

| 模块 | 内容 |
|---|---|
| SPM 工程 | BuoyCore（Foundation-only）/ BuoyApp / buoyctl / BuoyCoreTests 四 target |
| BuoyCore | 统一 Quota 模型、燃烧率/ETA、HealthScore、HTTP 层 |
| 适配器 | DeepSeek（bearer，真联调通过）、火山（V4 签名 + GetAFPUsage 解析，代码就绪待 AK/SK） |
| 浮标球 | 外环=30d 剩余、核心液面=5h/1d/7d 可滚轮切换、呼吸+波形动画、健康度三色 |
| 手势 | 拖动+边缘吸附、点击开总面板、滚轮切核心窗口、hover 浮层摘要 |
| 总面板 | 手风琴两 provider、进度条+用量+reset 倒计时、球上 provider 切换 Picker |
| 打包 | `Scripts/make-app.sh` → build/Buoy.app（LSUIElement、com.wyang.buoy） |

## 验证记录

- `swift build` ✅ / `swift test` 16/16 ✅（含 V4 签名参考向量，Python hashlib/hmac 独立实现交叉验证）
- **DeepSeek 真联调**：`buoyctl deepseek` → 余额 ¥1.25（granted 0 / topped_up 1.25）✅
- **UI 真机验证**：合成 CGEvent 点击球 → 总面板打开；点击 volcano 头部 → 手风琴展开 4 窗口进度条 + reset 倒计时（截图确认）✅

## ⚠️ 火山需要你操作：拿 IAM AK/SK

GetAFPUsage 是**控制面 API**，只认 IAM AK/SK 签名；你 settings 里的 `ark-` 是推理 key（实测 Bearer→404、X-Api-Key→401，无法鉴权）。

1. 打开 console.volcengine.com → 访问控制 IAM → 密钥管理 → 新建 AccessKey
2. 跑：`BUOY_VOLC_AK=xxx BUOY_VOLC_SK=yyy .build/debug/buoyctl volcano`
3. 若返回 `PlanType + 4 窗口 Quota/Used/ResetTime`，适配器即真联调通过（解析逻辑已有文档示例单测覆盖）

## 已知留待 M1+

- mock 数据 → 轮询引擎 + Keychain 凭证存储
- 双击详情面板（M0 单击/双击均开总面板）
- 总面板 pin 成 NSPanel、点击穿透开关、逃逸徽标
- 燃烧率告警（BurnRateEstimator 已就绪，未接 UI）

## 当前状态

Buoy.app 仍在运行（右上角球，mock 数据）。退出：`pkill -x Buoy`。

## 补充（2026-07-28 晚）：凭证配置落地

- 凭证已写入 `~/.buoy/config.json`（chmod 600，**仓库外**，git 不可达）：DeepSeek token + 火山 ark- key/baseURL
- `buoyctl` 凭证优先级：env > ~/.buoy/config.json；DeepSeek 已从配置加载并联调通过
- `.gitignore` 已覆盖 config.json / .env* / secrets/；全仓库明文扫描确认无任何 token
- 火山 ark- key 复测 GetAFPUsage：Bearer→404、X-Api-Key→401（控制面只认 IAM AK/SK 签名，官方文档确认）
- **拿到 AK/SK 后**填入 `~/.buoy/config.json` 的 `providers.volcano.ak/sk` 即可，无需改代码

## 补充 2（2026-07-28 深夜）：火山真联调通过 ✅

用户提供 IAM AK/SK 后，定位到关键问题：**GetAFPUsage 的正确入口是通用开放网关 `open.volcengineapi.com`**，
而非文档表面暗示的 `ark.cn-beijing.volces.com`（推理端点，自有鉴权层不认 AK/SK，Bearer→404 / X-Api-Key→401 / V4 签名→401）。
用官方 volcengine Python SDK 交叉验证排除了签名实现问题后确认。

`buoyctl volcano` 实测输出（medium 套餐）：
- 5h：6339.7 / 10000（63.4%），reset 2026-07-29 03:46
- 1d：0 / 50000（0%）
- 7d：16284.2 / 35000（46.5%）
- 30d：51282.0 / 100000（51.3%）

VolcanoProvider endpoint 与 DESIGN.md §5.2 已同步修正；16/16 单测保持全绿。
至此 M1 基线的两个 provider（DeepSeek + 火山）全部真联调通过。
