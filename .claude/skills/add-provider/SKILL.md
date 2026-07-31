---
name: add-provider
description: Add a new token provider to token-runway - adapter + manifest + logo + registry registration. Use when integrating a new LLM provider's quota/balance API (e.g. OpenAI, Anthropic, Moonshot, Qwen).
---

# add-provider

Integrate a new provider into token-runway. After the ProviderRegistry refactor,
a provider's identity is declared **once** in its `ProviderManifest` and derived
everywhere (theme, ball nameplate, settings help link, trwyctl env vars). So
adding a provider is mostly: write an adapter, drop in a logo, register one line.

## Inputs you need from the user

Before starting, confirm: provider `id` (lowercase, e.g. `openai`), display name,
auth mode (bearer / volcSignature / consoleSession), the quota/usage API endpoint,
the quota shape (balance vs rolling time-window), and a square logo PNG. If the
user doesn't know the API shape, read the provider's API docs first.

## Steps

1. **Adapter** - create `Sources/TokenRunwayCore/Providers/<Name>Provider.swift`
   from `Provider.template.swift` (same directory as this skill). Fill the
   `ProviderManifest` and implement `fetchUsage` + `parse`.

2. **Logo** - add `Sources/TokenRunwayApp/Resources/<id>_logo.png` (square,
   transparent, ~64–128px). The `logoName` in the manifest must equal this
   filename **without** the extension.

3. **Register** - add one line to `ProviderRegistry.all` in
   `Sources/TokenRunwayCore/Provider/ProviderRegistry.swift`. Order matters:
   it drives the default ball and cluster arrangement.

4. **Parsing tests** - add cases to `Tests/TokenRunwayCoreTests/ProviderParsingTests.swift`
   (happy path + an error/edge case). Use a real doc-sample response when available.

5. **Build + test** - `swift build && swift test`. The consistency tests
   (`ProviderThemeRegistryTests`, `ProviderRegistryTests`) will fail if you
   forgot the logo, `shortName`, `consoleURL`, or mis-declared the manifest.

That's it for the common case (reusing an existing `AuthMode`). No edits needed
in `UsageStore`, `ProviderTheme`, `trwyctl`, or `ProviderSettingsView` - they
all derive from the registry/manifest.

## When you DO need to touch more (new auth scheme)

Only if the provider needs a brand-new auth mode (not bearer/volcSignature):

- `Sources/TokenRunwayCore/Provider/Provider.swift` - add an `AuthMode` case
  and a `Credential` case. The `Credential` enum has a redacting
  `CustomStringConvertible` - **every new case must redact** (prefix 4 chars +
  length), never print raw secrets.
- `Sources/TokenRunwayCore/Config/CredentialStore.swift` - teach
  `credential(for:from:)` to map config fields -> the new `Credential` case.
- `Sources/TokenRunwayApp/Dashboard/ProviderSettingsView.swift` - add form
  fields + help steps for the new `authMode`. The five `switch authMode` blocks
  are exhaustive with no `default`, so the **compiler forces** you to handle it.

## Conventions (the part that isn't just "which files")

**Manifest is the single source of truth.** Declare everything there; do not
hardcode the provider's id/name/URL/color a second time anywhere.

- `id` - lowercase, stable, never localized (drives `Quota.id`, config keys,
  env vars). `displayName` is the human name (may be localized, e.g. `火山引擎`).
- `authMode` - reuse `.bearer` for API-key/Bearer-token providers (the common
  case: DeepSeek, OpenAI, Anthropic, Moonshot). `.volcSignature` is
  Volcano-specific HMAC. `.consoleSession` for console-only providers.
- `defaultPollInterval` - `120` for short rolling windows (5h), `180` for
  balance endpoints. Trades freshness vs request volume.
- `shortName` - 2–3 chars for the 88pt ball nameplate (`ds`, `vol`).
- `consoleURL` - the platform page where the user gets the credential. Used by
  the settings help popover **per provider** (not per authMode).
- `logoName` - `"<id>_logo"`. Must match a bundled resource (test-enforced).
- `themeColor` - pick from the `ThemeColor` enum. Adding a hue = add a case to
  the enum + the `asColor` switch (compiler-enforced).
- `envPrefixOverride` - **omit** unless a legacy env-var name must be preserved
  (Volcano uses `"VOLC"` not `"VOLCANO"`). Default is `id.uppercased()`.

**Quota modeling** (`Sources/TokenRunwayCore/Model/Quota.swift`):

- `.balance` - account balance, no time window (DeepSeek).
- `.timeWindowed` - rolling window with `windowStart` + `resetsAt` (Volcano).
- `.rateLimit` - TPM/RPM (not yet wired).
- `Quota.id` format: `"<provider>.<window>"` (e.g. `volcano.5h`, `deepseek.balance`).
- **Skip windows where `limit == 0`** - they mean "not subscribed"; generating
  them yields misleading 0% and divide-by-zero risk.
- `Unit` - `.tokens` / `.credits` / `.usd` / `.cny`. **Never aggregate across
  units or providers** - they're not comparable.

**Credentials & security** (DESIGN.md §10):

- Keys never logged, never printed, never written to repo. `Credential`'s
  `description` already redacts - don't bypass it.
- `fetchUsage` must `guard` the credential matches `authMode` and throw
  `ProviderError.missingCredential` otherwise.
- Storage is `~/.trwy/config.json` via `CredentialStore` (chmod 0600). trwyctl
  env vars are auto-derived from `manifest.envPrefix` - **no trwyctl code change
  needed** for a new provider.

**Parse errors**: `throw ProviderError.parse("<id>: <code>")` - expose only the
error code, **never** the server's free-text message (it may leak info). Use
`ProviderError.fromStatus(response.status)` for HTTP status mapping before
parsing the body.

## Checklist

- [ ] Adapter created, manifest fully filled, `fetchUsage` + `parse` implemented
- [ ] `parse` tested (happy path + edge case) in `ProviderParsingTests`
- [ ] Logo PNG added; `logoName` matches filename
- [ ] Registered in `ProviderRegistry.all`
- [ ] `swift build && swift test` green (incl. consistency tests)
- [ ] Smoke test: `.build/debug/trwyctl <id>` and `trwyctl all`
- [ ] No secret values in logs / errors / commit
