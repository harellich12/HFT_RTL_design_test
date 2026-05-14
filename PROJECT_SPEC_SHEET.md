# HFT RTL Project Spec Sheet

This document is a derived project spec sheet for the current RTL implementation.
It does not replace `HFT_RTL_System_Spec_Prompt.md`; that file remains the source
of truth for required architecture and coding rules. This sheet explains what each
spec is, where it came from, why it matters, and how the current project addresses it.

## Source Legend

| Source | Meaning |
| --- | --- |
| `HFT_RTL_System_Spec_Prompt.md` | Original architectural and module specification. |
| `agents.md` | Session rules, output rules, and protected-file constraints. |
| RTL implementation | Behavior currently implemented in `rtl/*.sv`. |
| Assertion bind | Behavior checked by `rtl/*_assertions.sv`. |
| Smoke test | Behavior checked by `tb/tb_*.sv`. |
| `SPEC_GAP` | An explicit implementation note where the original spec or frozen interface is incomplete or contradictory. |

## System Objective

| Spec | Source | Why It Matters | Current Status |
| --- | --- | --- | --- |
| Build a sub-microsecond tick-to-trade RTL datapath. | `HFT_RTL_System_Spec_Prompt.md`, preamble and timing summary. | The project is latency-driven; every extra cycle directly harms the target use case. | Full structural pipeline exists in `hft_engine`. |
| Deterministic, minimum-latency processing from raw wire bits to outbound order packet. | Original system spec. | HFT systems need bounded latency more than average-case throughput. | Pipeline is fixed order and single clock domain. |
| Prefer the lower-latency interpretation when the spec is ambiguous. | Original system spec and `agents.md`. | Prevents accidental conservative buffering or handshakes that add latency. | Ambiguities are marked with `// SPEC_GAP:` and implemented with minimum-latency behavior. |

## Architecture

| Spec | Source | Why It Matters | Current Status |
| --- | --- | --- | --- |
| Headless datapath: no CPU, OS, DMA, or firmware in the critical path. | Original architecture section. | Software intervention is orders of magnitude slower than the target pipeline. | RTL datapath is pure module-to-module logic. |
| Cut-through forwarding: begin processing before the inbound frame tail arrives. | Original architecture section. | Avoids full-frame receive latency. | Modules process streamed 64-bit words; no full-frame buffer exists. |
| No AXI/AHB/APB or bus wrapper on datapath signals. | Original interface and architecture sections; `agents.md`. | Handshake fabrics add arbitration and ready/valid timing paths. | Current datapath uses raw fixed signals only. |
| Single pipeline order: `mac_shim -> hdr_stripper -> field_aligner -> sym_id_mapper -> risk_gate -> pkt_formatter`. | Original module decomposition section. | Ensures deterministic stage ordering and latency accounting. | Implemented by `rtl/hft_engine.sv`. |
| No additional datapath hierarchy. | Original module decomposition section. | Prevents hidden buffering or pipeline stage insertion. | Top-level instantiates exactly the named datapath modules. |
| One clock domain: `clk_pcs`, 156.25 MHz. | Original coding standards and module interfaces. | Avoids CDC latency, metastability controls, and timing uncertainty. | All RTL modules use `clk_pcs`. |
| One active-low synchronous reset: `rst_n`. | Original coding standards. | Keeps reset behavior synthesizable and deterministic. | All implemented modules reset synchronously in `always_ff`. |

## Top-Level Interface

| Signal | Direction | Source | Why It Matters | Current Status |
| --- | --- | --- | --- | --- |
| `clk_pcs` | input | Original top-level interface. | Defines the sole datapath clock. | Present in `hft_engine`. |
| `rst_n` | input | Original top-level interface. | Defines deterministic reset. | Present in `hft_engine`. |
| `pcs_rxdata[63:0]` | input | Original raw PCS RX interface. | Carries 64-bit post-decode PCS data, earliest byte in low bits. | Present in `hft_engine`. |
| `pcs_rxctl[7:0]` | input | Original raw PCS RX interface. | Marks control characters such as terminate. | Present in `hft_engine`. |
| `pcs_rx_valid` | input | Original raw PCS RX interface. | Qualifies input word validity. | Present in `hft_engine`. |
| `pcs_block_lock` | input | Original raw PCS RX interface. | Prevents processing before PCS lock. | Present in `hft_engine`. |
| `pcs_txdata[63:0]` | output | Original raw PCS TX interface. | Carries outbound data words. | Present in `hft_engine`. |
| `pcs_txctl[7:0]` | output | Original raw PCS TX interface. | Marks outbound control bytes. | Present in `hft_engine`; formatter currently drives `8'h00`. |
| `pcs_tx_valid` | output | Original raw PCS TX interface. | Qualifies outbound words. | Present in `hft_engine`. |
| `pcs_tx_sof` | output | Original raw PCS TX interface. | Marks outbound frame start. | Present in `hft_engine`. |
| `pcs_tx_eof` | output | Original raw PCS TX interface. | Marks outbound frame end. | Present in `hft_engine`. |
| `pcs_tx_eof_bytes[2:0]` | output | Original raw PCS TX interface. | Marks final valid byte count. | Present in `hft_engine`; formatter emits full final word (`0`). |

