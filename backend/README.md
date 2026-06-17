# Open Speech ASR Local Backend

This directory contains the bundled Python backend used by local Gemma
correction modes and by the legacy SenseVoice ASR mode.

The default `Qwen3-ASR + Gemma E4B` mode performs ASR in Swift and starts this
backend only for Gemma text correction. SenseVoice ASR is disabled in that mode
to avoid unnecessary model loading.

## Modes

- `Gemma-only`: exposes polish and chat-completion endpoints for Qwen3-ASR text
  cleanup.
- `SenseVoice + Gemma E4B`: exposes both local ASR and text cleanup for the
  legacy pipeline.
- `Third-party API`: does not require this backend.

## Runtime Endpoints

- `GET /health`
- `POST /asr`
- `POST /v1/audio/transcriptions`
- `POST /polish`
- `POST /v1/chat/completions`
- `GET /api/metrics`
- `POST /api/memory/cleanup`

## Packaging Notes

`make all` copies `inference_server.py`, `config.yaml`, model directories, and a
standalone Python runtime into the app bundle under
`Contents/Resources/backend`.

Do not commit bundled runtime output, downloaded models, API keys, certificates,
or provisioning profiles.
