// Module     : field_aligner_assertions
// Description: Assertion bind checks for field_aligner extraction and error behavior
// Latency    : N/A assertion bind
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
module field_aligner_assertions #(
    parameter int MSG_TYPE_OFFSET      = 0,   // Legal range: 0; matches bound field_aligner message type offset.
    parameter int INSTRUMENT_ID_OFFSET = 2,   // Legal range: 2; matches bound field_aligner instrument offset.
    parameter int PRICE_OFFSET         = 10,  // Legal range: 10; matches bound field_aligner price offset.
    parameter int QUANTITY_OFFSET      = 18,  // Legal range: 18; matches bound field_aligner quantity offset.
    parameter int SIDE_OFFSET          = 22   // Legal range: 22; matches bound field_aligner side offset.
) (
    input logic        clk_pcs,
    input logic        rst_n,

    input logic [63:0] payload_data,
    input logic        payload_valid,
    input logic        payload_sof,
    input logic        payload_eof,
    input logic        frame_err,

    input logic [15:0] msg_type,
    input logic [63:0] instrument_id,
    input logic [63:0] price,
    input logic [31:0] quantity,
    input logic [7:0]  side,
    input logic        field_valid,
    input logic        field_err
);

    logic [63:0] payload_data_d1_r;
    logic [63:0] payload_data_d2_r;
    logic [63:0] payload_data_d3_r;
    logic        payload_valid_d1_r;
    logic        payload_valid_d2_r;
    logic        payload_valid_d3_r;
    logic        payload_sof_d1_r;
    logic        payload_sof_d2_r;
    logic        payload_sof_d3_r;
    logic        payload_eof_d1_r;
    logic        payload_eof_d2_r;
    logic        payload_eof_d3_r;
    logic        frame_err_d1_r;
    logic        frame_err_d2_r;
    logic        frame_err_d3_r;

    logic        default_offsets;
    logic        three_word_nominal;
    logic        three_word_error;
    logic [15:0] expected_msg_type;
    logic [63:0] expected_instrument_id;
    logic [63:0] expected_price;
    logic [31:0] expected_quantity;
    logic [7:0]  expected_side;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            payload_data_d1_r  <= 64'h0;
            payload_data_d2_r  <= 64'h0;
            payload_data_d3_r  <= 64'h0;
            payload_valid_d1_r <= 1'b0;
            payload_valid_d2_r <= 1'b0;
            payload_valid_d3_r <= 1'b0;
            payload_sof_d1_r   <= 1'b0;
            payload_sof_d2_r   <= 1'b0;
            payload_sof_d3_r   <= 1'b0;
            payload_eof_d1_r   <= 1'b0;
            payload_eof_d2_r   <= 1'b0;
            payload_eof_d3_r   <= 1'b0;
            frame_err_d1_r     <= 1'b0;
            frame_err_d2_r     <= 1'b0;
            frame_err_d3_r     <= 1'b0;
        end else begin
            payload_data_d1_r  <= payload_data;
            payload_data_d2_r  <= payload_data_d1_r;
            payload_data_d3_r  <= payload_data_d2_r;
            payload_valid_d1_r <= payload_valid;
            payload_valid_d2_r <= payload_valid_d1_r;
            payload_valid_d3_r <= payload_valid_d2_r;
            payload_sof_d1_r   <= payload_sof;
            payload_sof_d2_r   <= payload_sof_d1_r;
            payload_sof_d3_r   <= payload_sof_d2_r;
            payload_eof_d1_r   <= payload_eof;
            payload_eof_d2_r   <= payload_eof_d1_r;
            payload_eof_d3_r   <= payload_eof_d2_r;
            frame_err_d1_r     <= frame_err;
            frame_err_d2_r     <= frame_err_d1_r;
            frame_err_d3_r     <= frame_err_d2_r;
        end
    end

    always_comb begin
        default_offsets = (MSG_TYPE_OFFSET == 0)
                       && (INSTRUMENT_ID_OFFSET == 2)
                       && (PRICE_OFFSET == 10)
                       && (QUANTITY_OFFSET == 18)
                       && (SIDE_OFFSET == 22);

        three_word_nominal = default_offsets
                          && payload_valid_d3_r
                          && payload_valid_d2_r
                          && payload_valid_d1_r
                          && payload_sof_d3_r
                          && !payload_eof_d3_r
                          && !payload_eof_d2_r
                          && !frame_err_d3_r
                          && !frame_err_d2_r
                          && !frame_err_d1_r;

        three_word_error = payload_valid_d3_r
                        && payload_valid_d2_r
                        && payload_valid_d1_r
                        && payload_sof_d3_r
                        && (frame_err_d3_r || frame_err_d2_r || frame_err_d1_r);

        expected_msg_type = {payload_data_d3_r[7:0], payload_data_d3_r[15:8]};

        expected_instrument_id = {payload_data_d3_r[23:16], payload_data_d3_r[31:24],
                                  payload_data_d3_r[39:32], payload_data_d3_r[47:40],
                                  payload_data_d3_r[55:48], payload_data_d3_r[63:56],
                                  payload_data_d2_r[7:0],   payload_data_d2_r[15:8]};

        expected_price = {payload_data_d2_r[23:16], payload_data_d2_r[31:24],
                          payload_data_d2_r[39:32], payload_data_d2_r[47:40],
                          payload_data_d2_r[55:48], payload_data_d2_r[63:56],
                          payload_data_d1_r[7:0],   payload_data_d1_r[15:8]};

        expected_quantity = {payload_data_d1_r[23:16], payload_data_d1_r[31:24],
                             payload_data_d1_r[39:32], payload_data_d1_r[47:40]};

        expected_side = payload_data_d1_r[55:48];
    end

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        field_valid |-> !field_err);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        three_word_nominal |-> (field_valid && !field_err));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        three_word_nominal |-> (msg_type == expected_msg_type));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        three_word_nominal |-> (instrument_id == expected_instrument_id));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        three_word_nominal |-> (price == expected_price));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        three_word_nominal |-> (quantity == expected_quantity));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        three_word_nominal |-> (side == expected_side));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        three_word_error |-> (!field_valid && field_err));

endmodule

bind field_aligner field_aligner_assertions #(
    .MSG_TYPE_OFFSET(MSG_TYPE_OFFSET),
    .INSTRUMENT_ID_OFFSET(INSTRUMENT_ID_OFFSET),
    .PRICE_OFFSET(PRICE_OFFSET),
    .QUANTITY_OFFSET(QUANTITY_OFFSET),
    .SIDE_OFFSET(SIDE_OFFSET)
) u_field_aligner_assertions (
    .clk_pcs(clk_pcs),
    .rst_n(rst_n),
    .payload_data(payload_data),
    .payload_valid(payload_valid),
    .payload_sof(payload_sof),
    .payload_eof(payload_eof),
    .frame_err(frame_err),
    .msg_type(msg_type),
    .instrument_id(instrument_id),
    .price(price),
    .quantity(quantity),
    .side(side),
    .field_valid(field_valid),
    .field_err(field_err)
);