## Top-Level Spec Gap

| Gap | Source | Why It Matters | Current Interpretation |
| --- | --- | --- | --- |
| The original top-level interface section lists derived MAC signals, but module decomposition requires `mac_shim` inside `hft_engine`. | Original spec sections 2.1 and 3. | The top boundary affects whether MAC decode is external or internal. | `hft_engine` exposes raw PCS RX/TX and keeps derived MAC signals internal. This is marked as `SPEC_GAP` in `hft_engine`. |

## Module Spec: `mac_shim`

| Spec | Source | Why It Matters | Current Status |
| --- | --- | --- | --- |
| Detect preamble/SFD word `0x55_55_55_55_55_55_55_D5` on wire order. | Original `mac_shim` section. | Defines exact start-of-frame boundary. | Implemented using constant `64'hD5_55_55_55_55_55_55_55`. |
| Assert `rx_sof` on the registered output cycle for SFD detection. | Original `mac_shim` latency requirement. | Downstream modules use SOF to start fixed-offset parsing. | Implemented with one output register stage. |
| Detect PCS terminate via nonzero `pcs_rxctl`. | Original `mac_shim` section. | Defines end-of-frame boundary. | Implemented as `eof_detect = pcs_rxctl != 8'h00` while frame active. |
| Produce `rx_eof_bytes`. | Original interface. | Downstream final-word handling depends on byte count. | Implemented by priority mapping first control byte to count. |
| Compute CRC-32/FCS and assert `mac_fcs_valid` with EOF if FCS matches. | Original `mac_shim` section. | Bad inbound frames must not be trusted. | Implemented with rolling four-byte FCS exclusion window. |
| Do not strip preamble. | Original `mac_shim` section. | Header stripper owns preamble/header removal. | `rx_data` forwards the input word. |
| Assertion bind coverage. | Original assertion requirement. | Catches SOF/EOF/valid consistency and alignment regressions. | `mac_shim_assertions.sv` exists and lints. |
| Smoke test coverage. | Current verification. | Confirms block-lock suppression, SOF forwarding, EOF byte count, good FCS, and bad FCS rejection. | `tb/tb_mac_shim.sv` is in the WSL flow. |

### `mac_shim` Notes

| Note | Source | Why It Matters |
| --- | --- | --- |
| CRC helper uses explicitly unrolled bit steps. | RTL implementation. | Satisfies the original rule prohibiting loops in synthesizable modules. |
| SOF/preamble word is admitted into the stream. | Original `mac_shim` section. | Preserves the requirement that `mac_shim` does not strip the preamble. |

## Module Spec: `hdr_stripper`

| Spec | Source | Why It Matters | Current Status |
| --- | --- | --- | --- |
| Strip preamble plus Ethernet, IPv4, and UDP headers. | Original `hdr_stripper` section. | Downstream field aligner must see UDP payload only. | Implemented with fixed stream position and 16-bit alignment shift. |
| Treat Ethernet+IPv4+UDP header as fixed 42 bytes. | Original `hdr_stripper` constraints. | Fixed offsets avoid variable parser latency. | Implemented with constants: 42 bytes, 5 full words, 2-byte remainder. |
| Assume fixed 20-byte IPv4 header; flag options as error. | Original `hdr_stripper` constraints. | Variable IP options would add variable parsing. | IHL check flags non-5 IHL. |
| Flag EtherType, IP protocol, and short frame errors. | Original `frame_err` description and constraints. | Bad frames must be killed without a flush handshake. | Implemented with same-cycle `frame_err_now` and sticky active error. |
| Produce `payload_sof`, `payload_valid`, `payload_eof`, and `payload_eof_bytes`. | Original interface. | Maintains streaming contract to field aligner. | Implemented. |
| Assertion bind coverage. | Original assertion requirement. | Checks valid/SOF/EOF consistency and no-gap behavior. | `hdr_stripper_assertions.sv` exists and lints. |
| Smoke test coverage. | Current verification. | Confirms fixed 42-byte strip, 2-byte payload alignment, EOF handling, EtherType/IHL/protocol errors, and short-frame error. | `tb/tb_hdr_stripper.sv` is in the WSL flow. |

