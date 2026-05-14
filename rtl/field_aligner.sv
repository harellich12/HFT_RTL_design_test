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
    parameter int MSG_TYPE_OFFSET      = 0,   // Legal range: 0..22 with field end <= byte 23; changes static slice selection.
    parameter int INSTRUMENT_ID_OFFSET = 2,   // Legal range: 0..16 with field end <= byte 23; changes static slice selection.
    parameter int PRICE_OFFSET         = 10,  // Legal range: 0..16 with field end <= byte 23; changes static slice selection.
    parameter int QUANTITY_OFFSET      = 18,  // Legal range: 0..20 with field end <= byte 23; changes static slice selection.
    parameter int SIDE_OFFSET          = 22   // Legal range: 0..23 with field end <= byte 23; changes static slice selection.
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
    localparam int WINDOW_BYTES   = 24;

    localparam int MSG_TYPE_BYTES      = 2;
    localparam int INSTRUMENT_ID_BYTES = 8;
    localparam int PRICE_BYTES         = 8;
    localparam int QUANTITY_BYTES      = 4;
    localparam int SIDE_BYTES          = 1;

    localparam int MSG_TYPE_END_BYTES      = MSG_TYPE_OFFSET + MSG_TYPE_BYTES;
    localparam int INSTRUMENT_ID_END_BYTES = INSTRUMENT_ID_OFFSET + INSTRUMENT_ID_BYTES;
    localparam int PRICE_END_BYTES         = PRICE_OFFSET + PRICE_BYTES;
    localparam int QUANTITY_END_BYTES      = QUANTITY_OFFSET + QUANTITY_BYTES;
    localparam int SIDE_END_BYTES          = SIDE_OFFSET + SIDE_BYTES;

    localparam int MAX_MSG_INSTR_BYTES = (MSG_TYPE_END_BYTES > INSTRUMENT_ID_END_BYTES)
                                       ? MSG_TYPE_END_BYTES : INSTRUMENT_ID_END_BYTES;
    localparam int MAX_PRICE_QTY_BYTES = (PRICE_END_BYTES > QUANTITY_END_BYTES)
                                       ? PRICE_END_BYTES : QUANTITY_END_BYTES;
    localparam int MAX_DATA_BYTES      = (MAX_MSG_INSTR_BYTES > MAX_PRICE_QTY_BYTES)
                                       ? MAX_MSG_INSTR_BYTES : MAX_PRICE_QTY_BYTES;
    localparam int MAX_FIELD_BYTES     = (MAX_DATA_BYTES > SIDE_END_BYTES)
                                       ? MAX_DATA_BYTES : SIDE_END_BYTES;

    localparam int MSG_TYPE_BIT      = MSG_TYPE_OFFSET * 8;
    localparam int INSTRUMENT_ID_BIT = INSTRUMENT_ID_OFFSET * 8;
    localparam int PRICE_BIT         = PRICE_OFFSET * 8;
    localparam int QUANTITY_BIT      = QUANTITY_OFFSET * 8;
    localparam int SIDE_BIT          = SIDE_OFFSET * 8;

    logic [WORD_CNT_WIDTH-1:0] payload_word_cnt_r;
    logic [63:0] payload_word0_r;
    logic [63:0] payload_word1_r;
    logic        frame_err_r;
    logic        fields_captured_r;
    logic        align_err_now;
    logic        field_err_next;
    logic [WORD_CNT_WIDTH-1:0] current_word_idx;
    logic [5:0]  payload_bytes_available;
    logic [WINDOW_BYTES*8-1:0] payload_window;

    logic [15:0] msg_type_next;
    logic [63:0] instrument_id_next;
    logic [63:0] price_next;
    logic [31:0] quantity_next;
    logic [7:0]  side_next;
    logic        field_valid_next;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            payload_word_cnt_r <= '0;
            payload_word0_r    <= 64'h0;
            payload_word1_r    <= 64'h0;
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
                payload_word0_r    <= payload_data;
                payload_word1_r    <= 64'h0;
                frame_err_r        <= frame_err;
                fields_captured_r  <= 1'b0;
            end else if (payload_valid) begin
                if (!payload_eof) begin
                    payload_word_cnt_r <= payload_word_cnt_r + {{(WORD_CNT_WIDTH-1){1'b0}}, 1'b1};
                end

                if (payload_word_cnt_r == 2'd1) begin
                    payload_word1_r <= payload_data;
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
        current_word_idx = payload_sof ? '0 : payload_word_cnt_r;
        payload_bytes_available = ({4'h0, current_word_idx} + 6'd1) << 3;

        unique case (current_word_idx)
            2'd0: payload_window = {128'h0, payload_data};
            2'd1: payload_window = {64'h0, payload_data, payload_word0_r};
            default: payload_window = {payload_data, payload_word1_r, payload_word0_r};
        endcase

        align_err_now = payload_valid
                     && payload_eof
                     && (payload_bytes_available < MAX_FIELD_BYTES[5:0]);
        field_err_next = frame_err_r || frame_err || align_err_now;

        field_valid_next = payload_valid
                         && (payload_bytes_available >= MAX_FIELD_BYTES[5:0])
                         && !fields_captured_r
                         && !field_err_next;

        msg_type_next = {payload_window[MSG_TYPE_BIT +: 8],
                         payload_window[MSG_TYPE_BIT + 8 +: 8]};

        instrument_id_next = {payload_window[INSTRUMENT_ID_BIT +: 8],
                              payload_window[INSTRUMENT_ID_BIT + 8 +: 8],
                              payload_window[INSTRUMENT_ID_BIT + 16 +: 8],
                              payload_window[INSTRUMENT_ID_BIT + 24 +: 8],
                              payload_window[INSTRUMENT_ID_BIT + 32 +: 8],
                              payload_window[INSTRUMENT_ID_BIT + 40 +: 8],
                              payload_window[INSTRUMENT_ID_BIT + 48 +: 8],
                              payload_window[INSTRUMENT_ID_BIT + 56 +: 8]};

        price_next = {payload_window[PRICE_BIT +: 8],
                      payload_window[PRICE_BIT + 8 +: 8],
                      payload_window[PRICE_BIT + 16 +: 8],
                      payload_window[PRICE_BIT + 24 +: 8],
                      payload_window[PRICE_BIT + 32 +: 8],
                      payload_window[PRICE_BIT + 40 +: 8],
                      payload_window[PRICE_BIT + 48 +: 8],
                      payload_window[PRICE_BIT + 56 +: 8]};

        quantity_next = {payload_window[QUANTITY_BIT +: 8],
                         payload_window[QUANTITY_BIT + 8 +: 8],
                         payload_window[QUANTITY_BIT + 16 +: 8],
                         payload_window[QUANTITY_BIT + 24 +: 8]};

        side_next = payload_window[SIDE_BIT +: 8];
    end

endmodule
