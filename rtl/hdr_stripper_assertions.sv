// Module     : hdr_stripper_assertions
// Description: Assertion bind checks for hdr_stripper stream and error behavior
// Latency    : N/A assertion bind
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
module hdr_stripper_assertions (
    input logic        clk_pcs,
    input logic        rst_n,

    input logic        rx_valid,
    input logic        rx_sof,
    input logic        rx_eof,

    input logic        payload_valid,
    input logic        payload_sof,
    input logic        payload_eof,
    input logic [2:0]  payload_eof_bytes,
    input logic        frame_err
);

    localparam int ASSERT_MAX_PAYLOAD_WORDS = 256;

    logic payload_active_r;
    logic payload_bound_active_r;
    logic [8:0] payload_bound_count_r;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            payload_active_r       <= 1'b0;
            payload_bound_active_r <= 1'b0;
            payload_bound_count_r  <= 9'h0;
        end else if (frame_err) begin
            payload_active_r       <= 1'b0;
            payload_bound_active_r <= 1'b0;
            payload_bound_count_r  <= 9'h0;
        end else if (payload_valid && payload_eof) begin
            payload_active_r       <= 1'b0;
            payload_bound_active_r <= 1'b0;
            payload_bound_count_r  <= 9'h0;
        end else if (payload_valid && payload_sof) begin
            payload_active_r       <= 1'b1;
            payload_bound_active_r <= 1'b1;
            payload_bound_count_r  <= 9'h0;
        end else if (payload_bound_active_r) begin
            payload_bound_count_r <= payload_bound_count_r + 9'd1;
        end
    end

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        payload_sof |-> payload_valid);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        payload_eof |-> payload_valid);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        frame_err |-> !payload_valid);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (payload_active_r && !payload_eof && !frame_err) |-> payload_valid);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (payload_valid && !payload_eof) |=> (payload_valid || frame_err));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        payload_sof |-> !payload_active_r);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        payload_bound_active_r |-> (payload_bound_count_r <= ASSERT_MAX_PAYLOAD_WORDS[8:0]));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        rx_sof |-> rx_valid);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        rx_eof |-> rx_valid);

endmodule

bind hdr_stripper hdr_stripper_assertions u_hdr_stripper_assertions (
    .clk_pcs(clk_pcs),
    .rst_n(rst_n),
    .rx_valid(rx_valid),
    .rx_sof(rx_sof),
    .rx_eof(rx_eof),
    .payload_valid(payload_valid),
    .payload_sof(payload_sof),
    .payload_eof(payload_eof),
    .payload_eof_bytes(payload_eof_bytes),
    .frame_err(frame_err)
);
