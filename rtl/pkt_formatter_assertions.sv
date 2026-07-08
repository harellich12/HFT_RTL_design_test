// Module     : pkt_formatter_assertions
// Description: Assertion bind checks for pkt_formatter framing and kill behavior
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
    input logic                       tx_abort,

    input logic [63:0] pcs_txdata,
    input logic [7:0]  pcs_txctl,
    input logic        pcs_tx_valid,
    input logic        pcs_tx_sof,
    input logic        pcs_tx_eof,
    input logic [2:0]  pcs_tx_eof_bytes
);

    localparam logic [63:0] ASSERT_PREAMBLE_SFD_WORD = 64'hD5_55_55_55_55_55_55_55;
    localparam logic [3:0]  ASSERT_LAST_WORD_COUNT   = 4'd9;

    logic       tx_frame_active_r;
    logic [3:0] tx_word_count_r;

    default clocking cb @(posedge clk_pcs);
    endclocking

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            tx_frame_active_r <= 1'b0;
            tx_word_count_r   <= 4'h0;
        end else if (pcs_tx_valid && pcs_tx_eof) begin
            tx_frame_active_r <= 1'b0;
            tx_word_count_r   <= 4'h0;
        end else if (pcs_tx_valid && pcs_tx_sof) begin
            tx_frame_active_r <= 1'b1;
            tx_word_count_r   <= 4'h1;
        end else if (pcs_tx_valid) begin
            tx_word_count_r   <= tx_word_count_r + 4'h1;
        end
    end

    property launch_within_one_cycle_from_idle;
        (risk_pass && !risk_kill && !pcs_tx_valid) |=> (pcs_tx_valid && pcs_tx_sof);
    endproperty

    property no_gap_between_valid_and_eof;
        (pcs_tx_valid && !pcs_tx_eof) |=> pcs_tx_valid;
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

    // A kill decided while a frame is in flight must not truncate that frame.
    property kill_does_not_truncate_inflight;
        (risk_kill && pcs_tx_valid && !pcs_tx_eof) |=> pcs_tx_valid;
    endproperty

    // A kill with no pass and no frame in flight must not start one.
    property kill_at_idle_stays_idle;
        (risk_kill && !risk_pass && !pcs_tx_valid) |=> !pcs_tx_valid;
    endproperty

    property eof_terminate_word_has_no_data;
        pcs_tx_eof |-> (pcs_tx_eof_bytes == 3'h0);
    endproperty

    property sof_word_is_preamble;
        pcs_tx_sof |-> (pcs_txdata == ASSERT_PREAMBLE_SFD_WORD);
    endproperty

    // Data words carry no control lanes; only the terminate word does.
    property data_words_ctl_idle;
        (pcs_tx_valid && !pcs_tx_eof) |-> (pcs_txctl == 8'h00);
    endproperty

    property terminate_word_ctl_flagged;
        pcs_tx_eof |-> (pcs_txctl == 8'hFF);
    endproperty

    // Fixed deterministic burst: preamble to terminate is exactly 10 words.
    // Counter-based because this Verilator version rejects multi-cycle ##N.
    property eof_exactly_at_frame_length;
        (pcs_tx_valid && pcs_tx_eof) |-> (tx_word_count_r == ASSERT_LAST_WORD_COUNT);
    endproperty

    property no_words_past_frame_length;
        (pcs_tx_valid && (tx_word_count_r == ASSERT_LAST_WORD_COUNT)) |-> pcs_tx_eof;
    endproperty

    property sof_only_on_first_valid_word;
        pcs_tx_sof |-> !tx_frame_active_r;
    endproperty

    property first_valid_word_requires_sof;
        (pcs_tx_valid && !tx_frame_active_r) |-> pcs_tx_sof;
    endproperty

    property no_repeated_sof_before_eof;
        (pcs_tx_valid && tx_frame_active_r && !pcs_tx_eof) |-> !pcs_tx_sof;
    endproperty

    assert property (disable iff (!rst_n) launch_within_one_cycle_from_idle);
    assert property (disable iff (!rst_n) no_gap_between_valid_and_eof);
    assert property (disable iff (!rst_n) eof_requires_valid);
    assert property (disable iff (!rst_n) sof_requires_valid);
    assert property (disable iff (!rst_n) sof_not_eof_same_cycle);
    assert property (disable iff (!rst_n) kill_does_not_truncate_inflight);
    assert property (disable iff (!rst_n) kill_at_idle_stays_idle);
    assert property (disable iff (!rst_n) eof_terminate_word_has_no_data);
    assert property (disable iff (!rst_n) sof_word_is_preamble);
    assert property (disable iff (!rst_n) data_words_ctl_idle);
    assert property (disable iff (!rst_n) terminate_word_ctl_flagged);
    assert property (disable iff (!rst_n) eof_exactly_at_frame_length);
    assert property (disable iff (!rst_n) no_words_past_frame_length);
    assert property (disable iff (!rst_n) sof_only_on_first_valid_word);
    assert property (disable iff (!rst_n) first_valid_word_requires_sof);
    assert property (disable iff (!rst_n) no_repeated_sof_before_eof);

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
    .tx_abort(tx_abort),
    .pcs_txdata(pcs_txdata),
    .pcs_txctl(pcs_txctl),
    .pcs_tx_valid(pcs_tx_valid),
    .pcs_tx_sof(pcs_tx_sof),
    .pcs_tx_eof(pcs_tx_eof),
    .pcs_tx_eof_bytes(pcs_tx_eof_bytes)
);
