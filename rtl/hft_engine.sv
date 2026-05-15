// Module     : hft_engine
// Description: Top-level cut-through HFT engine pipeline integration
// Latency    : 7 cycles best case
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
//
// Pipeline role:
// - Instantiates the spec-defined datapath modules in the required order.
// - Keeps all datapath signals in the single PCS clock domain.
// - Aligns extracted sideband fields with registered symbol and risk decisions.
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
    input  logic                          risk_global_kill,

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
    logic        frame_err;

    logic [63:0] instrument_id;
    logic [PRICE_WIDTH-1:0] field_price;
    logic [QTY_WIDTH-1:0]   field_quantity;
    logic [7:0]             field_side;
    logic                   field_valid;
    logic                   field_err;

    logic [PRICE_WIDTH-1:0] sym_stage_price_r;
    logic [QTY_WIDTH-1:0]   sym_stage_quantity_r;
    logic [7:0]             sym_stage_side_r;

    logic [SYMBOL_ID_WIDTH-1:0] symbol_idx;
    logic                       sym_valid;
    logic                       sym_miss;
    logic                       sym_err;

    logic [PRICE_WIDTH-1:0] risk_stage_price_r;
    logic [QTY_WIDTH-1:0]   risk_stage_quantity_r;
    logic [7:0]             risk_stage_side_r;
    logic [SYMBOL_ID_WIDTH-1:0] risk_stage_symbol_idx_r;
    logic                   risk_pass;
    logic                   risk_kill;

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
        .payload_eof_bytes(),
        .frame_err(frame_err)
    );

    field_aligner u_field_aligner (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .payload_data(payload_data),
        .payload_valid(payload_valid),
        .payload_sof(payload_sof),
        .payload_eof(payload_eof),
        .frame_err(frame_err),
        .msg_type(),
        .instrument_id(instrument_id),
        .price(field_price),
        .quantity(field_quantity),
        .side(field_side),
        .field_valid(field_valid),
        .field_err(field_err)
    );

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            sym_stage_price_r    <= '0;
            sym_stage_quantity_r <= '0;
            sym_stage_side_r     <= 8'h0;
            risk_stage_price_r    <= '0;
            risk_stage_quantity_r <= '0;
            risk_stage_side_r     <= 8'h0;
            risk_stage_symbol_idx_r <= '0;
        end else begin
            if (field_valid) begin
                sym_stage_price_r    <= field_price;
                sym_stage_quantity_r <= field_quantity;
                sym_stage_side_r     <= field_side;
            end

            if (sym_valid) begin
                risk_stage_price_r    <= sym_stage_price_r;
                risk_stage_quantity_r <= sym_stage_quantity_r;
                risk_stage_side_r     <= sym_stage_side_r;
                risk_stage_symbol_idx_r <= symbol_idx;
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
        .symbol_idx(symbol_idx),
        .sym_valid(sym_valid),
        .sym_miss(sym_miss),
        .sym_err(sym_err)
    );

    risk_gate #(
        .SYMBOL_TABLE_DEPTH(SYMBOL_TABLE_DEPTH),
        .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH),
        .PRICE_WIDTH(PRICE_WIDTH),
        .QTY_WIDTH(QTY_WIDTH)
    ) u_risk_gate (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .symbol_idx(symbol_idx),
        .price(sym_stage_price_r),
        .quantity(sym_stage_quantity_r),
        .side(sym_stage_side_r),
        .sym_valid(sym_valid),
        .sym_miss(sym_miss),
        .sym_err(sym_err),
        .risk_cfg_symbol_idx(risk_cfg_symbol_idx),
        .risk_cfg_price_floor(risk_cfg_price_floor),
        .risk_cfg_price_ceil(risk_cfg_price_ceil),
        .risk_cfg_qty_max(risk_cfg_qty_max),
        .risk_cfg_valid(risk_cfg_valid),
        .risk_global_kill(risk_global_kill),
        .risk_pass(risk_pass),
        .risk_kill(risk_kill),
        .kill_reason(),
        .risk_err()
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
        .risk_pass(risk_pass),
        .risk_kill(risk_kill),
        .pcs_txdata(pcs_txdata),
        .pcs_txctl(pcs_txctl),
        .pcs_tx_valid(pcs_tx_valid),
        .pcs_tx_sof(pcs_tx_sof),
        .pcs_tx_eof(pcs_tx_eof),
        .pcs_tx_eof_bytes(pcs_tx_eof_bytes)
    );

endmodule
