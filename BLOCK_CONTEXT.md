# Block Context Handoff

This file is the lightweight session-to-session handoff for block-level RTL work.
It does not replace `agents.md` or `HFT_RTL_System_Spec_Prompt.md`; read those first
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
| `sym_id_mapper` | `rtl/sym_id_mapper.sv` | Implemented with a direct-mapped tag table loaded by off-path config pins. The lower instrument bits select the symbol index; disabled entries or tag mismatches assert `sym_miss`. A `SPEC_GAP` remains because the exact serial reset-load protocol is undefined. | Verilator lint-only passes. `tb/tb_sym_id_mapper.sv` lint-only passes. `rtl/sym_id_mapper_assertions.sv` lint-only passes with assertions enabled. Existing VCD: `tb/sym_id_mapper_smoke.vcd`. |
| `risk_gate` | `rtl/risk_gate.sv` | Implemented with off-path loaded floor/ceiling/quantity tables and a synchronously captured `risk_global_kill` input. Single-cause kill reasons use the spec codes; simultaneous violations encode as reserved `4'hE` to avoid reason aliasing. A `SPEC_GAP` remains because the exact serial reset-load protocol is undefined. | Verilator lint-only passes. `tb/tb_risk_gate.sv` lint-only passes. `rtl/risk_gate_assertions.sv` lint-only passes with assertions enabled. Existing VCD: `tb/risk_gate_smoke.vcd`. |
| `pkt_formatter` | `rtl/pkt_formatter.sv` | Implemented with a fixed Ethernet/IPv4/UDP template, 16-byte order payload, two Ethernet pad bytes, incremental FCS generation, one-cycle launch from `risk_pass`, and synchronous suppression on `risk_kill`. Has a `SPEC_GAP` note because the spec does not define addressing or payload schema. | Verilator lint-only passes. `tb/tb_pkt_formatter.sv` lint-only passes. `rtl/pkt_formatter_assertions.sv` lint-only passes with assertions enabled. Executable smoke flow is covered by `make test`. |
| `hft_engine` | `rtl/hft_engine.sv` | Implemented as the top-level raw PCS RX/TX wrapper. Instantiates `mac_shim`, `hdr_stripper`, `field_aligner`, `sym_id_mapper`, `risk_gate`, and `pkt_formatter` in spec order. Includes sideband alignment registers for symbol/price/quantity/side across `sym_id_mapper` and `risk_gate` registered latencies. Exposes `rx_mac_fcs_valid` as telemetry without gating the cut-through trade path. Has a `SPEC_GAP` note because the spec lists derived MAC signals at the top-level boundary while also requiring `mac_shim` inside the top. | Verilator lint-only passes with all child RTL. `tb/tb_hft_engine.sv` lint-only passes and is wired into `make test`. |
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
- A Linux/WSL flow now exists:
  - `Makefile`
  - `scripts/run_verilator_flow.sh`
  - Run `make`, `make lint`, `make test`, or `make clean` from the repo root inside WSL.
  - `make test` builds under `/tmp/hft_verilator_flow_<user>` by default because GNU Make/Verilator cannot build inside repo paths containing spaces.
  - Verilator binary builds default to `JOBS=1` to avoid the Verilator 5.048 internal thread-pool abort observed with `-j 12`; override with `JOBS=N` only if the local toolchain is stable.

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

- `mac_shim`: the spec's `[0=8, 1..7=N]` EOF bytecount encoding cannot represent a
  terminate in lane 0 at the raw PCS boundary; `rx_eof_bytes` is the exact
  EOF-word data byte count (0..7) and `hdr_stripper` consumes the same encoding.
- `hdr_stripper`: numeric definition of bad length.
- `hdr_stripper`: causal conflict between stripping preamble/header bytes and the written 2-cycle `rx_sof` to `payload_valid` budget.
- `sym_id_mapper`: serial table load required by spec; current branch uses direct off-path load pins plus a post-reset init sweep (`cfg_ready` when done) while the serial protocol remains undefined.
- `risk_gate`: serial risk table load required by spec; current branch uses direct off-path load pins, a post-reset fail-safe init sweep (`cfg_ready` when done), and a global kill input while the serial protocol remains undefined.
- `risk_gate`: simultaneous violation priority is unspecified; current RTL reports multi-cause kills as `4'hE`.
- `pkt_formatter`: destination/source addressing and outbound order payload schema are unspecified.
- `hft_engine`: top-level boundary keeps most derived MAC signals internal because `mac_shim` is instantiated inside the engine; FCS status is exposed as telemetry.

## Phase 1 Hardening (2026-07-08)

Correctness fixes landed after a full-project review; all lint and smoke tests pass:

1. FCS wire order in `mac_shim` and `pkt_formatter` corrected to IEEE 802.3
   (bit-reversed CRC bytes, MSB byte first). Verified against independent
   `zlib.crc32` known-answer vectors hardcoded in `tb_mac_shim` and
   `tb_pkt_formatter`. The old mapping was self-consistent but rejected every
   real-world frame and emitted frames a real MAC would drop.
