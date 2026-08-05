# Windows Port Guide: TP-7 Vibe SEM Deck

## Recommended architecture

Keep the following four layers separate. The macOS app already follows this
shape, even though its names are Swift-specific.

```text
MIDI input -> Normalizer -> Mapping profile -> Action dispatcher -> SEM adapter
```

1. **MIDI input**: opens the selected TP-7 MIDI source and reopens it after USB
   reconnects.
2. **Normalizer**: turns CC, note, and pitch-bend messages into stable events:
   `ButtonDown`, `ButtonUp`, `RelativeWheel(delta)`, and
   `SideAxis(value, centered)`.
3. **Mapping profile**: persistent configuration of TP-7 input role to action.
   It knows nothing about the Zeiss SDK.
4. **Action dispatcher**: applies one-shot, hold, long-press, rate-limit, and
   cancellation rules.
5. **SEM adapter**: the only layer allowed to call the Zeiss vendor SDK,
   microscope automation API, scripting host, or simulated test harness.

## Windows implementation choices

Use a native desktop UI such as WinUI 3 or WPF with .NET 8+. For MIDI, use a
maintained Windows MIDI API/library that gives raw CC and pitch-bend values and
device-added/device-removed callbacks. Do not design the app around simulated
keyboard events; call a dedicated SEM adapter interface instead.

Suggested project structure:

```text
Tp7SemDeck/
  UI/                 WinUI/WPF screens and 3D/2D TP-7 visual
  Domain/             InputRole, MidiSignature, Action, MappingProfile
  Midi/               MIDI device discovery, parser, reconnect logic
  Dispatch/           hold state machine, wheel/rocker timing
  Sem/                ISemAdapter, SimulatedSemAdapter, ZeissSemAdapter
  Persistence/        JSON profile and calibration storage
  Diagnostics/        MIDI recorder and replay tests
```

## Reuse these source files as behavioral references

| Source file | Reuse value |
| --- | --- |
| `Models/TP7Mapping.swift` | Canonical roles, CC signatures, action model, wheel and hold settings |
| `Models/TP7ControlEvent.swift` | Minimal normalized event shape |
| `Services/TP7MIDIListener.swift` | MIDI parsing, reconnect, TP-7 destination activation reference |
| `Stores/AppStore.swift` | Dispatch order, wheel decoding, side-rocker state machine, timing |
| `Sources/TP7MIDICapture/` | Standalone MIDI capture utility and JSON evidence format |
| `Views/TP7DeviceSceneView.swift` | TP-7 visual interaction/hotspot reference |
| `Resources/TP7Model.scnassets/tp7.glb` | Best source asset for a Windows 3D renderer |

## Minimum viable SEM mapping

Begin with a `SimulatedSemAdapter` that merely logs calls. Then prove these
paths one at a time against an approved Zeiss integration:

| TP-7 input | Initial SEM-safe action concept |
| --- | --- |
| REC hold | Deadman enable while held, no motion by itself |
| PLAY | Capture/mark current image, if the vendor API supports it |
| STOP | Emergency stop for software commands / cancel queued command |
| Wheel | Fine focus or image pan in bounded relative increments |
| Side rocker | Continuous image pan only while deflected; center stops |
| Plus / Minus | Select a finer/coarser step preset, never alter high voltage directly |
| Menu | Open mapping/safety panel, not a microscope action |
| Memo | Record annotation or attach a note to the current acquisition |

Do not assume the exact Zeiss API names or permissions. The Windows developer
should implement `ZeissSemAdapter` only after checking the installed microscope
software, vendor documentation, and local lab policy.

## UI/asset portability

The macOS app's SceneKit/USDZ path is Apple-specific. Use the bundled `tp7.glb`
and texture PNGs for Windows. If 3D integration slows delivery, begin with a
high-resolution 2D rendering from the assets and retain the same input-role
selector, inspector, learn mode, and status panel.

## Diagnostics required before live SEM control

1. Enumerate the TP-7 endpoint and display its exact name.
2. Log every normalized event with timestamp and raw bytes.
3. Run each button through a simulated adapter first.
4. Confirm REC release and side-rocker center always stop an active hold action.
5. Persist calibration per physical device/firmware and expose Reset to Defaults.
6. Keep a safe "MIDI monitor only" mode that cannot send any SEM command.