### `hdr_stripper` Spec Gaps

| Gap | Source | Why It Matters | Current Interpretation |
| --- | --- | --- | --- |
| "Bad length" is not numerically defined. | Original `frame_err` requirement. | A precise length rule is needed for exhaustive verification. | Current RTL flags frames ending before any UDP payload byte exists. |
| 2-cycle `rx_sof` to `payload_valid` conflicts with stripping in-stream preamble plus 42 header bytes. | Original latency table versus stream layout. | The written budget is causally impossible if the header bytes must arrive first. | Current RTL emits payload on the first causal cycle after enough bytes arrive. |

## Module Spec: `field_aligner`

| Spec | Source | Why It Matters | Current Status |
| --- | --- | --- | --- |
| Extract `msg_type`, `instrument_id`, `price`, `quantity`, and `side`. | Original `field_aligner` interface. | Converts untyped payload bytes into trading fields. | Implemented for static offsets within the first 24 payload bytes. |
| Own all endian conversion. | Original `field_aligner` constraints. | Prevents repeated byte-swap logic downstream. | Implemented with static byte reversal. |
| Support static offset parameters. | Original constraints. | Allows compile-time layout changes without runtime parsing. | Implemented as compile-time part-selects over a three-word payload window. |
| Cross-word fields cost at most one extra cycle. | Original constraints. | Keeps field extraction bounded. | Implemented by capturing the first two payload words and completing when the last required static byte arrives. |
| Propagate upstream framing errors as `field_err`. | Original interface. | Bad frames must be killed downstream. | Implemented. |
| Assertion bind coverage. | Original assertion requirement. | Checks extraction correctness and error suppression. | `field_aligner_assertions.sv` exists and lints. |
| Smoke test coverage. | Current verification. | Confirms nominal and alternate-offset byte extraction. | `tb/tb_field_aligner.sv` lints with default and non-default parameter instances. |

## Module Spec: `sym_id_mapper`

| Spec | Source | Why It Matters | Current Status |
| --- | --- | --- | --- |
| Map 64-bit exchange instrument ID to compact internal symbol index. | Original `sym_id_mapper` section. | Risk and order logic should use small fixed-width indexes. | Implemented as identity lower-bit mapping. |
| Use direct-mapped lookup indexed by low bits. | Original constraints. | Direct mapping gives deterministic one-cycle lookup. | Placeholder uses low bits as index. |
| Detect miss/collision by tag mismatch. | Original constraints. | Prevents wrong-symbol risk checks. | Current placeholder treats any nonzero upper tag as miss. |
| Propagate `field_err` as `sym_err`. | Original interface. | Upstream parser errors must kill frame. | Implemented. |
| One-cycle latency from `field_valid` to `sym_valid`. | Original timing table. | Keeps pipeline budget fixed. | Implemented and asserted. |
| Assertion bind coverage. | Original assertion requirement. | Checks one-cycle valid, index, miss, and error behavior. | `sym_id_mapper_assertions.sv` exists and lints. |
| Smoke test coverage. | Current verification. | Confirms identity hit, tag miss, field error, and idle behavior. | `tb/tb_sym_id_mapper.sv` passes. |

### `sym_id_mapper` Spec Gap

| Gap | Source | Why It Matters | Current Interpretation |
| --- | --- | --- | --- |
| Spec requires reset-time serial table load, but module interface has no load pins. | Original constraints and RTL marker. | Real symbol tables need configuration. | Current RTL uses deterministic identity/tag placeholder until config interface is defined. |

## Module Spec: `risk_gate`

| Spec | Source | Why It Matters | Current Status |
| --- | --- | --- | --- |
| Evaluate price floor, price ceiling, quantity limit, kill switch, symbol miss, and upstream error. | Original `risk_gate` table. | Risk gate is the safety-critical block preventing bad orders. | Implemented with current constant stand-in limits and upstream flags. |
| Complete checks in parallel combinational logic and register outputs. | Original constraints. | Avoids priority-chain or iterative latency. | Implemented as parallel violation signals plus OR-masked reason. |
| `risk_kill` valid one cycle after `sym_valid`. | Original timing table. | Kill latency must be bounded. | Implemented and asserted. |
| `risk_pass` and `risk_kill` mutually exclusive. | Derived from risk gate interface and safety behavior. | Formatter must never see pass and kill together. | Asserted in `risk_gate_assertions.sv`. |
| Kill reason encoding follows original table. | Original risk check table. | Debug and downstream action depend on cause. | Implemented for single and OR-combined reasons; single-cause cases asserted. |
| Assertion bind coverage. | Original assertion requirement and safety priority. | Kill path needs stronger coverage than pass path. | `risk_gate_assertions.sv` exists and lints. |
| Smoke test coverage. | Current verification. | Confirms pass, floor, ceiling, quantity, miss, and upstream error. | `tb/tb_risk_gate.sv` passes. |

