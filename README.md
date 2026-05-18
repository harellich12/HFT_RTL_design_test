# HFT RTL Design Test

SystemVerilog RTL for a headless, cut-through high-frequency trading datapath.
The design targets deterministic minimum latency from raw PCS receive words to an
outbound order packet, with no CPU, firmware, DMA, AXI, AHB, or other bus wrapper
in the critical path.

The implemented pipeline is:

```text
PCS RX -> mac_shim -> hdr_stripper -> field_aligner -> sym_id_mapper -> risk_gate -> pkt_formatter -> PCS TX
```

## Repository Layout

| Path | Purpose |
| --- | --- |
| `rtl/` | Synthesizable SystemVerilog RTL and SVA bind files. |
| `tb/` | Smoke testbenches for the leaf blocks and integrated top level. |
| `scripts/run_verilator_flow.sh` | Verilator lint/build/test flow. |
| `Makefile` | Convenience wrapper around the Verilator flow. |
| `HFT_RTL_System_Spec_Prompt.md` | Original architecture and module specification. |
| `PROJECT_SPEC_SHEET.md` | Derived status sheet mapping spec requirements to the current implementation. |
| `BLOCK_CONTEXT.md` | Lightweight handoff/status notes for future RTL sessions. |
| `DESIGN_NOTES.md` | Architectural rationale for latency-oriented choices. |

## RTL Blocks

| Block | Status |
| --- | --- |
| `mac_shim` | Detects SOF/EOF, forwards preamble/SFD, computes RX FCS, and uses unrolled CRC logic. |
| `hdr_stripper` | Strips fixed Ethernet/IPv4/UDP headers and aligns UDP payload words. |
| `field_aligner` | Extracts typed fields from static payload offsets in the first 24 payload bytes. |
| `sym_id_mapper` | Maps instrument IDs to symbol indexes through an off-path loaded direct-mapped tag table. |
| `risk_gate` | Applies off-path loaded price/quantity limits, global kill, symbol miss, and upstream error checks in parallel. |
| `pkt_formatter` | Emits a fixed Ethernet/IPv4/UDP outbound order frame with dynamic order fields and FCS. |
| `hft_engine` | Integrates the full raw PCS RX/TX pipeline in spec order and exposes RX FCS status as telemetry. |

Each leaf RTL block has a matching `rtl/*_assertions.sv` bind file.

## Verification

The repo is set up for Verilator. From a Linux/WSL-style shell with `verilator`,
`make`, and a C++ compiler installed:

```bash
make lint
make test
```

Useful direct flow commands:

```bash
scripts/run_verilator_flow.sh lint
scripts/run_verilator_flow.sh test
scripts/run_verilator_flow.sh all
scripts/run_verilator_flow.sh clean
```

The flow builds under `/tmp/hft_verilator_flow_<user>` by default because
Verilator-generated Makefiles can be awkward when the repository path contains
spaces. Override with:

```bash
BUILD_ROOT=/tmp/hft_build make test
```

Current verified state:

- RTL lint-only passes for all seven RTL modules, including `hft_engine`.
- Testbench lint-only passes for all smoke testbenches.
- Assertion bind lint-only passes with `--assert`.
- Executable smoke simulation is supported through `make test`. Smoke builds
  default to `JOBS=1` to avoid a Verilator 5.048 thread-pool shutdown failure
  observed with high parallelism; override with `JOBS=N make test` only on a
  stable local toolchain.

  <img width="1591" height="904" alt="image" src="https://github.com/user-attachments/assets/4e868c0c-a771-4054-868f-ff9ae6ca9ea8" />

## Current Timing Snapshot

The nominal integrated smoke path in `tb/tb_hft_engine.sv` records:

| Segment | Cycles | Time at 156.25 MHz |
| --- | ---: | ---: |
| `mac_sof` to `payload_sof` | 7 | 44.8 ns |
| `payload_sof` to `field_valid` | 3 | 19.2 ns |
| `field_valid` to `sym_valid` | 1 | 6.4 ns |
| `sym_valid` to risk decision | 1 | 6.4 ns |
| Risk decision to `tx_sof` | 1 | 6.4 ns |
| `mac_sof` to `tx_sof` | 13 | 83.2 ns |
| `tx_sof` to `tx_eof` | 7 | 44.8 ns |

The downstream decision path from `field_valid` to `tx_sof` is three cycles.
The larger front-end number is dominated by causal byte arrival for the fixed
headers and required payload fields.

## Known Spec Gaps

The current RTL preserves explicit `// SPEC_GAP:` comments where the original
specification or frozen interfaces are incomplete or contradictory:

- `hdr_stripper`: bad-length behavior is not numerically defined.
- `hdr_stripper`: the written two-cycle `rx_sof` to `payload_valid` budget
  conflicts with stripping an in-stream preamble plus 42 header bytes.
- `sym_id_mapper`: the spec calls for reset-time serial table load; the current
  branch uses direct off-path load pins while the exact serial protocol remains
  undefined.
- `risk_gate`: the spec calls for reset-loaded risk tables; the current branch
  uses direct off-path limit load pins plus a synchronously captured global kill
  input while the exact loader protocol remains undefined.
- `risk_gate`: simultaneous violation priority is unspecified, so the current
  implementation reports multi-cause kills as reserved reason `4'hE`.
- `pkt_formatter`: destination/source addressing and outbound order payload
  schema are unspecified.
- `hft_engine`: the top-level boundary keeps most derived MAC signals internal
  because `mac_shim` is instantiated inside the engine; RX FCS pass status is
  exposed as telemetry and does not gate cut-through trading.

## Development Notes

- Read `agents.md` and `HFT_RTL_System_Spec_Prompt.md` before changing RTL.
- Keep one `.sv` file per module and keep filenames matched to module names.
- Do not add pipeline stages, bus wrappers, or interface changes without an
  explicit spec decision.
- Do not use loops, latches, or blocking assignments in `always_ff` blocks.
- Generated VCD/build artifacts are intentionally ignored by Git.
