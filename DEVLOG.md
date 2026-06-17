# Open Speech ASR Devlog

## Step 0 - Reconnaissance

- Source copy: `/Users/paco/Documents/AI-Projects/Open Speech ASR`; original project was not modified.
- Existing ASR contract: `LocalBackendClient.transcribe(fileURL:) async throws -> String`; callers pass an audio file URL and receive a final text string. There is no current partial/streaming callback contract in the local ASR call path.
- Python backend duties before migration: SenseVoice ASR plus local Gemma text correction, `/polish`, OpenAI-compatible chat completion, health, metrics, and memory cleanup. Conclusion: remove Python ASR responsibility, retain Python only for optional local Gemma correction.
- `speech-swift` API difference from the initial plan: current upstream uses `Qwen3ASRModel.fromPretrained(modelId:cacheDir:offlineMode:progressHandler:)` and `transcribe(audio:sampleRate:language:)`. It does not expose the planned `loadFromHub()` or `transcribe(audioFile:)` API in the checked-out code.

## Step 1 - Native ASR Provider

- Added `ASRProvider`, `TranscriptionResult`, and `Qwen3ASRProvider`.
- `Qwen3ASRProvider` loads `aufklarer/Qwen3-ASR-1.7B-MLX-4bit` once and keeps it warm.
- The provider first looks for the bundled model at `Contents/Resources/qwen3-asr-1.7b-4bit` and loads it offline; if missing, it falls back to speech-swift's default cache/download path.

## Step 2 - Call Chain Replacement

- Local dictation now calls `Qwen3ASRProvider.transcribe(audioURL:)`.
- Retry transcription, onboarding test transcription, and setup test transcription use the same current-mode transcription helper.
- `LocalBackendClient.transcribe` was removed; `LocalBackendClient.polish` remains for local Gemma correction.

## Step 3 - Backend Scope

- Python backend startup is gated by `appState.shouldRunLocalGemmaBackend`.
- Custom LLM correction mode no longer starts Python/Gemma.
- The default Qwen3-ASR mode no longer uses Python ASR. A selectable legacy `SenseVoice + Gemma E4B` mode keeps the Python `/asr`, `/polish`, and OpenAI-compatible endpoints available on demand.

## Step 4 - Build And Shader

- `Package.swift` now uses SwiftPM with `speech-swift` and the `Qwen3ASR` product.
- `Makefile` now runs `swift build -c release --disable-sandbox`, precompiles `mlx.metallib`, stages the app bundle, bundles Qwen3-ASR model resources, and bundles the optional Gemma correction backend.
- Fixed the upstream metallib helper locally so paths containing spaces, such as `Open Speech ASR`, do not break the shader hash step.
- Verified: `swift build -c release --disable-sandbox` completed successfully.
- Verified: `make all` completed successfully and copied `mlx.metallib` into `build/Open Speech ASR.app/Contents/MacOS/mlx.metallib`.
- Verified: `codesign --verify --deep --strict --verbose=2 build/Open Speech ASR.app` passed.

## Step 5 - Real Audio ASR Evidence

Device: Paco's Mac, Apple Silicon, macOS environment using Xcode SDK 26.5.

Chinese sample:

- Audio: `build/asr-test-audio/zh.aiff`
- Source text: `今天我们测试开放语音的本地识别功能，确认模型已经可以正确输出中文。`
- Duration: 7.075 s
- Load time: 0.421 s
- Inference time: 2.239 s
- RTF: 0.3165
- Transcript: `今天我们测试开放语音的本地识别功能，确认模型已经可以正确输出中文。`

English sample:

- Audio: `build/asr-test-audio/en.aiff`
- Source text: `This is a local speech recognition test for Open Speech ASR. The model should return clear English text.`
- Duration: 6.267 s
- Load time: 0.329 s
- Inference time: 0.147 s
- RTF: 0.0234
- Transcript: `This is a local speech recognition test for open speech ASR. The model should return clear English text.`

Bundled model verification:

- Model path: `build/Open Speech ASR.app/Contents/Resources/qwen3-asr-1.7b-4bit`
- Audio: `build/asr-test-audio/en.aiff`
- Inference time: 0.145 s
- RTF: 0.0232
- Transcript: `This is a local speech recognition test for open speech ASR. The model should return clear English text.`

## Step 6 - Packaging QA

- Default first-run policy changed to native Qwen3-ASR with local Gemma E4B correction disabled, so the app does not preload the Python/Gemma backend on launch.
- Verified after `scripts/reset_local_state.sh`: launching `build/Open Speech ASR.app` starts `OpenSpeechASR` and starts no `python3.13`, `inference_server.py`, `gemma-e4b`, or `mlx_lm` process.
- Verified: `make codesign-dmg CODESIGN_IDENTITY="Developer ID Application: Foshan Zifuhuan Technology Co., Ltd. (KA9U6H75UJ)"` completed.
- Verified: `hdiutil verify build/Open Speech ASR.dmg` passed.
- Verified: `codesign --verify --deep --strict --verbose=2 build/Open Speech ASR.app` passed.
- Verified: `codesign --verify --verbose=2 build/Open Speech ASR.dmg` passed.
- Verified: `spctl -a -vv --type execute build/Open Speech ASR.app` accepted the Developer ID signature, but still reports `source=Unnotarized Developer ID` until Apple notarization is accepted and stapled.
- Bundled Chinese audio check: `build/asr-test-audio/zh.wav`, duration 7.076 s, load 0.351 s, inference 2.092 s, RTF 0.2956, transcript `今天我们测试开放语音的本地识别功能，确认模型已经可以正确输出中文。`
- Bundled English audio check: `build/asr-test-audio/en.wav`, duration 6.268 s, load 0.333 s, inference 0.137 s, RTF 0.0218, transcript `This is a local speech recognition test for open speech ASR. The model should return clear English text.`

