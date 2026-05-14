// Module     : pkt_formatter_assertions
// Description: Assertion bind checks for pkt_formatter timing and kill behavior
// Latency    : N/A assertion bind
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
module pkt_formatter_assertions #(
    parameter int SYMBOL_ID_WIDTH = 10,  // Legal range: positive integer; matches bound pkt_formatter symbol width.
    parameter int PRICE_WIDTH     = 64,  // Legal range: positive integer; matches bound pkt_formatter price width.
    parameter int QTY_WIDTH       = 32   // Legal range: positive integer; matches bound pkt_formatter quantity width.
) (
    input logic        clk_pcs,
    input logic        rst_n,

    input logic [SYMBOL_ID_WIDTH-1:0] symbol_idx,
    input logic [PRICE_WIDTH-1:0]     price,
    input logic [QTY_WIDTH-1:0]       quantity,
    input logic [7:0]                 side,
    input logic                       risk_pass,
    input logic                       risk_kill,

    input logic [63:0] pcs_txdata,
    input logic [7:0]  pcs_txctl,
    input logic        pcs_tx_valid,
    input logic        pcs_tx_sof,
    input logic        pcs_tx_eof,
    input logic [2:0]  pcs_tx_eof_bytes
);

    default clocking cb @(posedge clk_pcs);
    endclocking

    property launch_within_one_cycle_from_idle;
        (risk_pass && !risk_kill && !pcs_tx_valid) |=> (pcs_tx_valid && pcs_tx_sof);
    endproperty

    property no_gap_between_valid_and_eof;
        (pcs_tx_valid && !pcs_tx_eof && !risk_kill) |=> pcs_tx_valid;
    endproperty

    property eof_requires_valid;
        pcs_tx_eof |-> pcs_tx_valid;
    endproperty

    property sof_requires_valid;
        pcs_tx_sof |-> pcs_tx_valid;
    endproperty

    property sof_not_eof_same_cycle;
        pcs_tx_sof |-> !pcs_tx_eof;
    endproperty

    property kill_suppresses_tx_within_one_cycle;
        risk_kill |=> (!pcs_tx_valid && !pcs_tx_sof && !pcs_tx_eof);
    endproperty

    property eof_has_full_final_word;
        pcs_tx_eof |-> (pcs_tx_eof_bytes == 3'h0);
    endproperty

    property tx_control_idle_for_raw_data_path;
        pcs_tx_valid |-> (pcs_txctl == 8'h00);
    endproperty

    assert property (disable iff (!rst_n) launch_within_one_cycle_from_idle);
    assert property (disable iff (!rst_n) no_gap_between_valid_and_eof);
    assert property (disable iff (!rst_n) eof_requires_valid);
    assert property (disable iff (!rst_n) sof_requires_valid);
    assert property (disable iff (!rst_n) sof_not_eof_same_cycle);
    assert property (disable iff (!rst_n) kill_suppresses_tx_within_one_cycle);
    assert property (disable iff (!rst_n) eof_has_full_final_word);
    assert property (disable iff (!rst_n) tx_control_idle_for_raw_data_path);

endmodule

bind pkt_formatter pkt_formatter_assertions #(
    .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH),
    .PRICE_WIDTH(PRICE_WIDTH),
    .QTY_WIDTH(QTY_WIDTH)
) u_pkt_formatter_assertions (
    .clk_pcs(clk_pcs),
    .rst_n(rst_n),
    .symbol_idx(symbol_idx),
    .price(price),
    .quantity(quantity),
    .side(side),
    .risk_pass(risk_pass),
    .risk_kill(risk_kill),
    .pcs_txdata(pcs_txdata),
    .pcs_txctl(pcs_txctl),
    .pcs_tx_valid(pcs_tx_valid),
    .pcs_tx_sof(pcs_tx_sof),
    .pcs_tx_eof(pcs_tx_eof),
    .pcs_tx_eof_bytes(pcs_tx_eof_bytes)
);
