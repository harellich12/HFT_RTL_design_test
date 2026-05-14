# Strategy Core Proposal

This document describes where the quant/algorithm layer fits in the HFT RTL
pipeline. It is a proposal, not an implemented RTL change. The current source
spec does not define a strategy module, and `agents.md` says not to refactor
pipeline boundaries without explicit instruction.

## Current Pipeline

The implemented pipeline is:

```text
PCS
-> mac_shim
-> hdr_stripper
-> field_aligner
-> sym_id_mapper
-> risk_gate
-> pkt_formatter
-> PCS
```

This pipeline parses inbound packets, extracts typed fields, maps the symbol,
checks risk, and formats an outbound order packet. It does not contain a real
alpha, signal, or trading-decision algorithm.

## Proposed Pipeline With Quant Logic

A realistic trading pipeline would insert a strategy decision block between
symbol mapping and risk:

```text
PCS
-> mac_shim
-> hdr_stripper
-> field_aligner
-> sym_id_mapper
-> strategy_core
-> risk_gate
-> pkt_formatter
-> PCS
```

The strategy core consumes normalized market data fields and emits an order
intent. The risk gate then validates that order intent before any outbound packet
is emitted.

## Why The Strategy Core Belongs Before Risk

| Reason | Why It Matters |
| --- | --- |
| Risk should check actual order intent. | The current `risk_gate` checks parsed input fields directly. In a real strategy, the order price/quantity/side may differ from the market data fields. |
| Keeps risk independent of alpha logic. | Risk remains a safety/compliance block, not a strategy block. |
| Keeps formatter simple. | `pkt_formatter` should serialize an approved order, not decide whether to trade. |
| Preserves deterministic latency accounting. | A strategy block can be assigned a fixed cycle budget and verified separately. |

## Proposed Module

```systemverilog
module strategy_core #(
    parameter int SYMBOL_ID_WIDTH = 10,  // Legal range: positive integer; changes symbol index width.
    parameter int PRICE_WIDTH     = 64,  // Legal range: positive integer; changes price datapath width.
    parameter int QTY_WIDTH       = 32   // Legal range: positive integer; changes quantity datapath width.
) (
    input  logic                         clk_pcs,
    input  logic                         rst_n,

    // Parsed and normalized market data
    input  logic [SYMBOL_ID_WIDTH-1:0]   symbol_idx,
    input  logic [15:0]                  msg_type,
    input  logic [PRICE_WIDTH-1:0]       market_price,
    input  logic [QTY_WIDTH-1:0]         market_quantity,
    input  logic [7:0]                   market_side,
    input  logic                         market_valid,
    input  logic                         market_err,

    // Order intent to risk gate
    output logic [SYMBOL_ID_WIDTH-1:0]   order_symbol_idx,
    output logic [PRICE_WIDTH-1:0]       order_price,
    output logic [QTY_WIDTH-1:0]         order_quantity,
    output logic [7:0]                   order_side,
    output logic                         order_valid,
    output logic                         order_err,
    output logic                         order_suppress
);
```

## Proposed Signal Meaning

| Signal | Meaning |
| --- | --- |
| `symbol_idx` | Internal symbol index from `sym_id_mapper`. |
| `msg_type` | Parsed feed message type. |
| `market_price` | Parsed market-data price. |
| `market_quantity` | Parsed visible/update quantity. |
| `market_side` | Parsed side, for example `8'h42` for buy or `8'h53` for sell. |
| `market_valid` | Input fields are valid this cycle. |
| `market_err` | Upstream parse/map error. |
| `order_symbol_idx` | Symbol for proposed order. Usually equals `symbol_idx`. |
| `order_price` | Strategy-selected order price. |
| `order_quantity` | Strategy-selected order quantity. |
| `order_side` | Strategy-selected order side. |
| `order_valid` | Strategy has produced an order intent. |
| `order_err` | Strategy detected an invalid input or internal condition. |
| `order_suppress` | Strategy intentionally chose not to trade. |

## Minimal First Strategy

A first deterministic strategy can be deliberately simple:

```text
if market_valid and no error:
    if msg_type is tradeable:
        emit order_valid
        order_symbol_idx = symbol_idx
        order_price      = market_price
        order_quantity   = fixed configured quantity
        order_side       = opposite or configured side
    else:
        order_suppress = 1
```

This is not a profitable strategy. It is a hardware integration strategy: it
proves that the decision slot exists and that risk/formatter operate on order
intent rather than raw parsed market fields.

## Latency Budget Options

| Option | Latency | Use Case | Tradeoff |
| --- | --- | --- | --- |
| Combinational decision, registered output | 1 cycle | First practical implementation. | Adds one stage to current end-to-end latency. |
| Pure combinational pass-through into risk | 0 extra registered cycles | Extreme latency target. | Creates a longer timing path from mapper through strategy into risk. |
| Multi-stage strategy | 2+ cycles | More complex alpha logic. | Violates the current 7-cycle target unless explicitly approved. |

Recommended first implementation: 1 cycle, registered output.

## Required Risk Gate Change

Current `risk_gate` input fields are named generically:

```text
symbol_idx
price
quantity
side
sym_valid
sym_miss
sym_err
```

With `strategy_core`, these should be driven by order intent:

```text
symbol_idx <- order_symbol_idx
price      <- order_price
quantity   <- order_quantity
side       <- order_side
sym_valid  <- order_valid
sym_err    <- order_err or upstream error
```

The risk gate should remain strategy-agnostic.

## Required Formatter Change

No interface change is required if `risk_gate` continues passing the approved
order fields into `pkt_formatter`. The formatter should never know whether an
order came from a simple strategy or a complex one.

## Configuration Questions

Before implementing `strategy_core`, define:

1. Which `msg_type` values are tradeable?
2. Should the strategy quote, take liquidity, cancel, or replace?
3. Is `order_side` same-side, opposite-side, or configured by symbol?
4. Is order quantity fixed, market-derived, or per-symbol configured?
5. How are strategy parameters loaded at reset?
6. Is suppress/no-trade represented by `order_valid = 0` or an explicit suppress flag?
7. What is the allowed latency budget?

## Verification Plan

| Test | Purpose |
| --- | --- |
| Nominal tradeable message emits order intent. | Confirms basic decision path. |
| Non-tradeable message suppresses order. | Confirms no false order. |
| Upstream error propagates to `order_err`. | Confirms bad inputs are killed. |
| Fixed quantity/config path works. | Confirms deterministic order sizing. |
| Back-to-back market updates. | Confirms no hidden stalls or state bleed. |
| Integration with `risk_gate`. | Confirms risk checks order intent, not stale market fields. |

## Assertion Plan

| Assertion | Purpose |
| --- | --- |
| `market_valid` produces either `order_valid`, `order_suppress`, or `order_err` within the budget. | Ensures deterministic decision latency. |
| `order_valid` and `order_suppress` are mutually exclusive. | Prevents ambiguous strategy output. |
| `order_err` suppresses valid orders. | Prevents malformed order intent. |
| Output fields are stable when `order_valid` asserts. | Protects risk gate input stability. |

## Integration Warning

Adding `strategy_core` changes the original module decomposition and adds at
least one conceptual stage. It should be treated as an architectural change and
approved before modifying `hft_engine`.
