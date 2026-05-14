# agents.md — HFT Trading Engine RTL Project

## Session Behavior

- Read this file at the start of every session. Do not summarize it back to the user.
- The full system specification is in `HFT_RTL_System_Spec_Prompt.md`. Read it before generating or modifying any RTL.
- Design rationale is in `DESIGN_NOTES.md`. Read it only if a spec ambiguity requires architectural judgment.

## Scope

- You are working on one module per session unless explicitly told otherwise.
- Do not refactor interfaces or pipeline boundaries across modules without explicit instruction.
- Do not infer requirements not stated in the spec. If a gap exists, insert a `// SPEC_GAP:` comment and implement the minimum-latency interpretation.

## Output Rules

- One `.sv` file per module. File name must match module name exactly.
- Each file must open with the standard header comment block defined in §5.5 of the spec.
- Do not emit testbench code unless asked. Do not emit `$display` or `$monitor` in synthesizable blocks.

## What Not To Do

- Do not add pipeline stages not defined in the spec.
- Do not introduce AXI, AHB, or any bus wrapper on any datapath signal.
- Do not use loops, latches, or blocking assignments in `always_ff` blocks.
- Do not modify `agents.md` or `HFT_RTL_System_Spec_Prompt.md` during a session.