# Block Context Handoff

This file is the lightweight session-to-session handoff for block-level RTL work.
It does not replace `agents.md` or `HFT_RTL_System_Spec_Prompt.md`; read those first
before changing RTL.

## Project Goal

Implement the headless, cut-through HFT trading engine pipeline (spec order
plus the approved strategy stage):

```text
PCS -> mac_shim -> hdr_stripper -> field_aligner -> sym_id_mapper -> strategy_core -> risk_gate -> pkt_formatter -> PCS
```

The decision path after all fields are available is four cycles
(`field_valid -> sym_valid -> order_valid -> risk decision -> tx_sof`);
smoke-measured `mac_sof` to `tx_sof` is 14 cycles (89.6 ns). Do not add
pipeline stages or interface signals without explicit approval; the strategy
stage is the one approved addition (see Architecture Decisions below).

## Current Block Status

| Block | File | Status | Verification |
| --- | --- | --- | --- |
| `mac_shim` | `rtl/mac_shim.sv` | Frame boundary decode, exact-count `rx_eof_bytes` (0..7), IEEE 802.3 FCS check (wire order verified against zlib known answers), unrolled CRC. `SPEC_GAP`s: eof encoding versus spec, lane-0-only preamble detection. | Lint + assertions pass. `tb_mac_shim` covers block-lock, SOF/EOF, byte counts, good/bad FCS with a hardcoded IEEE known-answer vector. |
| `hdr_stripper` | `rtl/hdr_stripper.sv` | Fixed 42-byte strip and 2-byte realignment; consumes exact-count eof bytes; emits `[0=8]`-encoded `payload_eof_bytes`. `SPEC_GAP`s: bad-length definition, 2-cycle budget conflict. | Lint + assertions pass. `tb_hdr_stripper` covers strip/alignment, header errors, short frame, word-boundary EOF, and flush-tail cases. |
| `field_aligner` | `rtl/field_aligner.sv` | Static-offset extraction with byte-granular availability (truncated payloads raise `field_err`, never garbage fields); saturating word counter. | Lint + assertions pass. `tb_field_aligner` covers default and alternate offsets, truncated payloads, and long payloads. |
| `sym_id_mapper` | `rtl/sym_id_mapper.sv` | Direct-mapped tag table with post-reset init sweep + `cfg_ready`; misses deterministic from reset. `SPEC_GAP`: serial loader protocol undefined. | Lint + assertions (config-mirrored) pass. `tb_sym_id_mapper` covers init sweep, hit, tag miss, unconfigured entry, and error propagation. |
| `strategy_core` | `rtl/strategy_core.sv` | Stage-1 take-liquidity decision: configured tradeable msg_type, per-symbol enable/side-policy/qty table with init sweep + `cfg_ready`. Exactly one of order/suppress/err per market update. | Lint + assertions (config-mirrored) pass. `tb_strategy_core` compares every decision against the DPI golden model (`verif/strategy_ref_model.cpp`), directed + seeded random. |
| `risk_gate` | `rtl/risk_gate.sv` | Parallel checks on order intent; init sweep writes fail-safe limits; two-stage synchronizer on `risk_global_kill` (2-cycle reaction); multi-cause kills encode `4'hE`. `SPEC_GAP`: serial loader protocol undefined. | Lint + assertions (golden-model mirror incl. sweep and synchronizer) pass. `tb_risk_gate` covers pass, every single-cause kill, multi-cause, init sweep, and unconfigured symbols. |
| `pkt_formatter` | `rtl/pkt_formatter.sv` | Complete raw-PCS burst: preamble/SFD, template + order fields, IEEE FCS, terminate control word (10 words). Kill gates launch only; in-flight frames never truncate; `tx_abort` stomps the FCS; drop/stomp counters. `SPEC_GAP`s: addressing/payload schema, kill-semantics reinterpretation. | Lint + assertions pass (fixed frame length, framing, kill/abort behavior). `tb_pkt_formatter` checks every word incl. FCS known answers, busy drop, stomp, kill-mid-frame. |
| `hft_engine` | `rtl/hft_engine.sv` | Integrates all seven stages with sideband alignment; late-FCS policy (suppress pending launch or stomp in-flight order); synchronized global kill on the stomp path; exposes `cfg_ready`, kill reason, risk error, drop/stomp counters. `SPEC_GAP`: top-level boundary versus spec section 2.1. | Lint passes with all children and binds. `tb_hft_engine`: real-FCS frames, corrupt-FCS suppression, back-to-back gap-1 and zero-gap throughput. `tb_hft_engine_random`: fault-injected random frames scored word-for-word against a frame-level predictor. |
| Assertion bind files | `rtl/*_assertions.sv` | Complete for all eight RTL modules; risk and strategy binds carry full config-mirrored golden models. | All pass standalone, in leaf testbenches, and through `hft_engine`, in every simulation. |