### `risk_gate` Spec Gaps

| Gap | Source | Why It Matters | Current Interpretation |
| --- | --- | --- | --- |
| Risk tables and global kill are required but absent from interface. | Original constraints and RTL marker. | Production risk limits must be configurable. | Current RTL uses constants: floor 10, ceiling 1,000,000, quantity max 1,000, global kill 0. |
| Simultaneous violation priority is unspecified. | Original risk table does not define priority. | Multiple violations can happen in one cycle. | Current RTL OR-masks reasons to avoid a priority chain. |

## Module Spec: `pkt_formatter`

| Spec | Source | Why It Matters | Current Status |
| --- | --- | --- | --- |
| Begin outbound frame no later than one cycle after `risk_pass`. | Original `pkt_formatter` constraints. | Final stage must not add avoidable latency. | Implemented and asserted. |
| Suppress all output on `risk_kill` and reset state within one cycle. | Original constraints. | Prevents partial or bad orders. | Implemented and asserted. |
| Use static outbound Ethernet/IP/UDP template. | Original constraints. | Static template avoids runtime header construction latency. | Implemented with fixed template words. |
| Substitute symbol, price, quantity, and side. | Original constraints. | Carries order data into outbound packet. | Implemented in 16-byte payload plus pad. |
| UDP checksum disabled. | Original constraints. | Avoids expensive checksum path. | Template uses UDP checksum field as zero. |
| Compute and append Ethernet FCS incrementally. | Original constraints. | Produces complete outbound frame without post-buffering. | Implemented. |
| Emit Ethernet minimum frame size. | Derived Ethernet requirement from formatter implementation review. | Prevents runt frames. | Implemented with two pad bytes before FCS. |
| Assertion bind coverage. | Original assertion requirement. | Checks launch, no-gap, kill suppression, and EOF behavior. | `pkt_formatter_assertions.sv` exists and lints. |
| Smoke test coverage. | Current verification. | Confirms launch, fields, FCS word, kill suppression, idle. | `tb/tb_pkt_formatter.sv` passes. |

### `pkt_formatter` Spec Gap

| Gap | Source | Why It Matters | Current Interpretation |
| --- | --- | --- | --- |
| Destination/source addressing and outbound order payload schema are not defined. | Original formatter section. | Real exchange/order target format must be precise. | Current RTL uses fixed placeholder Ethernet/IP/UDP template and a compact symbol/price/quantity/side payload. |

## Module Spec: `hft_engine`

| Spec | Source | Why It Matters | Current Status |
| --- | --- | --- | --- |
| Instantiate exactly the specified pipeline modules in order. | Original module decomposition. | Ensures no hidden datapath hierarchy or reorder. | Implemented. |
| Share `clk_pcs` and `rst_n` across all modules. | Original decomposition and coding standards. | Maintains single timing domain. | Implemented. |
| Align sideband fields across registered mapper and risk stages. | Derived from implemented module latencies. | Prevents `risk_pass` or formatter payload from using mismatched symbol/price/side. | Implemented with sideband registers in `hft_engine`. |
| Lint with all child RTL and assertion binds. | Current verification requirement. | Catches bind/instance integration issues. | Passes lint-only with `--assert`. |

## Timing Budget Sheet

| Stage | Trigger | Output | Original Budget | Current Notes |
| --- | --- | --- | --- | --- |
| `mac_shim` | Preamble/SFD detect | `rx_sof` | 1 cycle | Registered output stage. |
| `hdr_stripper` | `rx_sof` | `payload_valid` | 2 cycles | Marked `SPEC_GAP`; causal stream implementation emits after enough header bytes arrive. |
| `field_aligner` | Payload words | `field_valid` | 1-2 cycles | Current fixed layout asserts on third payload word for cross-word fields. |
| `sym_id_mapper` | `field_valid` | `sym_valid` | 1 cycle | Implemented and asserted. |
| `risk_gate` | `sym_valid` | `risk_pass` or `risk_kill` | 1 cycle | Implemented and asserted. |
| `pkt_formatter` | `risk_pass` | `pcs_tx_sof` | 1 cycle | Implemented and asserted. |

## Measured End-to-End Latency

