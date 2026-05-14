# Block Context Handoff

This file is the lightweight session-to-session handoff for block-level RTL work.
It does not replace `AGENTS.md` or `HFT_RTL_System_Spec_Prompt.md`; read those first
before changing RTL.

## Project Goal

Implement the spec-defined headless, cut-through HFT trading engine pipeline:

```text
PCS -> mac_shim -> hdr_stripper -> field_aligner -> sym_id_mapper -> risk_gate -> pkt_formatter -> PCS
```

The best-case deterministic target is 7 cycles from inbound frame detection to
outbound launch. Do not add pipeline stages or interface signals without explicit
approval.

## Current Block Status

| Block | File | Status | Verification |
| --- | --- | --- | --- |
| `mac_shim` | `rtl/mac_shim.sv` | Implemented, has CRC/FCS logic, forwards the SOF/preamble word as required, and explicitly unrolls CRC bit steps to satisfy the project-level no-loop rule. | Verilator lint-only passes. `rtl/mac_shim_assertions.sv` lint-only passes with assertions enabled. `tb/tb_mac_shim.sv` covers block-lock suppression, SOF forwarding, EOF byte count, good FCS, and bad FCS rejection. |
| `hdr_stripper` | `rtl/hdr_stripper.sv` | Implemented, fixed IPv4/UDP header stripping and alignment. Has `SPEC_GAP` notes for bad-length definition and the stated 2-cycle budget conflict with in-stream preamble/header stripping. | Verilator lint-only passes. `rtl/hdr_stripper_assertions.sv` lint-only passes with assertions enabled. `tb/tb_hdr_stripper.sv` covers fixed strip/alignment, EOF behavior, EtherType/IHL/protocol errors, and short-frame error. |
| `field_aligner` | `rtl/field_aligner.sv` | Implemented with static offset parameters over the first 24 UDP payload bytes. Default layout remains unchanged; non-default static offsets are covered by the smoke test. | Verilator lint-only passes. `tb/tb_field_aligner.sv` lint-only passes. `rtl/field_aligner_assertions.sv` lint-only passes with assertions enabled. Existing VCD: `tb/field_aligner_smoke.vcd`. |
| `sym_id_mapper` | `rtl/sym_id_mapper.sv` | Implemented as an identity/tag placeholder because reset-time serial table load pins are absent from the frozen interface. | Verilator lint-only passes. `tb/tb_sym_id_mapper.sv` lint-only passes. `rtl/sym_id_mapper_assertions.sv` lint-only passes with assertions enabled. Existing VCD: `tb/sym_id_mapper_smoke.vcd`. |
| `risk_gate` | `rtl/risk_gate.sv` | Implemented with constant stand-in limits because risk tables and global kill config input are absent from the frozen interface. Single-cause kill reasons use the spec codes; simultaneous violations encode as reserved `4'hE` to avoid reason aliasing. | Verilator lint-only passes. `tb/tb_risk_gate.sv` lint-only passes. `rtl/risk_gate_assertions.sv` lint-only passes with assertions enabled. Existing VCD: `tb/risk_gate_smoke.vcd`. |
| `pkt_formatter` | `rtl/pkt_formatter.sv` | Implemented with a fixed Ethernet/IPv4/UDP template, 16-byte order payload, two Ethernet pad bytes, incremental FCS generation, one-cycle launch from `risk_pass`, and synchronous suppression on `risk_kill`. Has a `SPEC_GAP` note because the spec does not define addressing or payload schema. | Verilator lint-only passes. `tb/tb_pkt_formatter.sv` lint-only passes. `rtl/pkt_formatter_assertions.sv` lint-only passes with assertions enabled. Executable smoke build is blocked by missing `make`. |
| `hft_engine` | `rtl/hft_engine.sv` | Implemented as the top-level raw PCS RX/TX wrapper. Instantiates `mac_shim`, `hdr_stripper`, `field_aligner`, `sym_id_mapper`, `risk_gate`, and `pkt_formatter` in spec order. Includes sideband alignment registers for symbol/price/quantity/side across `sym_id_mapper` and `risk_gate` registered latencies. Has a `SPEC_GAP` note because the spec lists derived MAC signals at the top-level boundary while also requiring `mac_shim` inside the top. | Verilator lint-only passes with all child RTL. `tb/tb_hft_engine.sv` lint-only passes and is wired into `make test`. |
| Assertion bind files | `rtl/*_assertions.sv` | Complete for existing RTL modules: `mac_shim`, `hdr_stripper`, `field_aligner`, `sym_id_mapper`, `risk_gate`, and `pkt_formatter`. Recent hardening covers mid-frame block-lock loss, bounded payload completion, and exactly-one TX SOF per frame. | All assertion bind files lint-only pass standalone where applicable, with existing smoke tests where available, and through `hft_engine`. |

