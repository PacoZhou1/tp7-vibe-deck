# Open Speech ASR

Open Speech ASR is a macOS native dictation app forked from the previous OpenSpeech/FreeFlow codebase.

The default mode replaces the Python SenseVoice ASR path with Swift-native Qwen3-ASR while keeping local Gemma E4B for prompt-based correction:

- ASR runs in the Swift process through `speech-swift` `Qwen3ASR`.
- Text cleanup runs through the bundled local Gemma E4B backend, so prompt presets and custom vocabulary apply after recognition.
- The bundled model is `aufklarer/Qwen3-ASR-1.7B-MLX-4bit`.
- The packaged app includes the local model under `Contents/Resources/qwen3-asr-1.7b-4bit`.
- In the default mode, Python starts only for Gemma correction and skips loading SenseVoice ASR.
- `第三方 API` mode does not start the Python backend.

## Engine Modes

- `Qwen3-ASR + Gemma E4B`: default first-run mode. Loads the bundled Qwen3-ASR model in Swift, then uses local Gemma E4B for prompt presets, correction, output language, and custom vocabulary.
- `SenseVoice + Gemma E4B`: starts the bundled Python backend, exposes `/asr` and `/polish`, and waits for both `asrLoaded` and `modelLoaded`.
- `第三方 API`: uses the OpenAI-compatible API settings for audio transcription and LLM post-processing. Local Python/Gemma stays off.

## Build

```bash
make all
```

The build uses SwiftPM, then precompiles MLX Metal shaders into `mlx.metallib` and copies it next to the app executable. Do not skip this step: without the precompiled Metal library, MLX can fall back to runtime shader compilation and Qwen3-ASR inference becomes much slower.

The default model source is:

```text
/Users/paco/Documents/LLM-Models/Qwen3-ASR-1.7B-4bit
```

Override it with:

```bash
make all QWEN3_ASR_MODEL_SOURCE=/path/to/Qwen3-ASR-1.7B-4bit
```

## Package

```bash
make dmg
```

The DMG build resets local app state first for first-run QA, stages `Open Speech ASR.app`, includes an Applications alias, and signs the app. Set `CODESIGN_IDENTITY` and `NOTARIZE_PROFILE` for Developer ID distribution.

## Validation

The helper target below runs Qwen3-ASR against a real audio file using an explicit local model directory:

```bash
swift build -c release --product asr-smoke-test --disable-sandbox
.build/release/asr-smoke-test path/to/audio.aiff /Users/paco/Documents/LLM-Models/Qwen3-ASR-1.7B-4bit zh
```

The same helper can point at the bundled app model:

```bash
.build/release/asr-smoke-test path/to/audio.aiff "build/Open Speech ASR.app/Contents/Resources/qwen3-asr-1.7b-4bit" en
```
