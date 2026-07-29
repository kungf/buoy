# Buoy 🛟

> A always-on macOS desktop floating ball that shows your AI token / quota spend across providers at a glance, and warns you when it's burning down too fast.

Turns "open 5 provider dashboards to check quota" into "glance at a ball on your desktop." Buoy = buoy: a ball floating on your desktop whose liquid level rises and falls with your quota, flashing red when danger is near -- not a metaphor, a literal translation.

```
        ╭───╮
        │ ◯ │   outer ring = monthly remaining    core liquid = current window remaining
        ╰───╯   breathing rate ↔ burn rate (the faster you burn, the faster it breathes)
```

---

## Why

- **Glanceable**: see consumption at a glance, without switching away from your work or opening a browser.
- **Unified multi-provider view**: Volcano (5h / 7d / 30d rolling windows), DeepSeek (pure balance) -- rendered homogeneously; click for a full dashboard across all providers.
- **Prediction over reporting**: computes ETA from burn rate ("at the current pace, your 5h quota has 12 minutes left"), attacking the pain of "my 5-hour quota burned out in 10 minutes before I noticed."
- **Low-overhead resident**: native SwiftUI + AppKit, tiny resident memory and CPU; never steals focus.

## Status

🚧 **Pre-release / work in progress.** M0 skeleton + M1 dual adapters + Phase 1 prediction are done and runnable on real hardware.

| Done | TODO |
|---|---|
| Floating ball (outer ring + core liquid + breathing/wave animation) | Keychain credential storage (currently config.json) |
| Dashboard accordion + ETA + sparkline | Alert notifications (AlertEngine + UserNotifications) |
| DeepSeek + Volcano providers (real-verified) | Settings UI, menu bar, launch-at-login |
| Burn rate / ETA wired to ball breathing & dashboard | MiMo / OpenAI / Anthropic, sandbox & signing |
| Volc Signature V4 signing + unified Quota model | (per-provider polling, backoff & persistence ✅) |

Full roadmap in [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Requirements

- **macOS 14.0+** (Sonoma; uses `PhaseAnimator` / `Canvas`)
- Xcode Command Line Tools (Swift 6.0 toolchain)

## Quick Start

### 1. Build

```sh
git clone https://github.com/kungf/buoy.git
cd buoy
swift build
```

### 2. Configure credentials

Credentials live **outside** the repo in `~/.buoy/config.json` (chmod 600, gitignored, never committed):

```json
{
  "providers": {
    "deepseek": { "token": "sk-your-deepseek-api-key" },
    "volcano":  { "ak": "your-volc-AccessKey", "sk": "your-volc-SecretKey" }
  }
}
```

> **Volcano note**: you need IAM **AccessKey + SecretKey** (console -> Access Control IAM -> Key Management), **not** an ARK inference API key. An `ark-` key hitting the control-plane OpenAPI returns 401.

### 3. Verify with the CLI

```sh
.build/debug/buoyctl all      # fetches deepseek + volcano once, prints quotas
```

Credential priority: env vars > `~/.buoy/config.json`:
- `BUOY_DEEPSEEK_TOKEN`
- `BUOY_VOLC_AK` / `BUOY_VOLC_SK`

### 4. Package & run

```sh
./Scripts/make-app.sh         # produces build/Buoy.app (LSUIElement background agent)
open build/Buoy.app
```

The ball appears at the top-right of the main screen. Use `BUOY_MOCK=critical|warning|exhausted|mixed|healthy open build/Buoy.app` for visual testing with mock scenarios (no network). Quit: `pkill -x Buoy`.

## Interactions

| Gesture | Action |
|---|---|
| hover | floating summary (provider + per-window percentages) |
| click | open dashboard (all providers at a glance) |
| scroll | cycle core liquid between 5h ↔ 7d (outer monthly ring unchanged) |
| drag | move the ball; snaps to nearest screen edge on release |
| right-click | menu (refresh / pause / settings / hide) |

## Architecture

Adapter-first: all provider differences are contained in the adapter layer; the upper UI / scheduling / prediction only knows the unified `Quota` model.

```
UI           FloatingBall (NSPanel) · Dashboard (accordion) · [Settings WIP]
              │ subscribes @Published
Service      UsageStore (ObservableObject) · ForecastEngine (burn rate/ETA)
              │ scheduling                    │ credentials
Adapter      Provider protocol · Volcano(V4) · DeepSeek(bearer) · [MiMo/OpenAI/Anthropic WIP]
              │
Core         Quota model · VolcSigner · HTTPClient · CredentialStore
```

Four SPM targets:
- **BuoyCore** (Foundation-only, zero AppKit/SwiftUI) -- model / auth / forecast / providers / networking
- **BuoyApp** -- floating ball + dashboard UI
- **buoyctl** -- adapter integration CLI
- **BuoyCoreTests** -- unit tests (33/33)

## Security

- API keys live only in `~/.buoy/config.json` (chmod 600, outside the repo); **never committed, never logged, never sent to third parties** (M2 will migrate to Keychain).
- `Credential` implements a redacting `CustomStringConvertible` -- any `print()` shows only the first 4 characters.
- Network is HTTPS-only (ATS + certificate validation).

## Documentation

- [`docs/DESIGN.md`](docs/DESIGN.md) -- full design doc (philosophy / architecture / provider specs / UI / milestones) -- in Chinese
- [`docs/ROADMAP.md`](docs/ROADMAP.md) -- roadmap and gap checklist -- in Chinese
- [`docs/M0-ACCEPTANCE.md`](docs/M0-ACCEPTANCE.md) -- M0 acceptance report -- in Chinese

## License

TBD (pre-release).
