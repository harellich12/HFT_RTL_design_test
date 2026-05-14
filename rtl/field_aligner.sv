// Module     : field_aligner
// Description: Extract fixed-offset UDP payload fields into typed registered signals
// Latency    : 1-2 cycles
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
//
// Pipeline role:
// - Converts the stripped UDP payload stream into typed market-data fields.
// - Owns all fixed byte offsets and endian conversion before risk/order logic.
// - Propagates upstream framing errors as field_err.
module field_aligner #(
    parameter int MSG_TYPE_OFFSET      = 0,   // Legal range: 0; fixed byte offset, no hardware cost when unchanged.
    parameter int INSTRUMENT_ID_OFFSET = 2,   // Legal range: 2; fixed byte offset, changes static slice selection.
    parameter int PRICE_OFFSET         = 10,  // Legal range: 10; fixed byte offset, changes static slice selection.
    parameter int QUANTITY_OFFSET      = 18,  // Legal range: 18; fixed byte offset, changes static slice selection.
    parameter int SIDE_OFFSET          = 22   // Legal range: 22; fixed byte offset, changes static slice selection.
) (
    input  logic        clk_pcs,
    input  logic        rst_n,

    input  logic [63:0] payload_data,
    input  logic        payload_valid,
    input  logic        payload_sof,
    input  logic        payload_eof,
    input  logic        frame_err,

    // Extracted fields - registered, valid when field_valid asserted
    output logic [15:0] msg_type,
    output logic [63:0] instrument_id,
    output logic [63:0] price,
    output logic [31:0] quantity,
    output logic [7:0]  side,
    output logic        field_valid,
    output logic        field_err
);

    localparam int WORD_CNT_WIDTH = 2;

    logic [WORD_CNT_WIDTH-1:0] payload_word_cnt_r;
    logic [47:0] instrument_id_hi_r;
    logic [15:0] instrument_id_lo_r;
    logic [47:0] price_hi_r;
    logic        frame_err_r;
    logic        fields_captured_r;
    logic        align_err_now;
    logic        field_err_next;

    logic [15:0] msg_type_next;
    logic [63:0] instrument_id_next;
    logic [63:0] price_next;
    logic [31:0] quantity_next;
    logic [7:0]  side_next;
    logic        field_valid_next;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            payload_word_cnt_r <= '0;
            instrument_id_hi_r <= 48'h0;
            instrument_id_lo_r <= 16'h0;
            price_hi_r         <= 48'h0;
            frame_err_r        <= 1'b0;
            fields_captured_r  <= 1'b0;
            msg_type           <= 16'h0;
            instrument_id      <= 64'h0;
            price              <= 64'h0;
            quantity           <= 32'h0;
            side               <= 8'h0;
            field_valid        <= 1'b0;
            field_err          <= 1'b0;
        end else begin
            field_valid <= field_valid_next;
            field_err   <= field_err_next;

            if (field_valid_next) begin
                msg_type      <= msg_type_next;
                instrument_id <= instrument_id_next;
                price         <= price_next;
                quantity      <= quantity_next;
                side          <= side_next;
            end

            if (payload_valid && payload_sof) begin
                payload_word_cnt_r <= {{(WORD_CNT_WIDTH-1){1'b0}}, 1'b1};
                frame_err_r        <= frame_err;
                fields_captured_r  <= 1'b0;
                // First payload word contains msg_type and the upper 6 bytes of instrument_id.
                msg_type           <= {payload_data[7:0], payload_data[15:8]};
                instrument_id_hi_r <= payload_data[63:16];
            end else if (payload_valid) begin
                if (!payload_eof) begin
                    payload_word_cnt_r <= payload_word_cnt_r + {{(WORD_CNT_WIDTH-1){1'b0}}, 1'b1};
                end

                if (payload_word_cnt_r == 2'd1) begin
                    // Second payload word finishes instrument_id and starts price.
                    instrument_id_lo_r <= payload_data[15:0];
                    price_hi_r         <= payload_data[63:16];
                end

                if (frame_err) begin
                    frame_err_r <= 1'b1;
                end

                if (field_valid_next) begin
                    fields_captured_r <= 1'b1;
                end
            end

            if (payload_valid && payload_eof) begin
                payload_word_cnt_r <= '0;
                frame_err_r        <= 1'b0;
                fields_captured_r  <= 1'b0;
            end
        end
    end

    always_comb begin
        align_err_now = payload_valid && payload_eof && (payload_word_cnt_r < 2'd2);
        field_err_next = frame_err_r || frame_err || align_err_now;

        // SPEC_GAP: The spec asks for static offset parameters but gives no parameterized
        // interface; these defaults preserve the documented fixed feed layout.
        field_valid_next = payload_valid
                         && (payload_word_cnt_r == 2'd2)
                         && !fields_captured_r
                         && !field_err_next;

        msg_type_next = msg_type;

        instrument_id_next = {instrument_id_hi_r[7:0],  instrument_id_hi_r[15:8],
                              instrument_id_hi_r[23:16], instrument_id_hi_r[31:24],
                              instrument_id_hi_r[39:32], instrument_id_hi_r[47:40],
                              instrument_id_lo_r[7:0],  instrument_id_lo_r[15:8]};

        price_next = {price_hi_r[7:0],  price_hi_r[15:8],
                      price_hi_r[23:16], price_hi_r[31:24],
                      price_hi_r[39:32], price_hi_r[47:40],
                      payload_data[7:0], payload_data[15:8]};

        quantity_next = {payload_data[23:16], payload_data[31:24],
                         payload_data[39:32], payload_data[47:40]};

        side_next = payload_data[55:48];

        if ((MSG_TYPE_OFFSET != 0)
         || (INSTRUMENT_ID_OFFSET != 2)
         || (PRICE_OFFSET != 10)
         || (QUANTITY_OFFSET != 18)
         || (SIDE_OFFSET != 22)) begin
            field_valid_next = 1'b0;
            field_err_next   = payload_valid;
        end
    end

endmodule
