`timescale 1ns/1ps

module tb_mac_shim;
    logic        clk_pcs;
    logic        rst_n;
    logic [63:0] pcs_rxdata;
    logic [7:0]  pcs_rxctl;
    logic        pcs_rx_valid;
    logic        pcs_block_lock;

    logic [63:0] rx_data;
    logic        rx_valid;
    logic        rx_sof;
    logic        rx_eof;
    logic [2:0]  rx_eof_bytes;
    logic        mac_fcs_valid;

    localparam logic [63:0] PREAMBLE_SFD_WORD = 64'hD5_55_55_55_55_55_55_55;

    mac_shim dut (
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

    function automatic logic [63:0] pack8 (
        input logic [7:0] b0,
        input logic [7:0] b1,
        input logic [7:0] b2,
        input logic [7:0] b3,
        input logic [7:0] b4,
        input logic [7:0] b5,
        input logic [7:0] b6,
        input logic [7:0] b7
    );
        pack8 = {b7, b6, b5, b4, b3, b2, b1, b0};
    endfunction

    function automatic logic [31:0] crc32_bit (
        input logic [31:0] crc_in,
        input logic        data_bit
    );
        logic xor_bit;
        begin
            xor_bit   = crc_in[31] ^ data_bit;
            crc32_bit = {crc_in[30:0], 1'b0} ^ ({32{xor_bit}} & 32'h04C11DB7);
        end
    endfunction

    function automatic logic [31:0] crc32_byte (
        input logic [31:0] crc_in,
        input logic [7:0]  data_byte
    );
        logic [31:0] crc_tmp;
        begin
            crc_tmp = crc_in;
            for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
                crc_tmp = crc32_bit(crc_tmp, data_byte[bit_idx]);
            end
            crc32_byte = crc_tmp;
        end
    endfunction

    function automatic logic [31:0] expected_fcs_10b (
        input logic [7:0] b0,
        input logic [7:0] b1,
        input logic [7:0] b2,
        input logic [7:0] b3,
        input logic [7:0] b4,
        input logic [7:0] b5,
        input logic [7:0] b6,
        input logic [7:0] b7,
        input logic [7:0] b8,
        input logic [7:0] b9
    );
        logic [31:0] crc_tmp;
        begin
            crc_tmp = 32'hFFFFFFFF;
            crc_tmp = crc32_byte(crc_tmp, b0);
            crc_tmp = crc32_byte(crc_tmp, b1);
            crc_tmp = crc32_byte(crc_tmp, b2);
            crc_tmp = crc32_byte(crc_tmp, b3);
            crc_tmp = crc32_byte(crc_tmp, b4);
            crc_tmp = crc32_byte(crc_tmp, b5);
            crc_tmp = crc32_byte(crc_tmp, b6);
            crc_tmp = crc32_byte(crc_tmp, b7);
            crc_tmp = crc32_byte(crc_tmp, b8);
            crc_tmp = crc32_byte(crc_tmp, b9);
            expected_fcs_10b = crc_tmp ^ 32'hFFFFFFFF;
        end
    endfunction

    task automatic drive_idle;
        @(negedge clk_pcs);
        pcs_rxdata  = 64'h0;
        pcs_rxctl   = 8'h00;
        pcs_rx_valid = 1'b0;
    endtask

    task automatic drive_word (
        input logic [63:0] data_word,
        input logic [7:0]  ctl_word
    );
        @(negedge clk_pcs);
        pcs_rxdata  = data_word;
        pcs_rxctl   = ctl_word;
        pcs_rx_valid = 1'b1;
    endtask

    task automatic expect_outputs (
        input string       label,
        input logic [63:0] exp_data,
        input logic        exp_valid,
        input logic        exp_sof,
        input logic        exp_eof,
        input logic [2:0]  exp_eof_bytes,
        input logic        exp_fcs_valid
    );
        @(posedge clk_pcs);
        #1;
        if ((rx_data !== exp_data) ||
            (rx_valid !== exp_valid) ||
            (rx_sof !== exp_sof) ||
            (rx_eof !== exp_eof) ||
            (rx_eof_bytes !== exp_eof_bytes) ||
            (mac_fcs_valid !== exp_fcs_valid)) begin
            $error("%s mismatch: data=0x%016h/0x%016h valid=%0b/%0b sof=%0b/%0b eof=%0b/%0b eof_bytes=%0d/%0d fcs=%0b/%0b",
                   label,
                   rx_data, exp_data,
                   rx_valid, exp_valid,
                   rx_sof, exp_sof,
                   rx_eof, exp_eof,
                   rx_eof_bytes, exp_eof_bytes,
                   mac_fcs_valid, exp_fcs_valid);
            $fatal;
        end
    endtask

    task automatic send_frame (
        input string label,
        input logic  corrupt_fcs
    );
        logic [31:0] fcs;
        logic [31:0] fcs_to_send;
        logic [63:0] word0;
        logic [63:0] word1;
        logic [63:0] word2;
        begin
            fcs = expected_fcs_10b(8'h01, 8'h23, 8'h45, 8'h67,
                                   8'h89, 8'hAB, 8'hCD, 8'hEF,
                                   8'h55, 8'hAA);
            fcs_to_send = corrupt_fcs ? (fcs ^ 32'h00000001) : fcs;

            word0 = PREAMBLE_SFD_WORD;
            word1 = pack8(8'h01, 8'h23, 8'h45, 8'h67,
                          8'h89, 8'hAB, 8'hCD, 8'hEF);
            word2 = pack8(8'h55, 8'hAA,
                          fcs_to_send[7:0],
                          fcs_to_send[15:8],
                          fcs_to_send[23:16],
                          fcs_to_send[31:24],
                          8'h00,
                          8'h00);

            drive_word(word0, 8'h00);
            expect_outputs({label, " sof"}, word0, 1'b1, 1'b1, 1'b0, 3'h0, 1'b0);

            drive_word(word1, 8'h00);
            expect_outputs({label, " data"}, word1, 1'b1, 1'b0, 1'b0, 3'h0, 1'b0);

            drive_word(word2, 8'h40);
            expect_outputs({label, " eof"}, word2, 1'b1, 1'b0, 1'b1, 3'h6, !corrupt_fcs);

            drive_idle();
            expect_outputs({label, " idle"}, 64'h0, 1'b0, 1'b0, 1'b0, 3'h0, 1'b0);
        end
    endtask

    always #3.2 clk_pcs = ~clk_pcs;

    initial begin
        $dumpfile("tb/mac_shim_smoke.vcd");
        $dumpvars(0, tb_mac_shim);

        clk_pcs        = 1'b0;
        rst_n          = 1'b0;
        pcs_rxdata     = 64'h0;
        pcs_rxctl      = 8'h00;
        pcs_rx_valid   = 1'b0;
        pcs_block_lock = 1'b0;

        repeat (3) @(posedge clk_pcs);
        rst_n = 1'b1;

        drive_word(PREAMBLE_SFD_WORD, 8'h00);
        expect_outputs("block lock low", PREAMBLE_SFD_WORD, 1'b0, 1'b0, 1'b0, 3'h0, 1'b0);

        @(negedge clk_pcs);
        pcs_block_lock = 1'b1;
        pcs_rx_valid   = 1'b0;
        pcs_rxdata     = 64'h0;
        pcs_rxctl      = 8'h00;
        expect_outputs("block lock idle", 64'h0, 1'b0, 1'b0, 1'b0, 3'h0, 1'b0);

        send_frame("good frame", 1'b0);
        repeat (2) drive_idle();

        send_frame("bad frame", 1'b1);
        repeat (2) drive_idle();

        $finish;
    end

endmodule