## Verification Snapshot

Commands used for the current audit:

```powershell
$env:VERILATOR_ROOT='C:\msys64\ucrt64\share\verilator'
verilator --lint-only --timing --top-module <module> rtl\<module>.sv
verilator --lint-only --timing --top-module <tb_module> -Irtl tb\<tb_module>.sv rtl\<module>.sv
```

Results:

- RTL lint-only passes for all seven existing RTL files, including integrated `hft_engine`.
- Testbench lint-only passes for `tb_mac_shim`, `tb_hdr_stripper`, `tb_field_aligner`, `tb_sym_id_mapper`, `tb_risk_gate`, `tb_pkt_formatter`, and `tb_hft_engine`.
- Assertion lint-only passes for all existing `rtl/*_assertions.sv` bind files with `--assert`.
- Executable simulation build is currently blocked because the MSYS Verilator install cannot find `make`.
- WSL execution was not available because no `Ubuntu` distro is installed.
- A Linux/WSL flow now exists:
  - `Makefile`
  - `scripts/run_verilator_flow.sh`
  - Run `make`, `make lint`, `make test`, or `make clean` from the repo root inside WSL.
  - `make test` builds under `/tmp/hft_verilator_flow_<user>` by default because GNU Make/Verilator cannot build inside repo paths containing spaces.

Latest WSL top-level smoke result from `tb_hft_engine`:

| Segment | Cycles | Time |
| --- | ---: | ---: |
| `mac_sof` to `payload_sof` | 7 | 44.8 ns |
| `payload_sof` to `field_valid` | 3 | 19.2 ns |
| `field_valid` to `sym_valid` | 1 | 6.4 ns |
| `sym_valid` to risk decision | 1 | 6.4 ns |
| Risk decision to `tx_sof` | 1 | 6.4 ns |
| `mac_sof` to `tx_sof` | 13 | 83.2 ns |
| `tx_sof` to `tx_eof` | 7 | 44.8 ns |

## Known Spec Gaps To Preserve

Existing `// SPEC_GAP:` markers are intentional and should remain until the spec
or interfaces are clarified:

- `hdr_stripper`: numeric definition of bad length.
- `hdr_stripper`: causal conflict between stripping preamble/header bytes and the written 2-cycle `rx_sof` to `payload_valid` budget.
- `sym_id_mapper`: serial table load required by spec, but no load pins are present.
- `risk_gate`: risk tables and global kill input required by spec, but no config/input interface is present.
- `risk_gate`: simultaneous violation priority is unspecified; current RTL reports multi-cause kills as `4'hE`.
- `pkt_formatter`: destination/source addressing and outbound order payload schema are unspecified.
- `hft_engine`: top-level boundary keeps derived MAC signals internal because `mac_shim` is instantiated inside the engine.

## Next Recommended Work

1. Resolve or formalize spec gaps around config/load interfaces and formatter packet schema.

## Session Checklist

Before editing any RTL in a future block session:

1. Read `AGENTS.md`.
2. Read `HFT_RTL_System_Spec_Prompt.md`.
3. Read this file.
4. Work on one module only unless explicitly told otherwise.
5. Preserve module interfaces and latency boundaries unless explicitly approved.
6. Add or update the block's smoke test only when asked, or when needed to verify a behavior change.
