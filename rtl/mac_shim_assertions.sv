// Module     : mac_shim_assertions
// Description: Assertion bind checks for mac_shim boundary and alignment behavior
// Latency    : N/A assertion bind
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
module mac_shim_assertions (
    input logic        clk_pcs,
    input logic        rst_n,

    input logic [63:0] pcs_rxdata,
    input logic [7:0]  pcs_rxctl,
    input logic        pcs_rx_valid,
    input logic        pcs_block_lock,

    input logic [63:0] rx_data,
    input logic        rx_valid,
    input logic        rx_sof,
    input logic        rx_eof,
    input logic [2:0]  rx_eof_bytes,
    input logic        mac_fcs_valid
);

    localparam logic [63:0] ASSERT_PREAMBLE_SFD_WORD = 64'hD5_55_55_55_55_55_55_55;

    logic output_frame_active_r;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            output_frame_active_r <= 1'b0;
        end else if (!pcs_block_lock) begin
            output_frame_active_r <= 1'b0;
        end else if (rx_valid && rx_eof) begin
            output_frame_active_r <= 1'b0;
        end else if (rx_valid && rx_sof) begin
            output_frame_active_r <= 1'b1;
        end
    end

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        rx_sof |-> rx_valid);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        rx_eof |-> rx_valid);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        mac_fcs_valid |-> rx_eof);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        rx_sof |-> (rx_data == ASSERT_PREAMBLE_SFD_WORD));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        !pcs_block_lock |=> (!rx_valid && !rx_sof && !rx_eof && !mac_fcs_valid));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (output_frame_active_r && !pcs_block_lock)
        |=> (!rx_valid && !rx_sof && !rx_eof && !mac_fcs_valid));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        ($past(output_frame_active_r) && !$past(pcs_block_lock) && pcs_block_lock
         && !(pcs_rx_valid && (pcs_rxdata == ASSERT_PREAMBLE_SFD_WORD)))
        |=> (!rx_valid && !rx_sof && !rx_eof && !mac_fcs_valid));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (pcs_rx_valid && pcs_block_lock && (pcs_rxdata == ASSERT_PREAMBLE_SFD_WORD) && !output_frame_active_r)
        |=> (rx_valid && rx_sof && !rx_eof));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (pcs_rx_valid && pcs_block_lock && output_frame_active_r && (pcs_rxctl != 8'h00))
        |=> (rx_valid && rx_eof));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        rx_valid |-> (rx_data == $past(pcs_rxdata)));

endmodule

bind mac_shim mac_shim_assertions u_mac_shim_assertions (
    .clk_pcs(clk_pcs),
    .rst_n(rst_n),
    .pcs_rxdata(pcs_rxdata),
    .pcs_rxctl(pcs_rxctl),
    .pcs_rx_valid(pcs_rx_valid),
    .pcs_block_lock(pcs_block_lock),
    .rx_data(rx_data),
    .rx_valid(rx_valid),
    .rx_sof(rx_sof),
    .rx_eof(rx_eof),
    .rx_eof_bytes(rx_eof_bytes),
    .mac_fcs_valid(mac_fcs_valid)
);