## Verification Snapshot

The single source of truth is the flow (run inside WSL or on CI):

```bash
make lint    # 17 lint targets: RTL, assertion binds, all testbenches
make test    # 9 simulations, assertions enabled
make waves MOD=<block>
```

CI (`.github/workflows/ci.yml`) runs both targets on every push and pull
request. The verification methodology (golden models, DPI comparison, the
randomized engine scoreboard) is documented in `verif/README.md`.

Latest smoke-measured latency from `tb_hft_engine`:

| Segment | Cycles | Time |
| --- | ---: | ---: |
| `mac_sof` to `payload_sof` | 7 | 44.8 ns |
| `payload_sof` to `field_valid` | 3 | 19.2 ns |
| `field_valid` to `sym_valid` | 1 | 6.4 ns |
| `sym_valid` to risk decision (through `strategy_core`) | 2 | 12.8 ns |
| Risk decision to `tx_sof` | 1 | 6.4 ns |
| `mac_sof` to `tx_sof` | 14 | 89.6 ns |
| `tx_sof` to `tx_eof` | 9 | 57.6 ns |

## Known Spec Gaps To Preserve

Existing `// SPEC_GAP:` markers are intentional and should remain until the spec
or interfaces are clarified:

- `mac_shim`: the spec's `[0=8, 1..7=N]` EOF bytecount encoding cannot represent a
  terminate in lane 0 at the raw PCS boundary; `rx_eof_bytes` is the exact
  EOF-word data byte count (0..7) and `hdr_stripper` consumes the same encoding.
- `mac_shim`: SOF detection only recognizes lane-0 (word-aligned) preambles;
  10GBASE-R lane-4 frame starts are not yet supported. Open item before
  live-wire bring-up.
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

## Audit Hardening + Engine Scoreboard (2026-07-12)

From the full-project audit:

1. `risk_global_kill` now crosses a two-stage synchronizer in both
   `risk_gate` (decision path) and `hft_engine` (stomp path); the assertion
   mirror matches. Kill reaction from the pin is two cycles. The pin is
   asynchronous; a single flop was a metastability liability on the most
   safety-critical input.
2. `mac_shim` lane-0-only preamble detection recorded as a `SPEC_GAP`
   (10GBASE-R lane-4 frame starts are not recognized); open item before
   live-wire bring-up.
3. Stale docs fixed: `STRATEGY_CORE_PROPOSAL.md` carries an implemented
   status banner; `PROJECT_SPEC_SHEET.md` gained the `strategy_core` module
   section, the new top-level ports, and the 14-cycle measured latency.
4. `tb_hft_engine_random`: randomized full-engine scoreboard. A deterministic
   xorshift32 generator builds whole frames (header faults, truncation, tag
   misses, unmapped symbols, non-tradeable msg_types, price/qty violations,
   junk sides, corrupt FCS, short/long payloads, random gaps); a frame-level
   predictor - using the same DPI golden model as tb_strategy_core for the
   strategy decision - predicts every launch and the EXACT ten TX words
   including FCS (inverted when a late bad inbound FCS stomps the order).
   A directed epilogue pins the stomp, the fail-safe suppression eating the
   next launch, and the suppression clearing after one decision. Also the
   audit noted the 4'hF upstream-error kill path is unreachable end-to-end
   (field_valid and field_err are mutually exclusive by construction), so
   the scoreboard never predicts it; error frames die by valid-suppression.

## Next Recommended Work

1. Resolve or formalize the formatter packet schema (addressing + payload).
2. Strategy stage 2 per `STRATEGY_CORE_PROPOSAL.md` staging: per-symbol
   market state (best bid/offer, last trade) updated from inbound data.
3. Serial config loader: deferred until FPGA host interface is chosen.
4. Verification uplift remainder: formal on the risk_gate kill path
   (SymbiYosys), coverage collection, spec v2 decision (owner: project lead).
5. FPGA milestone: Vivado STA on the two 1024-deep read-to-decide paths
   (risk_gate and strategy_core), lane-4 preamble support.

## Session Checklist

Before editing any RTL in a future block session:

1. Read `agents.md`.
2. Read `HFT_RTL_System_Spec_Prompt.md`.
3. Read this file.
4. Work on one module only unless explicitly told otherwise.
5. Preserve module interfaces and latency boundaries unless explicitly approved.
6. Add or update the block's smoke test only when asked, or when needed to verify a behavior change.
