# Open Speech ASR

Open Speech ASR is a native macOS menu bar dictation app. It uses a Swift
Qwen3-ASR pipeline for local speech recognition and can apply local Gemma E4B
text cleanup after transcription.

The current public baseline is tagged `appstore-submitted-2026-06-16`. Ongoing
App Store review remediation work lives on
`appstore-review-fix/nonpublic-api`.

## Highlights

- Native macOS app built with SwiftUI and Swift Package Manager.
- Local Qwen3-ASR recognition through `speech-swift` and `Qwen3ASR`.
- Optional local Gemma E4B correction for prompt presets, custom vocabulary,
  output language, and cleanup.
- Legacy `SenseVoice + Gemma E4B` mode remains available for compatibility.
- OpenAI-compatible third-party API mode can run without starting the local
  Python backend.
- Packaged builds include the Qwen3-ASR model under
  `Contents/Resources/qwen3-asr-1.7b-4bit`.
- The release build precompiles `mlx.metallib` so MLX avoids slow first-use
  shader compilation.

## Engine Modes

`Qwen3-ASR + Gemma E4B` is the default mode. ASR runs in the Swift process, then
the bundled local Gemma backend performs optional prompt-based cleanup.

`SenseVoice + Gemma E4B` starts the bundled Python backend and exposes both ASR
and polish endpoints. It is the legacy local mode.

`第三方 API` uses OpenAI-compatible transcription and chat settings. The local
Python/Gemma backend stays off in this mode.

## Repository Layout

```text
Sources/        SwiftUI app, transcription pipeline, settings, and providers
backend/        Bundled Python backend for Gemma correction and legacy SenseVoice
Resources/      App icons and shared bundled resources
scripts/        Build, QA, state reset, and GitHub sync helpers
website/        Static landing-page assets
Makefile        Build, packaging, signing, notarization, and run targets
```

Build outputs, SwiftPM build state, App Store Connect keys, certificates, and
provisioning profiles must not be committed. The repository intentionally keeps
`build/`, `.build`, `.DS_Store`, Python caches, and `.env` out of Git.

## Build

```bash
make all
```

The build uses SwiftPM, precompiles MLX Metal shaders into `mlx.metallib`,
copies the app executable into `build/Open Speech ASR.app`, bundles the local
ASR model, bundles the optional Gemma backend, and signs the app.

The default Qwen3-ASR model source is:

```text
/Users/paco/Documents/LLM-Models/Qwen3-ASR-1.7B-4bit
```

Override it when needed:

```bash
make all QWEN3_ASR_MODEL_SOURCE=/path/to/Qwen3-ASR-1.7B-4bit
```

## Package

```bash
make dmg
```

The DMG target resets local app state, stages `Open Speech ASR.app`, adds an
Applications alias, and signs the app. Set `CODESIGN_IDENTITY` and
`NOTARIZE_PROFILE` for Developer ID distribution and notarization:

```bash
make notarize \
  CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  NOTARIZE_PROFILE="notarytool-profile"
```

## Validation

Run a release Swift build:

```bash
swift build -c release --disable-sandbox
```

Run ASR smoke tests against a local model:

```bash
swift build -c release --product asr-smoke-test --disable-sandbox
.build/release/asr-smoke-test path/to/audio.aiff /Users/paco/Documents/LLM-Models/Qwen3-ASR-1.7B-4bit zh
```

Run the same helper against a bundled app model:

```bash
.build/release/asr-smoke-test \
  path/to/audio.aiff \
  "build/Open Speech ASR.app/Contents/Resources/qwen3-asr-1.7b-4bit" \
  en
```

Verify signed artifacts:

```bash
codesign --verify --deep --strict --verbose=2 "build/Open Speech ASR.app"
hdiutil verify "build/Open Speech ASR.dmg"
```

## GitHub Sync

The canonical remote is:

```text
https://github.com/PacoZhou1/open-speech-asr
```

For this local checkout, automatic GitHub sync can be installed with:

```bash
scripts/install_auto_sync_hook.sh
```

The hook runs after each commit and pushes the current branch plus tags to
`origin`. Manual sync is also available:

```bash
scripts/sync_to_github.sh
```

The hook only pushes committed Git objects. It does not stage or commit local
changes, and it does not upload ignored build output or secret files.

## Current GitHub Baseline

- `main`: App Store submission baseline.
- `appstore-submitted-2026-06-16`: tag for the submitted build baseline.
- `appstore-review-fix/nonpublic-api`: current App Store review fix branch.
