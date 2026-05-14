`timescale 1ns/1ps

module tb_hdr_stripper;
    logic        clk_pcs;
    logic        rst_n;
    logic [63:0] rx_data;
    logic        rx_valid;
    logic        rx_sof;
    logic        rx_eof;
    logic [2:0]  rx_eof_bytes;

    logic [63:0] payload_data;
    logic        payload_valid;
    logic        payload_sof;
    logic        payload_eof;
    logic [2:0]  payload_eof_bytes;
    logic        frame_err;

    hdr_stripper dut (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_sof(rx_sof),
        .rx_eof(rx_eof),
        .rx_eof_bytes(rx_eof_bytes),
        .payload_data(payload_data),
        .payload_valid(payload_valid),
        .payload_sof(payload_sof),
        .payload_eof(payload_eof),
        .payload_eof_bytes(payload_eof_bytes),
        .frame_err(frame_err)
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

    task automatic drive_inputs (
        input logic [63:0] data_word,
        input logic        valid_word,
        input logic        sof_word,
        input logic        eof_word,
        input logic [2:0]  eof_bytes_word
    );
        @(negedge clk_pcs);
        rx_data      = data_word;
        rx_valid     = valid_word;
        rx_sof       = sof_word;
        rx_eof       = eof_word;
        rx_eof_bytes = eof_bytes_word;
        #1;
    endtask

    task automatic advance_cycle;
        @(posedge clk_pcs);
        #1;
    endtask

    task automatic expect_payload (
        input string       label,
        input logic [63:0] exp_data,
        input logic        exp_valid,
        input logic        exp_sof,
        input logic        exp_eof,
        input logic [2:0]  exp_eof_bytes,
        input logic        exp_err
    );
        if ((payload_data !== exp_data) ||
            (payload_valid !== exp_valid) ||
            (payload_sof !== exp_sof) ||
            (payload_eof !== exp_eof) ||
            (frame_err !== exp_err) ||
            (exp_eof && (payload_eof_bytes !== exp_eof_bytes))) begin
            $error("%s mismatch: data=0x%016h/0x%016h valid=%0b/%0b sof=%0b/%0b eof=%0b/%0b eof_bytes=%0d/%0d err=%0b/%0b",
                   label,
                   payload_data, exp_data,
                   payload_valid, exp_valid,
                   payload_sof, exp_sof,
                   payload_eof, exp_eof,
                   payload_eof_bytes, exp_eof_bytes,
                   frame_err, exp_err);
            $fatal;
        end
    endtask

    task automatic drive_and_expect (
        input string       label,
        input logic [63:0] data_word,
        input logic        valid_word,
        input logic        sof_word,
        input logic        eof_word,
        input logic [2:0]  eof_bytes_word,
        input logic [63:0] exp_data,
        input logic        exp_valid,
        input logic        exp_sof,
        input logic        exp_eof,
        input logic [2:0]  exp_eof_bytes,
        input logic        exp_err
    );
        drive_inputs(data_word, valid_word, sof_word, eof_word, eof_bytes_word);
        expect_payload(label, exp_data, exp_valid, exp_sof, exp_eof, exp_eof_bytes, exp_err);
        advance_cycle();
    endtask

    task automatic drive_idle;
        drive_and_expect("idle", 64'h0, 1'b0, 1'b0, 1'b0, 3'h0,
                         64'h0, 1'b0, 1'b0, 1'b0, 3'h0, 1'b0);
    endtask

    task automatic reset_dut;
        @(negedge clk_pcs);
        rst_n        = 1'b0;
        rx_data      = 64'h0;
        rx_valid     = 1'b0;
        rx_sof       = 1'b0;
        rx_eof       = 1'b0;
        rx_eof_bytes = 3'h0;
        repeat (2) @(posedge clk_pcs);
        @(negedge clk_pcs);
        rst_n        = 1'b1;
        rx_data      = 64'h0;
        rx_valid     = 1'b0;
        rx_sof       = 1'b0;
        rx_eof       = 1'b0;
        rx_eof_bytes = 3'h0;
        #1;
        advance_cycle();
    endtask

    task automatic send_valid_header_prefix (
        input logic [15:0] ethertype,
        input logic [3:0]  ihl,
        input logic [7:0]  protocol
    );
        logic header_err;
        logic protocol_or_header_err;
        begin
        header_err = (ethertype != 16'h0800) || (ihl != 4'h5);
        protocol_or_header_err = header_err || (protocol != 8'h11);

        drive_and_expect("preamble", 64'hD5_55_55_55_55_55_55_55, 1'b1, 1'b1, 1'b0, 3'h0,
                         64'h0, 1'b0, 1'b0, 1'b0, 3'h0, 1'b0);
        drive_and_expect("eth0", pack8(8'h00, 8'h11, 8'h22, 8'h33,
                                       8'h44, 8'h55, 8'h66, 8'h77),
                         1'b1, 1'b0, 1'b0, 3'h0,
                         64'h0, 1'b0, 1'b0, 1'b0, 3'h0, 1'b0);
        drive_and_expect("eth/ip0", pack8(8'h88, 8'h99, 8'hAA, 8'hBB,
                                          ethertype[15:8], ethertype[7:0],
                                          {ihl, 4'h0}, 8'h00),
                         1'b1, 1'b0, 1'b0, 3'h0,
                         64'h0, 1'b0, 1'b0, 1'b0, 3'h0,
                         header_err);
        drive_and_expect("ip1", pack8(8'h00, 8'h2C, 8'h00, 8'h00,
                                      8'h40, 8'h00, 8'h40, protocol),
                         1'b1, 1'b0, 1'b0, 3'h0,
                         64'h0, 1'b0, 1'b0, 1'b0, 3'h0,
                         protocol_or_header_err);
        drive_and_expect("ip2", pack8(8'h00, 8'h00, 8'h0A, 8'h00,
                                      8'h00, 8'h01, 8'h0A, 8'h00),
                         1'b1, 1'b0, 1'b0, 3'h0,
                         64'h0, 1'b0, 1'b0, 1'b0, 3'h0,
                         protocol_or_header_err);
        drive_and_expect("udp0", pack8(8'h00, 8'h02, 8'h23, 8'h28,
                                       8'h23, 8'h29, 8'h00, 8'h18),
                         1'b1, 1'b0, 1'b0, 3'h0,
                         64'h0, 1'b0, 1'b0, 1'b0, 3'h0,
                         protocol_or_header_err);
        end
    endtask

    task automatic send_nominal_frame;
        send_valid_header_prefix(16'h0800, 4'h5, 8'h11);

        drive_and_expect("payload prealign", pack8(8'h00, 8'h00,
                                                   8'h12, 8'h34, 8'h00, 8'h00, 8'h00, 8'h00),
                         1'b1, 1'b0, 1'b0, 3'h0,
                         64'h0, 1'b0, 1'b0, 1'b0, 3'h0, 1'b0);

        drive_and_expect("payload word0", pack8(8'h00, 8'h00, 8'h01, 8'h55,
                                                8'h00, 8'h00, 8'h00, 8'h00),
                         1'b1, 1'b0, 1'b0, 3'h0,
                         pack8(8'h12, 8'h34, 8'h00, 8'h00,
                               8'h00, 8'h00, 8'h00, 8'h00),
                         1'b1, 1'b1, 1'b0, 3'h0, 1'b0);

        drive_and_expect("payload word1", pack8(8'h00, 8'h00, 8'h00, 8'h64,
                                                8'h00, 8'h00, 8'h00, 8'h64),
                         1'b1, 1'b0, 1'b0, 3'h0,
                         pack8(8'h01, 8'h55, 8'h00, 8'h00,
                               8'h00, 8'h00, 8'h00, 8'h00),
                         1'b1, 1'b0, 1'b0, 3'h0, 1'b0);

        drive_and_expect("payload word2 eof", pack8(8'h42, 8'h00, 8'h00, 8'h00,
                                                    8'h00, 8'h00, 8'h00, 8'h00),
                         1'b1, 1'b0, 1'b1, 3'd2,
                         pack8(8'h00, 8'h64, 8'h00, 8'h00,
                               8'h00, 8'h64, 8'h42, 8'h00),
                         1'b1, 1'b0, 1'b1, 3'h0, 1'b0);
    endtask

    task automatic send_short_frame;
        drive_and_expect("short preamble", 64'hD5_55_55_55_55_55_55_55, 1'b1, 1'b1, 1'b0, 3'h0,
                         64'h0, 1'b0, 1'b0, 1'b0, 3'h0, 1'b0);
        drive_and_expect("short eof", pack8(8'h00, 8'h11, 8'h22, 8'h33,
                                            8'h44, 8'h55, 8'h66, 8'h77),
                         1'b1, 1'b0, 1'b1, 3'h0,
                         64'h0, 1'b0, 1'b0, 1'b0, 3'h0, 1'b1);
    endtask

    always #3.2 clk_pcs = ~clk_pcs;

    initial begin
        $dumpfile("tb/hdr_stripper_smoke.vcd");
        $dumpvars(0, tb_hdr_stripper);

        clk_pcs      = 1'b0;
        rst_n        = 1'b0;
        rx_data      = 64'h0;
        rx_valid     = 1'b0;
        rx_sof       = 1'b0;
        rx_eof       = 1'b0;
        rx_eof_bytes = 3'h0;

        reset_dut();
        drive_idle();
        send_nominal_frame();

        reset_dut();
        send_valid_header_prefix(16'h0806, 4'h5, 8'h11);

        reset_dut();
        send_valid_header_prefix(16'h0800, 4'h6, 8'h11);

        reset_dut();
        send_valid_header_prefix(16'h0800, 4'h5, 8'h06);

        reset_dut();
        send_short_frame();

        $finish;
    end

endmodule
