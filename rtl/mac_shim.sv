// Module     : mac_shim
// Description: Thin raw PCS-to-MAC decoder for frame boundary and FCS signals
// Latency    : 1 cycle
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
//
// Pipeline role:
// - Terminates the raw PCS receive interface at the first RTL pipeline stage.
// - Marks frame boundaries for hdr_stripper while leaving all bytes untouched.
// - Keeps CRC/FCS bookkeeping off to the side so the datapath remains cut-through.
module mac_shim (
    input  logic        clk_pcs,
    input  logic        rst_n,

    // From PCS
    input  logic [63:0] pcs_rxdata,
    input  logic [7:0]  pcs_rxctl,
    input  logic        pcs_rx_valid,
    input  logic        pcs_block_lock,

    // To hdr_stripper
    output logic [63:0] rx_data,
    output logic        rx_valid,
    output logic        rx_sof,
    output logic        rx_eof,
    output logic [2:0]  rx_eof_bytes,
    output logic        mac_fcs_valid
);

    localparam logic [63:0] PREAMBLE_SFD_WORD = 64'hD5_55_55_55_55_55_55_55;
    localparam logic [31:0] CRC_INIT          = 32'hFFFFFFFF;
    localparam logic [31:0] CRC_POLY          = 32'h04C11DB7;
    localparam logic [31:0] CRC_FINAL_XOR     = 32'hFFFFFFFF;
    localparam int          FCS_BYTES         = 4;
    localparam int          ROLL_WIDTH        = 67;

    logic        frame_active_r;
    logic [31:0] crc_reg;
    logic [31:0] fcs_window_r;
    logic [2:0]  fcs_depth_r;

    logic        sof_detect;
    logic        eof_detect;
    logic [2:0]  eof_bytecount;
    logic [3:0]  data_byte_count;
    logic        rx_valid_next;
    logic        fcs_match;
    logic [31:0] crc_next;
    logic [31:0] fcs_window_next;
    logic [2:0]  fcs_depth_next;
    logic [31:0] crc_final;
    logic [31:0] expected_fcs_wire_order;
    logic [ROLL_WIDTH-1:0] roll_b0;
    logic [ROLL_WIDTH-1:0] roll_b1;
    logic [ROLL_WIDTH-1:0] roll_b2;
    logic [ROLL_WIDTH-1:0] roll_b3;
    logic [ROLL_WIDTH-1:0] roll_b4;
    logic [ROLL_WIDTH-1:0] roll_b5;
    logic [ROLL_WIDTH-1:0] roll_b6;
    logic [ROLL_WIDTH-1:0] roll_b7;

    function automatic logic [31:0] crc32_byte (
        input logic [31:0] crc_in,
        input logic [7:0]  data_byte
    );
        logic [31:0] crc;
        logic        msb;
        crc = crc_in;
        for (int i = 0; i < 8; i++) begin
            msb = crc[31] ^ data_byte[i];
            crc = {crc[30:0], 1'b0} ^ (msb ? CRC_POLY : 32'h0);
        end
        return crc;
    endfunction

    // Rolls one accepted data byte through a four-byte delay window. Bytes leave
    // this window only after four newer bytes arrive, which excludes the final
    // Ethernet FCS from the CRC path once EOF identifies the end of the frame.
    function automatic logic [ROLL_WIDTH-1:0] roll_crc_window_byte (
        input logic [31:0] crc_in,
        input logic [31:0] fcs_window_in,
        input logic [2:0]  fcs_depth_in,
        input logic [7:0]  data_byte,
        input logic        byte_valid
    );
        logic [31:0] crc_tmp;
        logic [31:0] fcs_window_tmp;
        logic [2:0]  fcs_depth_tmp;
        crc_tmp        = crc_in;
        fcs_window_tmp = fcs_window_in;
        fcs_depth_tmp  = fcs_depth_in;

        if (byte_valid) begin
            // Keep the newest four bytes out of the CRC path until EOF proves them FCS.
            fcs_window_tmp = {fcs_window_in[23:0], data_byte};
            if (fcs_depth_in == FCS_BYTES[2:0]) begin
                crc_tmp = crc32_byte(crc_in, fcs_window_in[31:24]);
            end else begin
                fcs_depth_tmp = fcs_depth_in + 3'd1;
            end
        end

        return {crc_tmp, fcs_window_tmp, fcs_depth_tmp};
    endfunction

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            frame_active_r    <= 1'b0;
            crc_reg           <= CRC_INIT;
            fcs_window_r      <= 32'h0;
            fcs_depth_r       <= 3'h0;
            rx_sof            <= 1'b0;
            rx_eof            <= 1'b0;
            rx_valid          <= 1'b0;
            rx_data           <= 64'h0;
            mac_fcs_valid     <= 1'b0;
            rx_eof_bytes      <= 3'h0;
        end else begin
            rx_data           <= pcs_rxdata;
            rx_valid          <= rx_valid_next;
            rx_sof            <= sof_detect && !eof_detect;
            rx_eof            <= eof_detect;
            rx_eof_bytes      <= eof_detect ? eof_bytecount : 3'h0;
            mac_fcs_valid     <= fcs_match;

            if (!pcs_block_lock) begin
                frame_active_r <= 1'b0;
            end else if (eof_detect) begin
                frame_active_r <= 1'b0;
            end else if (sof_detect) begin
                frame_active_r <= 1'b1;
            end

            if (!pcs_block_lock || sof_detect) begin
                crc_reg      <= CRC_INIT;
                fcs_window_r <= 32'h0;
                fcs_depth_r  <= 3'h0;
            end else if (pcs_rx_valid && frame_active_r) begin
                crc_reg      <= crc_next;
                fcs_window_r <= eof_detect ? 32'h0 : fcs_window_next;
                fcs_depth_r  <= eof_detect ? 3'h0 : fcs_depth_next;
            end
        end
    end

    // Decode the current PCS word and build the next CRC/FCS state. All results
    // are captured by the single output register stage above.
    always_comb begin
        sof_detect = pcs_rx_valid
                  && pcs_block_lock
                  && !frame_active_r
                  && (pcs_rxdata == PREAMBLE_SFD_WORD);

        eof_bytecount = pcs_rxctl[0] ? 3'h0 :
                        pcs_rxctl[1] ? 3'h1 :
                        pcs_rxctl[2] ? 3'h2 :
                        pcs_rxctl[3] ? 3'h3 :
                        pcs_rxctl[4] ? 3'h4 :
                        pcs_rxctl[5] ? 3'h5 :
                        pcs_rxctl[6] ? 3'h6 :
                        pcs_rxctl[7] ? 3'h7 : 3'h0;

        eof_detect = pcs_rx_valid
                  && pcs_block_lock
                  && frame_active_r
                  && (pcs_rxctl != 8'h00);

        data_byte_count = eof_detect ? {1'b0, eof_bytecount} : 4'd8;

        roll_b0 = roll_crc_window_byte(crc_reg,       fcs_window_r,       fcs_depth_r,
                                       pcs_rxdata[7:0],   data_byte_count > 4'd0);
        roll_b1 = roll_crc_window_byte(roll_b0[66:35], roll_b0[34:3], roll_b0[2:0],
                                       pcs_rxdata[15:8],  data_byte_count > 4'd1);
        roll_b2 = roll_crc_window_byte(roll_b1[66:35], roll_b1[34:3], roll_b1[2:0],
                                       pcs_rxdata[23:16], data_byte_count > 4'd2);
        roll_b3 = roll_crc_window_byte(roll_b2[66:35], roll_b2[34:3], roll_b2[2:0],
                                       pcs_rxdata[31:24], data_byte_count > 4'd3);
        roll_b4 = roll_crc_window_byte(roll_b3[66:35], roll_b3[34:3], roll_b3[2:0],
                                       pcs_rxdata[39:32], data_byte_count > 4'd4);
        roll_b5 = roll_crc_window_byte(roll_b4[66:35], roll_b4[34:3], roll_b4[2:0],
                                       pcs_rxdata[47:40], data_byte_count > 4'd5);
        roll_b6 = roll_crc_window_byte(roll_b5[66:35], roll_b5[34:3], roll_b5[2:0],
                                       pcs_rxdata[55:48], data_byte_count > 4'd6);
        roll_b7 = roll_crc_window_byte(roll_b6[66:35], roll_b6[34:3], roll_b6[2:0],
                                       pcs_rxdata[63:56], data_byte_count > 4'd7);

        crc_next        = roll_b7[66:35];
        fcs_window_next = roll_b7[34:3];
        fcs_depth_next  = roll_b7[2:0];

        crc_final = crc_next ^ CRC_FINAL_XOR;
        // FCS is transmitted least-significant byte first on the Ethernet wire.
        expected_fcs_wire_order = {crc_final[7:0], crc_final[15:8],
                                   crc_final[23:16], crc_final[31:24]};

        fcs_match = eof_detect
                 && (fcs_depth_next == FCS_BYTES[2:0])
                 && (fcs_window_next == expected_fcs_wire_order);

        // SPEC_GAP: Suppressing rx_valid while frame_active_r is low would drop the
        // preamble/SFD word, so the SOF detection cycle is admitted into the stream.
        rx_valid_next = pcs_rx_valid
                     && pcs_block_lock
                     && (frame_active_r || sof_detect);
    end

endmodule
