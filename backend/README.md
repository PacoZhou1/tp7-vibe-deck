# Open Speech ASR Legacy Local Backend

This backend is used by local Gemma correction modes.
The default `Qwen3-ASR + Gemma E4B` mode uses Qwen3-ASR in Swift and starts this backend for Gemma text correction only; SenseVoice ASR is disabled in that mode.

Runtime endpoints:

- `GET /health`
- `POST /asr`
- `POST /v1/audio/transcriptions`
- `POST /polish`
- `POST /v1/chat/completions`
- `GET /api/metrics`
- `POST /api/memory/cleanup`