Measured by `tb/tb_hft_engine.sv` on the nominal pass-path frame at 156.25 MHz:

| Segment | Measured Cycles | Measured Time | Why It Matters |
| --- | ---: | ---: | --- |
| `mac_sof` to `payload_sof` | 7 | 44.8 ns | Captures the causal cost of receiving and stripping the preamble plus fixed Ethernet/IP/UDP header before the first UDP payload word can be emitted. |
| `payload_sof` to `field_valid` | 3 | 19.2 ns | The current field set reaches through payload byte 22, so the aligner cannot present all fields until the third 64-bit payload word has arrived. |
| `field_valid` to `sym_valid` | 1 | 6.4 ns | Confirms the symbol mapping stage is at its specified one-cycle budget. |
| `sym_valid` to risk decision | 1 | 6.4 ns | Confirms the risk gate decision stage is at its specified one-cycle budget. |
| Risk decision to `tx_sof` | 1 | 6.4 ns | Confirms the formatter launches at its specified one-cycle budget after pass. |
| `mac_sof` to `tx_sof` | 13 | 83.2 ns | Current observed start-to-start latency for the integrated pipeline. This exceeds the original headline 7-cycle budget because the original budget conflicts with the byte arrival point of the required fields. |
| `tx_sof` to `tx_eof` | 7 | 44.8 ns | Confirms the formatter emits the complete minimum-size outbound frame in a fixed deterministic burst. |

Interpretation: the downstream decision path from `field_valid` to `tx_sof` is 3 cycles and already matches the per-stage RTL budgets. The larger `mac_sof` to `tx_sof` number is dominated by front-end byte arrival and fixed-offset parsing, not by avoidable buffering in the mapper, risk gate, or formatter.

## Verification Spec

| Requirement | Source | Why It Matters | Current Status |
| --- | --- | --- | --- |
| Per-module assertion bind files. | Original assertion section. | Keeps formal/simulation checks separate from synthesizable RTL. | Complete for all current RTL blocks. |
| Smoke tests for implemented high-risk/current blocks. | Engineering verification need. | Fast regression catches obvious behavioral breaks. | Existing tests cover `mac_shim`, `hdr_stripper`, `field_aligner`, `sym_id_mapper`, `risk_gate`, `pkt_formatter`, and top-level `hft_engine`. |
| WSL/Linux repeatable flow. | User request and toolchain constraints. | Avoids manual command drift and Windows Make path issues. | `Makefile` and `scripts/run_verilator_flow.sh` exist. |
| Build outside paths with spaces. | GNU Make/Verilator behavior observed during run. | Verilator generated Makefiles fail under repo path containing spaces. | Flow builds under `/tmp/hft_verilator_flow_$USER`. |

## WSL Commands

```bash
cd "/mnt/c/Users/harel/OneDrive/Desktop/AI Coding/HFT design"

make lint
make test
```

Optional:

```bash
make clean
make
BUILD_ROOT=/tmp/hft_build make test
```

Wave viewing:

```bash
gtkwave tb/field_aligner_smoke.vcd
gtkwave tb/mac_shim_smoke.vcd
gtkwave tb/hdr_stripper_smoke.vcd
gtkwave tb/sym_id_mapper_smoke.vcd
gtkwave tb/risk_gate_smoke.vcd
gtkwave tb/pkt_formatter_smoke.vcd
gtkwave tb/hft_engine_smoke.vcd
```

## Current Completion Status

| Area | Status |
| --- | --- |
| Main RTL modules | Complete for current frozen interfaces. |
| Top-level integration | Complete structurally and lint-clean. |
| Assertion binds | Complete for existing RTL modules. |
| Smoke tests | Present for `mac_shim`, `hdr_stripper`, `field_aligner`, `sym_id_mapper`, `risk_gate`, `pkt_formatter`, and top-level `hft_engine`. |
| WSL flow | Present and used successfully. |
| Spec gaps | Tracked and preserved. |
| Strict no-loop compliance | `mac_shim` CRC helper is unrolled; no loops are present in synthesizable RTL. |
| Quant/strategy layer | Not part of current source spec; proposed separately in `STRATEGY_CORE_PROPOSAL.md`. |

## Remaining Recommended Work

1. Review and approve or reject the proposed `strategy_core` insertion.
   - Source: current pipeline parses and risk-checks fields but has no actual quant/alpha decision block.
   - Why important: In production, risk should validate order intent produced by strategy logic, not raw market data fields.

2. Resolve configuration interface gaps.
   - Source: `sym_id_mapper` and `risk_gate` original specs require reset-time configuration not present in frozen interfaces.
   - Why important: Placeholder constants are not production trading configuration.