## Step 7 - Engine Mode Review

- Replaced the confusing local/custom-LLM toggle pair with one persisted `ASREngineMode`: `Qwen3-ASR（原生）`, `SenseVoice + Gemma E4B`, and `第三方 API`.
- Menu bar and Settings now read/write the same engine mode, so frontend selection and backend process behavior stay aligned.
- Verified default first-run `Qwen3-ASR` mode: app logs show bundled model loading from `Contents/Resources/qwen3-asr-1.7b-4bit`, and no Python backend process starts.
- Verified `第三方 API` mode: only `OpenSpeechASR` starts; no `python3.13`, `inference_server.py`, `gemma-e4b`, or `mlx_lm` process starts.
- Verified `SenseVoice + Gemma E4B` mode: backend `/health` returns `modelLoaded=true` and `asrLoaded=true`; `/asr` transcribed the Chinese WAV as `今天我们测试开放语音的本地识别功能确认模型已经可以正确输出中文`.
- Verified Swift build: `swift build -c release --disable-sandbox` completes with no warnings after removing obsolete provider settings UI and updating deprecated SwiftUI change handlers.

## Step 8 - Qwen ASR + Local Gemma Correction

- Changed the default Qwen engine from raw ASR / optional third-party correction to `Qwen3-ASR + Gemma E4B`.
- Qwen still performs ASR inside Swift; local Gemma E4B now performs prompt-based cleanup, preset behavior, output-language handling, and custom vocabulary application through `/polish`.
- The local Python backend can now start in Gemma-only mode with SenseVoice ASR disabled, so Qwen mode does not load the SenseVoice model unnecessarily.
- `SenseVoice + Gemma E4B` remains available as the legacy full local backend mode and still enables `/asr`.

## Step 9 - Combined MLX Memory Budget

- Added a shared 8GB soft budget for the Swift Qwen3-ASR process plus the local Gemma backend process.
- The Swift app now polls backend `/api/metrics`, reads its own Qwen MLX memory and process footprint, and triggers cleanup when the combined footprint crosses the soft limit.
- Backend `/api/memory/cleanup` now accepts the peer process footprint, dynamically shrinks MLX `cache_limit`, and clears cache based on the remaining global budget.
- Qwen3-ASR now sets MLX `memoryLimit`, caps `cacheLimit`, clears recyclable cache after inference, and releases the Qwen model when switching away from Qwen mode.
- Restart remains last resort: the app first clears Qwen and Gemma caches; Qwen model release only happens while idle and after caches are already low; backend restart only follows an explicit backend hard-limit recommendation.
- Verified: `swift build -c release --disable-sandbox` completed successfully.
- Verified: bundled backend `python3.13 -m py_compile backend/inference_server.py` completed successfully.
- Verified: backend peer-budget cleanup with `global_soft=8000 MB` and peer footprint `7900 MB` reduced the backend target cache limit to `0 MB` without recommending restart.
- Verified: `make all` rebuilt and ad-hoc signed `build/Open Speech ASR.app`; `codesign --verify --deep --strict --verbose=2 build/Open Speech ASR.app` passed.

## Step 10 - Stale Process Guard

- Found the high-memory `OpenSpeechASR` and backend `python3.13` processes were launched from `/Volumes/Open Speech ASR/Open Speech ASR.app`, so they were old DMG instances rather than the rebuilt `build/Open Speech ASR.app`.
- Added `scripts/stop_running_instances.sh` to terminate both the Swift app and bundled backend from mounted DMGs, build bundles, or old dev runtime paths.
- Updated `scripts/reset_local_state.sh` to reuse the same stop script before clearing defaults, saved state, containers, logs, and TCC permissions.
- Updated `make all` to run `stop-running` first, so future build/test/package cycles do not leave an old mounted DMG instance masking the new code.
- Verified: stale `/Volumes` PIDs were terminated and `pgrep -fl "OpenSpeechASR|python3.13|inference_server.py|Open Speech ASR"` returned no running app/backend process.
- Verified: `make all` still rebuilds and signs `build/Open Speech ASR.app`; `codesign --verify --deep --strict --verbose=2 build/Open Speech ASR.app` passed.
- Tightened Qwen3-ASR cleanup after reviewing the decoder path: every native ASR call now force-synchronizes the MLX GPU stream and clears cache after transcription, and the Qwen cache limit is capped at 256MB instead of 1GB to avoid per-use cache growth.