2. `rx_eof_bytes` contract unified: exact EOF-word data byte count (0..7).
   `hdr_stripper` previously decoded 0 as 8 valid bytes and marked garbage
   bytes valid on frames ending at a word boundary.
3. `field_aligner` now takes `payload_eof_bytes` and checks byte-granular field
   availability, so truncated payloads raise `field_err` instead of validating
   garbage fields; the payload word counter saturates instead of wrapping on
   long payloads.
4. `sym_id_mapper` and `risk_gate` run a post-reset init sweep (one entry per
   cycle) so no table cell is ever read undefined; both expose `cfg_ready`
   (ANDed at `hft_engine` top). Unconfigured symbols deterministically miss/kill.
5. `.gitattributes` forces LF on `Makefile`/`*.sh` so the WSL flow works from a
   Windows clone with `core.autocrlf=true`.

All changes are latency-neutral: the smoke-measured pipeline is unchanged
(13 cycles `mac_sof` to `tx_sof`, 3-cycle decision path).

## Architecture Decisions (2026-07-08)

Recorded from review discussion; these are settled unless explicitly reopened:

| Decision | Choice | Rationale |
| --- | --- | --- |
| TX wire framing ownership | `pkt_formatter` emits full raw-PCS framing itself (preamble/SFD word, terminate control word). No separate `tx_shim`, no external TX MAC assumption. | Keeps the raw-PCS boundary symmetric with `mac_shim`, keeps module count per spec, zero decision-latency cost (framing words land after launch). |
| In-flight kill policy | Complete in-flight approved frames; kill gates new launches only. Late inbound FCS failure or global kill invalidates an in-flight order by FCS stomp (inverted outbound FCS). | "Philosophy 2": never truncate (illegal runt), never delay launch waiting for FCS (kills cut-through). Residual risk: an order fully transmitted before the bad-FCS verdict cannot be recalled. |
| Config loading | Direct off-path pins + init sweep + `cfg_ready` stay. Serial loader deferred until the FPGA bring-up defines the real host-side programming interface. | Avoid inventing a loader protocol the spec does not define and the target platform may contradict. |
| Strategy core | Separate later track. Production strategy will be true RTL; a C++ reference model is for verification only (DPI checker), not the datapath. | See STRATEGY_CORE_PROPOSAL.md staging. |

## Phase 2 Hardening (2026-07-08)

TX wire legality and kill-path safety landed; all lint and smoke tests pass:

1. `pkt_formatter` emits a complete 10-word raw-PCS burst: preamble/SFD word,
   five header words, two order-field words, IEEE FCS word, terminate control
   word (`pcs_txctl = 8'hFF`, /T/ in lane 0). The TX stream is now a legal
   input for the design's own RX conventions. `tx_sof` marks the preamble word
   and still lands one cycle after `risk_pass`; `tx_sof` to `tx_eof` grew from
   7 to 9 cycles (framing words only, decision path unchanged at 13 cycles).
2. Kill semantics fixed: `risk_kill` gates new launches only; an in-flight
   frame is never truncated (previously any kill mid-frame produced an illegal
   partial frame on the wire). Documented as a formatter `SPEC_GAP`.
3. FCS stomp: new `tx_abort` input inverts the outbound FCS of the in-flight
   frame so the receiving MAC drops it. `hft_engine` drives it on global kill
   and on late inbound FCS failure when the frame's decision already launched.
4. Late-FCS launch suppression: when a bad inbound FCS arrives before the
   frame's risk decision (short frames - the common case), `hft_engine` masks
   that decision's `risk_pass` so the bad order never launches. Verified at
   top level with a corrupt-FCS frame: decision fires, no TX frame appears.
5. Telemetry: `risk_kill_reason`, `risk_err`, `tx_launch_drops` (busy-drop
   counter), and `tx_stomps` are now top-level outputs.
6. `tb_hft_engine` now sends frames with real IEEE FCS bytes (zlib-verified
   known answers) plus a corrupt-FCS suppression case; `tb_pkt_formatter`
   covers busy re-launch drop, mid-frame abort/stomp, kill-mid-frame
   non-truncation, and kill/abort at idle.
7. `make waves` (`MOD=<block>`) opens a smoke VCD in gtkwave.

Known conservative corners (documented in RTL comments, revisit with OMS work):

- A bad-FCS frame that dies before any risk decision leaves the launch
  suppression armed for the next decision (drops one good order; fail-safe).
- If a launch was dropped while an older frame was transmitting, a late FCS
  abort for the dropped frame stomps the older in-flight frame (fail-safe).

Proper fix for both requires per-frame IDs, which arrives with the order
manager in the strategy track.

## Phase 3 Start (2026-07-08)

