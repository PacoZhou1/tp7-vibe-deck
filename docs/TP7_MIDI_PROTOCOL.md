# TP-7 MIDI Control Protocol

## Required TP-7 setting

Connect TP-7 by direct USB, then on the device hold `MODE`, open `MIDI`, and
select `ctrl`.

- `off`: MIDI control disabled.
- `sync`: MIDI clock synchronization, not the control surface mode.
- `ctrl`: exposes TP-7 as a MIDI source and destination and produces controls.

The macOS reference observed a MIDI endpoint named `TP-7`; the Windows port
should enumerate all MIDI inputs and prefer an endpoint containing `TP-7`, while
still allowing the user to select one manually.

## Confirmed fixed controls

All values below are 1-based MIDI channel numbering. Button press is `127` and
release is `0`. Treat any non-zero value as press, and value `0` as release.

| Physical control | MIDI message | Press | Release | Current default behavior |
| --- | --- | ---: | ---: | --- |
| REC | CC, channel 1, controller 22 | 127 | 0 | Hold-to-record / deadman action |
| PLAY | CC, channel 1, controller 23 | 127 | 0 | One-shot action |
| STOP | CC, channel 1, controller 24 | 127 | 0 | Stop/cancel action |
| Minus | CC, channel 1, controller 25 | 127 | 0 | User-mappable |
| Plus | CC, channel 1, controller 26 | 127 | 0 | User-mappable |
| Memo | CC, channel 1, controller 27 | 127 | 0 | User-mappable, supports short/long press |
| Menu | CC, channel 1, controller 28 | 127 | 0 | User-mappable |
| Main wheel | CC, channel 1, controller 30 | relative | n/a | Relative scroll/cursor axis |

The original macOS source for this fixed mapping is
`Sources/TP7VibeInput/Models/TP7Mapping.swift`.

## Main wheel semantics

TP-7 main wheel is a 7-bit relative CC encoder rather than an absolute 0-127
position. Decode it as:

```text
relative = value,       if value < 64
relative = value - 128, if value >= 64
```

So values `1...63` are positive motion, and `127...64` represent `-1...-64`.
Ignore `0`. Apply user sensitivity after decoding; never attempt to interpolate
the raw values as an absolute position.

The reference app clamps an individual dispatch to `-24...24` steps after
scaling. For text cursor mode its intended current feel is:

| User speed | Cursor steps per physical wheel event |
| --- | ---: |
| Low | 1 |
| Medium (default) | 3 |
| High | 5 |

For SEM, use the same relative axis but bind it to a safe, bounded parameter
(for example focus fine-step or image pan) through the vendor adapter. Show the
current step size and direction in the UI.

## Side rocker / shuttle control

The left-side forward/back rocker is **not a fixed CC mapping** in the reference
implementation. It is handled as MIDI Pitch Bend on channel 1:

```text
raw 14-bit = LSB | (MSB << 7)
signed     = raw 14-bit - 8192
```

- `0` means the rocker returned to center: immediately stop any continuous
  operation.
- Positive signed values are dispatched as `Side Forward` by the existing app.
- Negative signed values are dispatched as `Side Backward` by the existing app.
- The macOS app uses a small center dead zone and a 180 ms release cooldown to
  prevent stale/rebound values from producing a final unwanted action.

The included raw trace contains a full pitch-bend sweep with `Up`/`Down` markers.
That historical capture predates a capture-parser fix and labels its packets as
`raw` even though bytes begin with `0xE0`; it is still useful as byte-level
evidence. Do not infer human-facing direction labels from it alone. In the
Windows app, provide a one-time calibration screen: ask the operator to push
forward, record the sign, then persist it as the axis inversion preference.

## Press/hold behavior worth preserving

- One-shot controls execute exactly once on non-zero press, never on release.
- Hold actions begin on press and end on the corresponding zero release.
- Side-rocker continuous actions must stop at center; do not wait for a timer.
- Cursor-like hold repeat starts with one immediate step, then waits before
  repeating. This prevents a short tap from jumping multiple units.

Reference timing model:

| Speed | Initial delay | Base repeat interval |
| --- | ---: | ---: |
| Low | 420 ms | 180 ms |
| Medium | 360 ms | 110 ms |
| High | 200 ms | 65 ms |

Acceleration is applied by increasing the number of steps per tick over elapsed
hold time. This model is implemented in
`Sources/TP7VibeInput/Stores/AppStore.swift` and can be ported independently of
the UI.

## MIDI output / control handshake

The reference app can locate TP-7 as a MIDI destination and sends a conservative
connection activation sequence. It is only intended to establish/control a
connection, not to start recording or transport:

```text
for channels 1..6: CC 7 = 127, CC 120 = 0
for channels 1..3: CC 9 = 0
channel 1: Pitch Bend = 0, CC 18 = 64, CC 16 = 0
```

This is retained in `TP7MIDIListener.activateControl()`. It is optional for a
Windows read-only controller. Do not send undocumented MIDI output to the TP-7
while an SEM control experiment is being commissioned unless its effect is
separately verified.

## Learn mode rule

Unknown inputs should not silently become dangerous mappings. Require the user
to select a role, enter Learn mode, then press exactly one physical TP-7 control.
Store the resulting MIDI signature; reject duplicate signatures unless the user
explicitly replaces an existing mapping.
