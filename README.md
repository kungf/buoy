# TokenRunway 🛬

[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-005F9E?logo=apple)](https://apple.com/macos)
[![License](https://img.shields.io/badge/license-MIT-brightgreen)](LICENSE)

<p align="center">
  <img src="assets/ball_volcano.gif" alt="Volcano floating ball: monthly / weekly / 5-hour quotas" width="350">
  <img src="assets/ball_deepseek.gif" alt="DeepSeek floating ball and hover card: balance + last-5h spend" width="350">
</p>

> An always-on macOS desktop floating ball that shows how many minutes of AI you have left — at a glance, across all your providers, before you hit empty.

"Runway" is the startup word for "how long can you keep burning at this rate before you're out." **TokenRunway** puts that number on your desktop as a floating ball. The outer ring shows your monthly remaining; the core liquid shows your current-window remaining; the ball's breathing rate mirrors your actual burn rate. When it starts breathing hard and flashing red, your 5-hour quota is 10 minutes from empty. You knew before it happened.

---

## Why

- **Glanceable**: see consumption at a glance, without switching away from your work or opening a browser.
- **Unified multi-provider view**: Volcano (5h / 7d / 30d rolling windows), DeepSeek (pure balance), Kimi Code (weekly quota + rolling rate windows + booster wallet), MiMo (monthly Token Plan), Zhipu (monthly / weekly token quotas), MiniMax (5h rolling window + weekly) — rendered homogeneously; click for a full dashboard across all providers.
- **Prediction over reporting**: computes ETA from burn rate ("at the current pace, your 5h quota has 12 minutes left"), attacking the pain of "my 5-hour quota burned out in 10 minutes before I noticed."
- **Low-overhead resident**: native SwiftUI + AppKit, tiny resident memory and CPU; never steals focus.

## Providers

Adapter-first architecture: every provider maps onto one unified `Quota` model.

**Done (real-verified)**

| Provider | What is shown |
|---|---|
| Volcano Engine (火山引擎) | 5h / 7d / 30d rolling windows |
| DeepSeek | Pure account balance (¥) |
| Kimi Code | Weekly quota + rolling rate windows |
| MiMo | Monthly Token Plan |
| Zhipu | Monthly / weekly token quotas |
| MiniMax | 5h rolling window + weekly |

**Not yet**: OpenAI · Anthropic — planned next.

## Requirements

- **macOS 14.0+** (Sonoma; uses `PhaseAnimator` / `Canvas`)
- Xcode Command Line Tools (Swift 6.0 toolchain)

## Installation

### Homebrew

> 🚧 Coming soon - pending Apple notarization and a cask tap. For now, build from source.

### Build from source

**1. Build**

```sh
git clone https://github.com/kungf/token-runway.git
cd token-runway
swift build
```

**2. Package & run**

```sh
./Scripts/make-app.sh         # produces build/TokenRunway.app (LSUIElement background agent)
open build/TokenRunway.app
```

The ball appears at the top-right of the main screen. Quit: `pkill -x TokenRunway`.

**Preview without credentials** - run the real UI with synthetic data, no API keys or network:

```sh
TRWY_MOCK=mixed open build/TokenRunway.app
```

Six scenarios to try: `healthy` · `warning` · `critical` · `exhausted` · `mixed` · `balance-critical`.

**Distribution signing** — by default the build is ad-hoc signed (no certificate needed; fine for local use and screenshots). To produce a Developer-ID-signed build for distribution:

```sh
TRWY_SIGNING=identity \
TRWY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
./Scripts/make-app.sh
```

This enables Hardened Runtime with a network-client entitlement. Notarization and stapling are a separate step (TODO: `Scripts/notarize.sh`) and require an Apple Developer account.

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
UI           FloatingBall (NSPanel) · Dashboard (accordion) · Settings (per-provider sheet)
              │ subscribes @Published
Service      UsageStore (ObservableObject) · ForecastEngine (burn rate/ETA)
              │ scheduling                    │ credentials
Adapter      Provider protocol · Volcano(V4) · DeepSeek(bearer) · Kimi Code(localCLI) · MiMo(consoleSession) · Zhipu(bearer) · MiniMax(bearer) · [OpenAI/Anthropic WIP]
              │
Core         Quota model · VolcSigner · HTTPClient · CredentialStore
```

Four SPM targets:
- **TokenRunwayCore** (Foundation-only, zero AppKit/SwiftUI) — model / auth / forecast / providers / networking
- **TokenRunwayApp** — floating ball + dashboard UI
- **trwyctl** — CLI (integration / debugging)
- **TokenRunwayCoreTests** — unit tests (164/164)

## Security

- API keys live only in `~/.trwy/config.json` (chmod 600, outside the repo); **never committed, never logged, never sent to third parties** (M2 will migrate to Keychain).
- `Credential` implements a redacting `CustomStringConvertible` — any `print()` shows only the first 4 characters.
- Network is HTTPS-only (ATS + certificate validation).

## Documentation

- [`docs/DESIGN.md`](docs/DESIGN.md) — full design doc (philosophy / architecture / provider specs / UI / milestones) — in Chinese
- [`docs/M0-ACCEPTANCE.md`](docs/M0-ACCEPTANCE.md) — M0 acceptance report — in Chinese
- [Live site](https://kungf.github.io/token-runway/) — landing page (GitHub Pages)

## License

MIT — see [LICENSE](LICENSE).