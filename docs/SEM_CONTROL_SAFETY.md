# SEM Control Integration Guardrails

This controller should be treated as a human-interface layer, not as a direct
replacement for microscope safety controls. The final authority remains the
Zeiss microscope software, lab procedures, hardware interlocks, and the trained
operator.

## Default safety policy

- Ship with `Simulation / monitor only` selected by default.
- Require an explicit connected-and-armed state before any SEM command.
- Put every vendor API call behind `ISemAdapter`; no UI or MIDI code may call the
  microscope directly.
- Maintain an audit log with time, TP-7 input, normalized event, mapped action,
  command result, and operator identity if available.
- Provide a large on-screen `STOP` and map TP-7 STOP to cancel pending software
  actions. It must not be presented as a substitute for the laboratory emergency
  stop procedure.

## Continuous movement semantics

For any continuous navigation operation, use a deadman model:

```text
REC / rocker press or deflection -> begin bounded motion
REC release / rocker center / USB disconnect / app loses focus -> stop motion
```

The dispatcher needs a watchdog. If fresh input is not received within a short,
configurable timeout, it must call `StopAllMotion` in the adapter. Do not rely on
a final release event arriving after USB disconnect.

## Actions that should require deliberate confirmation or be excluded

Keep high-voltage, beam enable, vacuum/pump, stage collision-risk motion,
calibration writeback, and destructive acquisition/deletion outside the first
controller version unless the vendor integration and lab policy explicitly allow
them. If later added, make them two-step confirmed actions with clear current
state and hard software limits.

## Test progression

1. MIDI monitor only: prove every control without SEM connectivity.
2. Simulated adapter: validate state machine and logs.
3. Read-only SEM status adapter: show current state without writes.
4. One harmless, reversible command under supervision.
5. Add additional commands one at a time with an operator test script.

Never treat a successful keyboard shortcut test as proof that a microscope
command is safe or correctly acknowledged.