1. GitHub Actions CI (`.github/workflows/ci.yml`): `make lint` + `make test`
   on ubuntu-24.04 (Verilator 5.020, matching WSL) for every push/PR.
2. Back-to-back frame coverage in `tb_hft_engine`: a gap-1 pair and a
   zero-gap pair both launch all orders. Measured finding: the 10-word TX
   burst is exactly rate-matched to the 10-word minimum inbound frame, so
   consecutive TX bursts butt-join and the engine sustains minimum-size
   frames at full line rate with zero drops. `tx_launch_drops` can only
   trigger if TX frames grow longer than the smallest inbound spacing
   (e.g., a future larger order template), which is exactly what the
   counter is there to catch.

## FPGA Synthesis Probe (2026-07-09)

Yosys 0.66 `synth_xilinx` (7-series, via sv2v because yosys' SV frontend does
not support `return` in functions), whole `hft_engine`, default parameters:

| Module | Logic LUTs | FFs | RAM64M (LUTRAM) |
| --- | ---: | ---: | ---: |
| `risk_gate` | 1269 | 19 | 880 |
| `sym_id_mapper` | 441 | 24 | 304 |
| `mac_shim` | 1059 | 139 | 0 |
| `pkt_formatter` | 698 | 251 | 0 |
| `field_aligner` | 201 | 318 | 0 |
| `hdr_stripper` | 120 | 70 | 0 |
| Total | ~3.8k | ~1.0k | 1184 (~4.7k LUTRAM LUTs) |

Findings:

- Total footprint ~8.5k LUTs (logic + LUTRAM); fits even an Artix-7 35T with
  room to spare, negligible on any transceiver-bearing part.
- Zero BRAM inferred: the async-read tables map to distributed RAM, which
  preserves the 1-cycle lookup budget. Keep this structure; do not convert to
  BRAM (registered read would cost a pipeline cycle per lookup stage).
- Timing risk to verify in vendor STA at the FPGA milestone: the risk_gate
  single-cycle path LUTRAM read -> 16:1 mux tree -> 64-bit compares -> kill
  reduction at 6.4 ns. yosys gives no timing; Vivado will.
- The unrolled CRC (mac_shim ~1.1k LUTs, pkt_formatter ~0.7k) is the largest
  pure-logic block but registered-output only; no concern.
- Strategy stage 1 param table (~35b x 1024) would add roughly 200 RAM64M.

## Strategy Stage 1 (2026-07-12)

`strategy_core` implemented per the approved answer sheet and inserted between
`sym_id_mapper` and `risk_gate`; risk now validates order intent:

1. Decision policy: take liquidity only; one configured tradeable `msg_type`
   register; per-symbol `{enable, side_policy[1:0], qty}` parameter table with
   the standard init sweep + `cfg_ready` (ANDed into the top-level pin). Side
   policies: same / opposite / fixed-buy / fixed-sell; a side-dependent policy
   with an unrecognized market side suppresses rather than guessing.
2. Determinism contract (asserted): every `market_valid` resolves to exactly
   one of `order_valid` / `order_suppress` / `order_err` one cycle later.
3. Latency: +1 cycle as approved; smoke-measured `mac_sof -> tx_sof` is now
   14 cycles (89.6 ns); `tx_sof -> tx_eof` unchanged at 9. Zero-gap
   back-to-back frames still butt-join on TX (launch frees in time).
4. hft_engine changes: `msg_type` sideband captured at `field_valid`;
   `sym_miss` delayed one cycle to pair with the order-intent cycle; risk
   sidebands capture from `order_*`; the late-FCS bookkeeping treats
   `order_suppress` as a resolution (a suppressed frame consumes the
   suppression window like a risk decision would).
5. Verification pattern for the whole strategy track established:
   `verif/strategy_ref_model.cpp` is the bit-accurate C++ golden model,
   compiled into `tb_strategy_core` via DPI and compared on every decision
   cycle - directed cases plus a deterministic xorshift32 random stream
   (~315 checked cycles). The RTL and the model must change together.

## Next Recommended Work

1. Resolve or formalize the formatter packet schema (addressing + payload).
2. Strategy stage 2 per `STRATEGY_CORE_PROPOSAL.md` staging: per-symbol
   market state (best bid/offer, last trade) updated from inbound data.
3. Serial config loader: deferred until FPGA host interface is chosen.
4. Verification uplift (Phase 3 remainder): randomized frames + scoreboard at
   the engine top, formal on risk_gate kill path, coverage.

## Session Checklist

Before editing any RTL in a future block session:

1. Read `agents.md`.
2. Read `HFT_RTL_System_Spec_Prompt.md`.
3. Read this file.
4. Work on one module only unless explicitly told otherwise.
5. Preserve module interfaces and latency boundaries unless explicitly approved.
6. Add or update the block's smoke test only when asked, or when needed to verify a behavior change.
