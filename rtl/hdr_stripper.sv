// Module     : hdr_stripper
// Description: Strip Ethernet, IPv4, and UDP headers from inbound market data frames
// Latency    : 2 cycles
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
//
// Pipeline role:
// - Removes the preamble plus fixed Ethernet/IPv4/UDP header from the stream.
// - Re-aligns the UDP payload after the 42-byte header leaves a 2-byte offset.
// - Raises frame_err immediately for fixed-header protocol violations.
module hdr_stripper (
    input  logic        clk_pcs,
    input  logic        rst_n,

    // From mac_shim
    input  logic [63:0] rx_data,
    input  logic        rx_valid,
    input  logic        rx_sof,
    input  logic        rx_eof,
    input  logic [2:0]  rx_eof_bytes,

    // To field_aligner
    output logic [63:0] payload_data,
    output logic        payload_valid,
    output logic        payload_sof,
    output logic        payload_eof,
    output logic [2:0]  payload_eof_bytes,
    output logic        frame_err
);

    localparam int HDR_BYTES       = 42;
    localparam int WORD_BYTES      = 8;
    localparam int HDR_FULL_WORDS  = HDR_BYTES / WORD_BYTES;   // 5
    localparam int HDR_REM_BYTES   = HDR_BYTES % WORD_BYTES;   // 2
    localparam int SHIFT_BITS      = HDR_REM_BYTES * 8;         // 16

    localparam int WORD_CNT_WIDTH      = 16;
    localparam int PREAMBLE_WORDS      = 1;
    localparam int PAYLOAD_START_WORD  = PREAMBLE_WORDS + HDR_FULL_WORDS;
    localparam int FIRST_PAYLOAD_WORD  = PAYLOAD_START_WORD + 1;
    localparam int ALIGN_TAIL_BITS     = 64 - SHIFT_BITS;

    logic [WORD_CNT_WIDTH-1:0] word_cnt_r;
    logic [WORD_CNT_WIDTH-1:0] current_word_cnt;
    logic [ALIGN_TAIL_BITS-1:0] payload_tail_r;
    logic        frame_err_r;
    logic        payload_started_r;
    logic        eof_flush_r;
    logic [2:0]  eof_flush_bytes_r;

    logic [3:0]  rx_eof_valid_bytes;
    logic        ethertype_err;
    logic        ihl_err;
    logic        protocol_err;
    logic        short_frame_err;
    logic        frame_err_now;
    logic        frame_err_active;
    logic        normal_payload_valid;
    logic        normal_payload_eof;
    logic [2:0]  normal_payload_eof_bytes;
    logic        start_eof_flush;

    // Registered state is limited to stream position, the 6-byte alignment tail,
    // sticky error tracking, and the one-cycle EOF flush for trailing payload.
    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            word_cnt_r        <= '0;
            payload_tail_r    <= '0;
            frame_err_r       <= 1'b0;
            payload_started_r <= 1'b0;
            eof_flush_r       <= 1'b0;
            eof_flush_bytes_r <= '0;
        end else begin
            if (rx_valid && rx_sof) begin
                word_cnt_r        <= '0;
                frame_err_r       <= frame_err_now;
                payload_started_r <= 1'b0;
                eof_flush_r       <= 1'b0;
                eof_flush_bytes_r <= '0;
            end else begin
                if (rx_valid) begin
                    word_cnt_r <= word_cnt_r + {{(WORD_CNT_WIDTH-1){1'b0}}, 1'b1};
                end

                if (frame_err_now) begin
                    frame_err_r <= 1'b1;
                end

                if (payload_valid) begin
                    payload_started_r <= 1'b1;
                end

                if (eof_flush_r) begin
                    eof_flush_r       <= 1'b0;
                    eof_flush_bytes_r <= '0;
                end

                if (start_eof_flush) begin
                    eof_flush_r       <= 1'b1;
                    eof_flush_bytes_r <= rx_eof_valid_bytes[2:0] - HDR_REM_BYTES[2:0];
                end
            end

            if (rx_valid && (current_word_cnt >= PAYLOAD_START_WORD[WORD_CNT_WIDTH-1:0])) begin
                // Fixed 16-bit right shift: retain bytes 2-7 for the next aligned word.
                payload_tail_r <= rx_data[63:SHIFT_BITS];
            end
        end
    end

    // Combines the previous alignment tail with the current word to present
    // payload words without buffering the full frame.
    always_comb begin
        current_word_cnt = rx_sof ? '0 : word_cnt_r + {{(WORD_CNT_WIDTH-1){1'b0}}, 1'b1};

        rx_eof_valid_bytes = (rx_eof_bytes == 3'd0) ? 4'd8 : {1'b0, rx_eof_bytes};

        ethertype_err = rx_valid
                      && (current_word_cnt == 16'd2)
                      && ({rx_data[39:32], rx_data[47:40]} != 16'h0800);
        ihl_err       = rx_valid
                      && (current_word_cnt == 16'd2)
                      && (rx_data[51:48] != 4'h5);
        protocol_err  = rx_valid
                      && (current_word_cnt == 16'd3)
                      && (rx_data[63:56] != 8'h11);

        // SPEC_GAP: "bad length" is not numerically defined; flag frames ending before
        // any UDP payload byte exists, which is the minimum-latency detectable failure.
        short_frame_err = rx_valid
                        && rx_eof
                        && ((current_word_cnt < PAYLOAD_START_WORD[WORD_CNT_WIDTH-1:0])
                         || ((current_word_cnt == PAYLOAD_START_WORD[WORD_CNT_WIDTH-1:0])
                          && (rx_eof_valid_bytes <= HDR_REM_BYTES[3:0])));

        frame_err_now    = ethertype_err || ihl_err || protocol_err || short_frame_err;
        frame_err_active = frame_err_r || frame_err_now;

        // SPEC_GAP: A 2-cycle rx_sof-to-payload_valid budget conflicts with stripping
        // an in-stream preamble plus 42 header bytes; emit on the first causal cycle.
        normal_payload_valid = rx_valid
                            && (current_word_cnt >= FIRST_PAYLOAD_WORD[WORD_CNT_WIDTH-1:0]);
        normal_payload_eof   = rx_eof && (rx_eof_valid_bytes <= HDR_REM_BYTES[3:0]);

        if (rx_eof_valid_bytes == HDR_REM_BYTES[3:0]) begin
            normal_payload_eof_bytes = 3'd0;
        end else begin
            // One final byte from the current input word completes a 7-byte final output.
            normal_payload_eof_bytes = 3'd7;
        end

        start_eof_flush = rx_valid
                        && rx_eof
                        && !frame_err_active
                        && (current_word_cnt >= PAYLOAD_START_WORD[WORD_CNT_WIDTH-1:0])
                        && (rx_eof_valid_bytes > HDR_REM_BYTES[3:0]);

        payload_data = eof_flush_r ? {SHIFT_BITS'(0), payload_tail_r}
                                   : {rx_data[SHIFT_BITS-1:0], payload_tail_r};
        payload_valid = (eof_flush_r || normal_payload_valid) && !frame_err_active;
        payload_sof = payload_valid && !payload_started_r;
        payload_eof = payload_valid && (eof_flush_r || normal_payload_eof);
        payload_eof_bytes = eof_flush_r ? eof_flush_bytes_r : normal_payload_eof_bytes;
        frame_err = frame_err_active;
    end

endmodule
