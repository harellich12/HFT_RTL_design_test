`timescale 1ns/1ps

module tb_pkt_formatter;
    localparam int SYMBOL_ID_WIDTH = 10;
    localparam int PRICE_WIDTH     = 64;
    localparam int QTY_WIDTH       = 32;

    logic        clk_pcs;
    logic        rst_n;
    logic [SYMBOL_ID_WIDTH-1:0] symbol_idx;
    logic [PRICE_WIDTH-1:0]     price;
    logic [QTY_WIDTH-1:0]       quantity;
    logic [7:0]                 side;
    logic                       risk_pass;
    logic                       risk_kill;

    logic [63:0] pcs_txdata;
    logic [7:0]  pcs_txctl;
    logic        pcs_tx_valid;
    logic        pcs_tx_sof;
    logic        pcs_tx_eof;
    logic [2:0]  pcs_tx_eof_bytes;

    pkt_formatter #(
        .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH),
        .PRICE_WIDTH(PRICE_WIDTH),
        .QTY_WIDTH(QTY_WIDTH)
    ) dut (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .symbol_idx(symbol_idx),
        .price(price),
        .quantity(quantity),
        .side(side),
        .risk_pass(risk_pass),
        .risk_kill(risk_kill),
        .pcs_txdata(pcs_txdata),
        .pcs_txctl(pcs_txctl),
        .pcs_tx_valid(pcs_tx_valid),
        .pcs_tx_sof(pcs_tx_sof),
        .pcs_tx_eof(pcs_tx_eof),
        .pcs_tx_eof_bytes(pcs_tx_eof_bytes)
    );

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

    function automatic logic [31:0] crc32_word (
        input logic [31:0] crc_in,
        input logic [63:0] data_word
    );
        logic [31:0] crc_tmp;
        begin
            crc_tmp = crc_in;
            for (int byte_idx = 0; byte_idx < 8; byte_idx++) begin
                crc_tmp = crc32_byte(crc_tmp, data_word[byte_idx * 8 +: 8]);
            end
            crc32_word = crc_tmp;
        end
    endfunction

    function automatic logic [31:0] crc32_four_bytes (
        input logic [31:0] crc_in,
        input logic [31:0] data_word
    );
        logic [31:0] crc_tmp;
        begin
            crc_tmp = crc_in;
            for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
                crc_tmp = crc32_byte(crc_tmp, data_word[byte_idx * 8 +: 8]);
            end
            crc32_four_bytes = crc_tmp;
        end
    endfunction

    function automatic logic [31:0] expected_fcs (
        input logic [63:0] word0,
        input logic [63:0] word1,
        input logic [63:0] word2,
        input logic [63:0] word3,
        input logic [63:0] word4,
        input logic [63:0] word5,
        input logic [63:0] word6,
        input logic [31:0] tail
    );
        logic [31:0] crc_tmp;
        begin
            crc_tmp      = 32'hFFFFFFFF;
            crc_tmp      = crc32_word(crc_tmp, word0);
            crc_tmp      = crc32_word(crc_tmp, word1);
            crc_tmp      = crc32_word(crc_tmp, word2);
            crc_tmp      = crc32_word(crc_tmp, word3);
            crc_tmp      = crc32_word(crc_tmp, word4);
            crc_tmp      = crc32_word(crc_tmp, word5);
            crc_tmp      = crc32_word(crc_tmp, word6);
            crc_tmp      = crc32_four_bytes(crc_tmp, tail);
            expected_fcs = crc_tmp ^ 32'hFFFFFFFF;
        end
    endfunction

    task automatic expect_tx (
        input logic [63:0] expected_data,
        input logic        expected_valid,
        input logic        expected_sof,
        input logic        expected_eof,
        input logic [2:0]  expected_eof_bytes,
        input string       name
    );
        @(posedge clk_pcs);
        #0.1;
        if ((pcs_txdata !== expected_data)
         || (pcs_tx_valid !== expected_valid)
         || (pcs_tx_sof !== expected_sof)
         || (pcs_tx_eof !== expected_eof)
         || (pcs_tx_eof_bytes !== expected_eof_bytes)
         || (pcs_txctl !== 8'h00)) begin
            $error("%s mismatch: data=0x%016h/0x%016h valid=%0b/%0b sof=%0b/%0b eof=%0b/%0b eof_bytes=%0d/%0d ctl=0x%02h",
                   name,
                   pcs_txdata, expected_data,
                   pcs_tx_valid, expected_valid,
                   pcs_tx_sof, expected_sof,
                   pcs_tx_eof, expected_eof,
                   pcs_tx_eof_bytes, expected_eof_bytes,
                   pcs_txctl);
            $fatal;
        end
    endtask

    always #3.2 clk_pcs = ~clk_pcs;

    initial begin
        logic [63:0] expected_word5;
        logic [63:0] expected_word6;
        logic [63:0] expected_word7;
        logic [31:0] fcs;

        $dumpfile("tb/pkt_formatter_smoke.vcd");
        $dumpvars(0, tb_pkt_formatter);

        clk_pcs    = 1'b0;
        rst_n      = 1'b0;
        symbol_idx = '0;
        price      = '0;
        quantity   = '0;
        side       = 8'h0;
        risk_pass  = 1'b0;
        risk_kill  = 1'b0;

        repeat (3) @(posedge clk_pcs);
        rst_n = 1'b1;

        @(negedge clk_pcs);
        symbol_idx = 10'h155;
        price      = 64'h0102_0304_0506_0708;
        quantity   = 32'h0000_03E8;
        side       = 8'h42;
        risk_pass  = 1'b1;

        expected_word5 = 64'h0403_0201_5501_0000;
        expected_word6 = 64'hE803_0000_0807_0605;
        fcs = expected_fcs(64'h7766_5544_3322_1100,
                           64'h0045_0008_BBAA_9988,
                           64'h1140_0040_0000_2C00,
                           64'h000A_0100_000A_BF26,
                           64'h1800_2923_2823_0200,
                           expected_word5,
                           expected_word6,
                           32'h0000_0042);
        expected_word7 = {fcs, 24'h0, 8'h42};

        expect_tx(64'h7766_5544_3322_1100, 1'b1, 1'b1, 1'b0, 3'h0, "word0 launch");

        @(negedge clk_pcs);
        risk_pass = 1'b0;

        expect_tx(64'h0045_0008_BBAA_9988, 1'b1, 1'b0, 1'b0, 3'h0, "word1");
        expect_tx(64'h1140_0040_0000_2C00, 1'b1, 1'b0, 1'b0, 3'h0, "word2");
        expect_tx(64'h000A_0100_000A_BF26, 1'b1, 1'b0, 1'b0, 3'h0, "word3");
        expect_tx(64'h1800_2923_2823_0200, 1'b1, 1'b0, 1'b0, 3'h0, "word4");
        expect_tx(expected_word5,           1'b1, 1'b0, 1'b0, 3'h0, "word5 fields");
        expect_tx(expected_word6,           1'b1, 1'b0, 1'b0, 3'h0, "word6 fields");
        expect_tx(expected_word7,           1'b1, 1'b0, 1'b1, 3'h0, "word7 fcs");
        expect_tx(64'h0,                    1'b0, 1'b0, 1'b0, 3'h0, "post-frame idle");

        @(negedge clk_pcs);
        symbol_idx = 10'h02a;
        price      = 64'h1111_2222_3333_4444;
        quantity   = 32'h0000_0001;
        side       = 8'h53;
        risk_pass  = 1'b1;
        risk_kill  = 1'b1;

        expect_tx(64'h0, 1'b0, 1'b0, 1'b0, 3'h0, "kill suppress launch");

        @(negedge clk_pcs);
        risk_pass = 1'b0;
        risk_kill = 1'b0;

        expect_tx(64'h0, 1'b0, 1'b0, 1'b0, 3'h0, "kill idle");

        repeat (2) @(posedge clk_pcs);
        $finish;
    end
endmodule
