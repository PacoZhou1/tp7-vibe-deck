# TP7 Vibe Deck Repository Guide

Date: 2026-07-14

This repository contains the native macOS reference app and the hardware
protocol material needed to extend it toward a Windows or SEM controller.

## Start here

1. Read `docs/TP7_MIDI_PROTOCOL.md`. It contains the confirmed CC map, wheel
   semantics, side-rocker handling, and the required TP-7 hardware setting.
   `docs/tp7-midi-map.json` is the same fixed mapping in machine-readable form.
2. Read `docs/WINDOWS_PORT_GUIDE.md` and keep the device/input/action profile
   architecture. The UI may be rewritten, but MIDI normalization and the mapping
   profile should remain separate from the SEM adapter.
3. Read `docs/SEM_CONTROL_SAFETY.md` before wiring a live microscope. Start by
   emitting harmless logs or vendor-supported navigation commands only.
4. Use `evidence/tp7-midi-capture-20260623-173816.json` as raw field evidence.
   The included macOS capture utility source can record a fresh JSON trace when
   an unfamiliar TP-7 firmware or button mode needs calibration.

## Repository layout

- `Sources/TP7VibeInput/`: native SwiftUI app, TP-7 model, MIDI listener,
  mapping system, action adapters, and menu bar UI.
- `Sources/TP7MIDICapture/`: standalone MIDI capture utility.
- `script/`: build, run, MIDI capture, and DMG packaging scripts.
- `evidence/`: original MIDI trace captured from this physical TP-7.
- `docs/`: protocol notes, porting rules, and SEM integration guardrails.
- `assets/`: README screenshots and the current app icon.

## What transfers directly to Windows

- The TP-7 USB/MIDI setup and MIDI event rules.
- The input-role model: buttons and wheel are inputs; mappings bind them to
  actions; actions are executed by an adapter.
- Persistent mapping profiles, learn mode, wheel sensitivity, invert option,
  press/release semantics, and the side-rocker dead-zone model.
- Visual assets: `tp7.usdz`, `tp7.glb`, SceneKit export, textures, and icon.
  Windows can normally consume the GLB rather than USDZ/SceneKit.

## What must be replaced on Windows

- SwiftUI, AppKit, CoreMIDI, CoreGraphics, macOS Accessibility, ServiceManagement.
- Open Speech/Hermes-specific actions, if they are not part of the target
  workflow. Replace them with a Zeiss SEM adapter.
- macOS-only key injection and application-defaults integration.

## Important non-goal

The repository proves TP-7 input handling. It does not include a Zeiss API,
vendor SDK, or authorization to operate a microscope. Keep the SEM command layer
behind an explicit adapter, with simulated mode enabled by default.
