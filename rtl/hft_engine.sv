// Module     : hft_engine
// Description: Top-level cut-through HFT engine pipeline integration
// Latency    : 8 cycles best case (spec 7 plus the approved strategy stage)
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
//
// Pipeline role:
// - Instantiates the spec-defined datapath modules in the required order,
//   plus the approved strategy_core stage between mapper and risk so the
//   risk gate validates order intent rather than raw market fields.
// - Keeps all datapath signals in the single PCS clock domain.
// - Aligns extracted sideband fields with registered symbol, strategy, and
//   risk decisions.
module hft_engine #(
    parameter int SYMBOL_TABLE_DEPTH = 1024,  // Legal range: power of 2; changes mapper/risk table depth.
    parameter int SYMBOL_ID_WIDTH    = 10,    // Legal range: log2(SYMBOL_TABLE_DEPTH); changes symbol index width.
    parameter int PRICE_WIDTH        = 64,    // Legal range: positive integer; changes price sideband width.
    parameter int QTY_WIDTH          = 32     // Legal range: positive integer; changes quantity sideband width.
) (
    input  logic        clk_pcs,
    input  logic        rst_n,

    // Raw PCS RX
    input  logic [63:0] pcs_rxdata,
    input  logic [7:0]  pcs_rxctl,
    input  logic        pcs_rx_valid,
    input  logic        pcs_block_lock,

    // RX telemetry
    output logic        rx_mac_fcs_valid,

    // Off-path configuration
    input  logic [SYMBOL_ID_WIDTH-1:0]    sym_cfg_symbol_idx,
    input  logic [64-SYMBOL_ID_WIDTH-1:0] sym_cfg_instrument_tag,
    input  logic                          sym_cfg_entry_valid,
    input  logic                          sym_cfg_valid,
    input  logic [SYMBOL_ID_WIDTH-1:0]    risk_cfg_symbol_idx,
    input  logic [PRICE_WIDTH-1:0]        risk_cfg_price_floor,
    input  logic [PRICE_WIDTH-1:0]        risk_cfg_price_ceil,
    input  logic [QTY_WIDTH-1:0]          risk_cfg_qty_max,
    input  logic                          risk_cfg_valid,
    input  logic [15:0]                   strat_cfg_msg_type,
    input  logic                          strat_cfg_msg_type_valid,
    input  logic [SYMBOL_ID_WIDTH-1:0]    strat_cfg_symbol_idx,
    input  logic                          strat_cfg_entry_enable,
    input  logic [1:0]                    strat_cfg_side_policy,
    input  logic [QTY_WIDTH-1:0]          strat_cfg_qty,
    input  logic                          strat_cfg_valid,
    input  logic                          risk_global_kill,
    // High once both post-reset table init sweeps finish; load config after this.
    output logic                          cfg_ready,

    // Risk/TX telemetry: kill reason and error flag from risk_gate, plus
    // formatter counts of dropped launches and FCS-stomped frames.
    output logic [3:0]  risk_kill_reason,
    output logic        risk_err,
    output logic [15:0] tx_launch_drops,
    output logic [15:0] tx_stomps,

    // Raw PCS TX
    output logic [63:0] pcs_txdata,
    output logic [7:0]  pcs_txctl,
    output logic        pcs_tx_valid,
    output logic        pcs_tx_sof,
    output logic        pcs_tx_eof,
    output logic [2:0]  pcs_tx_eof_bytes
);

    logic [63:0] mac_rx_data;
    logic        mac_rx_valid;
    logic        mac_rx_sof;
    logic        mac_rx_eof;
    logic [2:0]  mac_rx_eof_bytes;

    logic [63:0] payload_data;
    logic        payload_valid;
    logic        payload_sof;
    logic        payload_eof;
    logic [2:0]  payload_eof_bytes;
    logic        frame_err;
    logic        sym_cfg_ready;
    logic        risk_cfg_ready;

    logic [63:0] instrument_id;
    logic [15:0]            field_msg_type;
    logic [PRICE_WIDTH-1:0] field_price;
    logic [QTY_WIDTH-1:0]   field_quantity;
    logic [7:0]             field_side;
    logic                   field_valid;
    logic                   field_err;

    logic [15:0]            sym_stage_msg_type_r;
    logic [PRICE_WIDTH-1:0] sym_stage_price_r;
    logic [QTY_WIDTH-1:0]   sym_stage_quantity_r;
    logic [7:0]             sym_stage_side_r;

    logic [SYMBOL_ID_WIDTH-1:0] symbol_idx;
    logic                       sym_valid;
    logic                       sym_miss;
    logic                       sym_err;

    logic [SYMBOL_ID_WIDTH-1:0] order_symbol_idx;
    logic [PRICE_WIDTH-1:0]     order_price;
    logic [QTY_WIDTH-1:0]       order_quantity;
    logic [7:0]                 order_side;
    logic                       order_valid;
    logic                       order_err;
    logic                       order_suppress;
    logic                       strat_stage_sym_miss_r;
    logic                       strat_cfg_ready;
    logic                       risk_in_valid;

    logic [PRICE_WIDTH-1:0] risk_stage_price_r;
    logic [QTY_WIDTH-1:0]   risk_stage_quantity_r;
    logic [7:0]             risk_stage_side_r;
    logic [SYMBOL_ID_WIDTH-1:0] risk_stage_symbol_idx_r;
    logic                   risk_pass;
    logic                   risk_kill;

    // Late-FCS/global-kill handling. A bad inbound FCS either suppresses the
    // pending launch (frame's risk decision not yet made: short frames) or
    // aborts the frame already on the wire via FCS stomp (decision already
    // made: long frames). Global kill stomps any frame in flight.
    logic                   global_kill_meta_r;
    logic                   global_kill_r;
    logic                   decision_done_r;
    logic                   launch_suppress_r;
    logic                   rx_fcs_bad;
    logic                   risk_decision;
    logic                   launch_suppress_now;
    logic                   fmt_risk_pass;
    logic                   tx_abort;

    assign cfg_ready = sym_cfg_ready && risk_cfg_ready && strat_cfg_ready;

    always_comb begin
        rx_fcs_bad    = mac_rx_eof && !rx_mac_fcs_valid;
        // A frame's intent is resolved by a risk decision or by the strategy
        // deciding not to trade; either consumes the late-FCS bookkeeping.
        risk_decision = risk_pass || risk_kill || order_suppress;
        risk_in_valid = order_valid || order_err;

        // Suppress combinationally so a bad EOF coinciding with the decision
        // cycle still blocks that launch instead of leaking to the next frame.
        launch_suppress_now = launch_suppress_r
                           || (rx_fcs_bad && !decision_done_r);
        fmt_risk_pass = risk_pass && !launch_suppress_now;

        // Abort targets the frame in flight only when the bad frame's own
        // decision already happened; otherwise the suppression path owns it.
        // Known conservative corner: if that launch was dropped while another
        // frame was transmitting, the stomp hits the older frame (fail-safe).
        tx_abort = global_kill_r || (rx_fcs_bad && decision_done_r);
    end

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            global_kill_meta_r <= 1'b0;
            global_kill_r     <= 1'b0;
            decision_done_r   <= 1'b0;
            launch_suppress_r <= 1'b0;
        end else begin
            // Two-stage synchronizer: risk_global_kill is asynchronous to
            // clk_pcs and feeds the FCS-stomp abort path.
            global_kill_meta_r <= risk_global_kill;
            global_kill_r      <= global_kill_meta_r;

            // Decisions are strictly in-order, one per parsed frame, so the
            // flag cleanly tracks whether the current inbound frame's risk
            // decision has already been produced.
            if (mac_rx_sof) begin
                decision_done_r <= 1'b0;
            end else if (risk_decision) begin
                decision_done_r <= 1'b1;
            end

            // Clear-on-decision wins: the masked decision consumed the
            // suppression this cycle. A frame that dies before any decision
            // leaves the suppression armed for the next decision, which is
            // the fail-safe direction (drop a good order, never send a bad one).
            if (risk_decision) begin
                launch_suppress_r <= 1'b0;
            end else if (rx_fcs_bad && !decision_done_r) begin
                launch_suppress_r <= 1'b1;
            end
        end
    end

    // SPEC_GAP: Section 2.1 lists derived MAC signals at the top-level boundary,
    // but Section 3 requires mac_shim inside hft_engine. This wrapper exposes only
    // raw PCS RX/TX and keeps the derived MAC signals internal.
    mac_shim u_mac_shim (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .pcs_rxdata(pcs_rxdata),
        .pcs_rxctl(pcs_rxctl),
        .pcs_rx_valid(pcs_rx_valid),
        .pcs_block_lock(pcs_block_lock),
        .rx_data(mac_rx_data),
        .rx_valid(mac_rx_valid),
        .rx_sof(mac_rx_sof),
        .rx_eof(mac_rx_eof),
        .rx_eof_bytes(mac_rx_eof_bytes),
        .mac_fcs_valid(rx_mac_fcs_valid)
    );

    hdr_stripper u_hdr_stripper (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .rx_data(mac_rx_data),
        .rx_valid(mac_rx_valid),
        .rx_sof(mac_rx_sof),
        .rx_eof(mac_rx_eof),
        .rx_eof_bytes(mac_rx_eof_bytes),
        .payload_data(payload_data),
        .payload_valid(payload_valid),
        .payload_sof(payload_sof),
        .payload_eof(payload_eof),
        .payload_eof_bytes(payload_eof_bytes),
        .frame_err(frame_err)
    );

    field_aligner u_field_aligner (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .payload_data(payload_data),
        .payload_valid(payload_valid),
        .payload_sof(payload_sof),
        .payload_eof(payload_eof),
        .payload_eof_bytes(payload_eof_bytes),
        .frame_err(frame_err),
        .msg_type(field_msg_type),
        .instrument_id(instrument_id),
        .price(field_price),
        .quantity(field_quantity),
        .side(field_side),
        .field_valid(field_valid),
        .field_err(field_err)
    );

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            sym_stage_msg_type_r <= 16'h0;
            sym_stage_price_r    <= '0;
            sym_stage_quantity_r <= '0;
            sym_stage_side_r     <= 8'h0;
            strat_stage_sym_miss_r <= 1'b0;
            risk_stage_price_r    <= '0;
            risk_stage_quantity_r <= '0;
            risk_stage_side_r     <= 8'h0;
            risk_stage_symbol_idx_r <= '0;
        end else begin
            if (field_valid) begin
                sym_stage_msg_type_r <= field_msg_type;
                sym_stage_price_r    <= field_price;
                sym_stage_quantity_r <= field_quantity;
                sym_stage_side_r     <= field_side;
            end

            // Align the mapper's miss flag with the strategy's registered
            // order-intent cycle so risk_gate sees a matched pair.
            strat_stage_sym_miss_r <= sym_miss;

            // Formatter sidebands follow the strategy's order intent so the
            // risk decision one cycle later pairs with the fields it judged.
            if (order_valid || order_err) begin
                risk_stage_price_r    <= order_price;
                risk_stage_quantity_r <= order_quantity;
                risk_stage_side_r     <= order_side;
                risk_stage_symbol_idx_r <= order_symbol_idx;
            end
        end
    end

    sym_id_mapper #(
        .SYMBOL_TABLE_DEPTH(SYMBOL_TABLE_DEPTH),
        .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH)
    ) u_sym_id_mapper (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .instrument_id(instrument_id),
        .field_valid(field_valid),
        .field_err(field_err),
        .sym_cfg_symbol_idx(sym_cfg_symbol_idx),
        .sym_cfg_instrument_tag(sym_cfg_instrument_tag),
        .sym_cfg_entry_valid(sym_cfg_entry_valid),
        .sym_cfg_valid(sym_cfg_valid),
        .cfg_ready(sym_cfg_ready),
        .symbol_idx(symbol_idx),
        .sym_valid(sym_valid),
        .sym_miss(sym_miss),
        .sym_err(sym_err)
    );

    strategy_core #(
        .SYMBOL_TABLE_DEPTH(SYMBOL_TABLE_DEPTH),
        .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH),
        .PRICE_WIDTH(PRICE_WIDTH),
        .QTY_WIDTH(QTY_WIDTH)
    ) u_strategy_core (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .symbol_idx(symbol_idx),
        .msg_type(sym_stage_msg_type_r),
        .market_price(sym_stage_price_r),
        .market_quantity(sym_stage_quantity_r),
        .market_side(sym_stage_side_r),
        .market_valid(sym_valid),
        .market_err(sym_err),
        .strat_cfg_msg_type(strat_cfg_msg_type),
        .strat_cfg_msg_type_valid(strat_cfg_msg_type_valid),
        .strat_cfg_symbol_idx(strat_cfg_symbol_idx),
        .strat_cfg_entry_enable(strat_cfg_entry_enable),
        .strat_cfg_side_policy(strat_cfg_side_policy),
        .strat_cfg_qty(strat_cfg_qty),
        .strat_cfg_valid(strat_cfg_valid),
        .cfg_ready(strat_cfg_ready),
        .order_symbol_idx(order_symbol_idx),
        .order_price(order_price),
        .order_quantity(order_quantity),
        .order_side(order_side),
        .order_valid(order_valid),
        .order_err(order_err),
        .order_suppress(order_suppress)
    );

    risk_gate #(
        .SYMBOL_TABLE_DEPTH(SYMBOL_TABLE_DEPTH),
        .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH),
        .PRICE_WIDTH(PRICE_WIDTH),
        .QTY_WIDTH(QTY_WIDTH)
    ) u_risk_gate (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .symbol_idx(order_symbol_idx),
        .price(order_price),
        .quantity(order_quantity),
        .side(order_side),
        .sym_valid(risk_in_valid),
        .sym_miss(strat_stage_sym_miss_r),
        .sym_err(order_err),
        .risk_cfg_symbol_idx(risk_cfg_symbol_idx),
        .risk_cfg_price_floor(risk_cfg_price_floor),
        .risk_cfg_price_ceil(risk_cfg_price_ceil),
        .risk_cfg_qty_max(risk_cfg_qty_max),
        .risk_cfg_valid(risk_cfg_valid),
        .cfg_ready(risk_cfg_ready),
        .risk_global_kill(risk_global_kill),
        .risk_pass(risk_pass),
        .risk_kill(risk_kill),
        .kill_reason(risk_kill_reason),
        .risk_err(risk_err)
    );

    pkt_formatter #(
        .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH),
        .PRICE_WIDTH(PRICE_WIDTH),
        .QTY_WIDTH(QTY_WIDTH)
    ) u_pkt_formatter (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .symbol_idx(risk_stage_symbol_idx_r),
        .price(risk_stage_price_r),
        .quantity(risk_stage_quantity_r),
        .side(risk_stage_side_r),
        .risk_pass(fmt_risk_pass),
        .risk_kill(risk_kill),
        .tx_abort(tx_abort),
        .tx_launch_drops(tx_launch_drops),
        .tx_stomps(tx_stomps),
        .pcs_txdata(pcs_txdata),
        .pcs_txctl(pcs_txctl),
        .pcs_tx_valid(pcs_tx_valid),
        .pcs_tx_sof(pcs_tx_sof),
        .pcs_tx_eof(pcs_tx_eof),
        .pcs_tx_eof_bytes(pcs_tx_eof_bytes)
    );

endmodule
