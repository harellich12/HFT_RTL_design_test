`timescale 1ns/1ps

module tb_pkt_formatter;
    localparam int SYMBOL_ID_WIDTH = 10;
    localparam int PRICE_WIDTH     = 64;
    localparam int QTY_WIDTH       = 32;

    localparam logic [63:0] PREAMBLE_SFD_WORD = 64'hD5_55_55_55_55_55_55_55;
    localparam logic [63:0] TERMINATE_WORD    = 64'h07_07_07_07_07_07_07_FD;

    logic        clk_pcs;
    logic        rst_n;
    logic [SYMBOL_ID_WIDTH-1:0] symbol_idx;
    logic [PRICE_WIDTH-1:0]     price;
    logic [QTY_WIDTH-1:0]       quantity;
    logic [7:0]                 side;
    logic                       risk_pass;
    logic                       risk_kill;
    logic                       tx_abort;

    logic [63:0] pcs_txdata;
    logic [7:0]  pcs_txctl;
    logic        pcs_tx_valid;
    logic        pcs_tx_sof;
    logic        pcs_tx_eof;
    logic [2:0]  pcs_tx_eof_bytes;
    logic [15:0] tx_launch_drops;
    logic [15:0] tx_stomps;

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
        .tx_abort(tx_abort),
        .pcs_txdata(pcs_txdata),
        .pcs_txctl(pcs_txctl),
        .pcs_tx_valid(pcs_tx_valid),
        .pcs_tx_sof(pcs_tx_sof),
        .pcs_tx_eof(pcs_tx_eof),
        .pcs_tx_eof_bytes(pcs_tx_eof_bytes),
        .tx_launch_drops(tx_launch_drops),
        .tx_stomps(tx_stomps)
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

    function automatic logic [7:0] bitrev8 (
        input logic [7:0] byte_in
    );
        bitrev8 = {byte_in[0], byte_in[1], byte_in[2], byte_in[3],
                   byte_in[4], byte_in[5], byte_in[6], byte_in[7]};
    endfunction

    // Convert the CRC register to IEEE 802.3 wire order: MSB byte first,
    // bit-reversed per byte. Result [7:0] is the first byte on the wire, which
    // makes the packed value equal the standard software CRC-32 residue.
    function automatic logic [31:0] fcs_wire_bytes (
        input logic [31:0] crc_final
    );
        fcs_wire_bytes = {bitrev8(crc_final[7:0]), bitrev8(crc_final[15:8]),
                          bitrev8(crc_final[23:16]), bitrev8(crc_final[31:24])};
    endfunction

    // FCS scope is DA through pad: template words, field words, and the low
    // half of the FCS word. The preamble and terminate words are excluded.
    function automatic logic [31:0] expected_fcs (
        input logic [63:0] word1,
        input logic [63:0] word2,
        input logic [63:0] word3,
        input logic [63:0] word4,
        input logic [63:0] word5,
        input logic [63:0] word6,
        input logic [63:0] word7,
        input logic [31:0] tail
    );
        logic [31:0] crc_tmp;
        begin
            crc_tmp      = 32'hFFFFFFFF;
            crc_tmp      = crc32_word(crc_tmp, word1);
            crc_tmp      = crc32_word(crc_tmp, word2);
            crc_tmp      = crc32_word(crc_tmp, word3);
            crc_tmp      = crc32_word(crc_tmp, word4);
            crc_tmp      = crc32_word(crc_tmp, word5);
            crc_tmp      = crc32_word(crc_tmp, word6);
            crc_tmp      = crc32_word(crc_tmp, word7);
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
        logic [7:0] expected_ctl;
        @(posedge clk_pcs);
        #0.1;
        expected_ctl = expected_eof ? 8'hFF : 8'h00;
        if ((pcs_txdata !== expected_data)
         || (pcs_tx_valid !== expected_valid)
         || (pcs_tx_sof !== expected_sof)
         || (pcs_tx_eof !== expected_eof)
         || (pcs_tx_eof_bytes !== expected_eof_bytes)
         || (pcs_txctl !== expected_ctl)) begin
            $error("%s mismatch: data=0x%016h/0x%016h valid=%0b/%0b sof=%0b/%0b eof=%0b/%0b eof_bytes=%0d/%0d ctl=0x%02h/0x%02h",
                   name,
                   pcs_txdata, expected_data,
                   pcs_tx_valid, expected_valid,
                   pcs_tx_sof, expected_sof,
                   pcs_tx_eof, expected_eof,
                   pcs_tx_eof_bytes, expected_eof_bytes,
                   pcs_txctl, expected_ctl);
            $fatal;
        end
    endtask

    task automatic expect_count (
        input logic [15:0] actual,
        input logic [15:0] expected,
        input string       name
    );
        if (actual !== expected) begin
            $error("%s mismatch: actual=%0d expected=%0d", name, actual, expected);
            $fatal;
        end
    endtask

    always #3.2 clk_pcs = ~clk_pcs;

    initial begin
        logic [63:0] field_word6;
        logic [63:0] field_word7;
        logic [63:0] fcs_word;
        logic [63:0] fcs_word_stomped;
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
        tx_abort   = 1'b0;

        repeat (3) @(posedge clk_pcs);
        rst_n = 1'b1;

        @(negedge clk_pcs);
        symbol_idx = 10'h155;
        price      = 64'h0102_0304_0506_0708;
        quantity   = 32'h0000_03E8;
        side       = 8'h42;
        risk_pass  = 1'b1;

        field_word6 = 64'h0403_0201_5501_0000;
        field_word7 = 64'hE803_0000_0807_0605;
        fcs = fcs_wire_bytes(expected_fcs(64'h7766_5544_3322_1100,
                                          64'h0045_0008_BBAA_9988,
                                          64'h1140_0040_0000_2C00,
                                          64'h000A_0100_000A_BF26,
                                          64'h1800_2923_2823_0200,
                                          field_word6,
                                          field_word7,
                                          32'h0000_0042));

        // Known-answer check against an independent IEEE 802.3 reference
        // (Python zlib.crc32 of the 60 frame bytes above).
        if (fcs !== 32'hAF5CF5A6) begin
            $error("FCS known-answer mismatch: computed=0x%08h expected=0xAF5CF5A6", fcs);
            $fatal;
        end

        fcs_word         = {fcs, 24'h0, 8'h42};
        fcs_word_stomped = {~fcs, 24'h0, 8'h42};

        // Frame A: nominal launch, with a busy re-launch injected mid-frame
        // that must be dropped and counted, not queued and not restarted.
        expect_tx(PREAMBLE_SFD_WORD,        1'b1, 1'b1, 1'b0, 3'h0, "A preamble launch");

        @(negedge clk_pcs);
        risk_pass = 1'b0;

        expect_tx(64'h7766_5544_3322_1100,  1'b1, 1'b0, 1'b0, 3'h0, "A word1");
        expect_tx(64'h0045_0008_BBAA_9988,  1'b1, 1'b0, 1'b0, 3'h0, "A word2");

        @(negedge clk_pcs);
        risk_pass = 1'b1;

        expect_tx(64'h1140_0040_0000_2C00,  1'b1, 1'b0, 1'b0, 3'h0, "A word3 busy relaunch");

        @(negedge clk_pcs);
        risk_pass = 1'b0;

        expect_tx(64'h000A_0100_000A_BF26,  1'b1, 1'b0, 1'b0, 3'h0, "A word4");
        expect_tx(64'h1800_2923_2823_0200,  1'b1, 1'b0, 1'b0, 3'h0, "A word5");
        expect_tx(field_word6,              1'b1, 1'b0, 1'b0, 3'h0, "A word6 fields");
        expect_tx(field_word7,              1'b1, 1'b0, 1'b0, 3'h0, "A word7 fields");
        expect_tx(fcs_word,                 1'b1, 1'b0, 1'b0, 3'h0, "A word8 fcs");
        expect_tx(TERMINATE_WORD,           1'b1, 1'b0, 1'b1, 3'h0, "A word9 terminate");
        expect_tx(64'h0,                    1'b0, 1'b0, 1'b0, 3'h0, "A post-frame idle");

        expect_count(tx_launch_drops, 16'd1, "tx_launch_drops after busy relaunch");
        expect_count(tx_stomps,       16'd0, "tx_stomps after frame A");

        // Frame B: tx_abort mid-frame corrupts the FCS (stomp); the frame
        // still completes as a fixed-length wire-legal burst.
        @(negedge clk_pcs);
        risk_pass = 1'b1;

        expect_tx(PREAMBLE_SFD_WORD,        1'b1, 1'b1, 1'b0, 3'h0, "B preamble launch");

        @(negedge clk_pcs);
        risk_pass = 1'b0;

        expect_tx(64'h7766_5544_3322_1100,  1'b1, 1'b0, 1'b0, 3'h0, "B word1");
        expect_tx(64'h0045_0008_BBAA_9988,  1'b1, 1'b0, 1'b0, 3'h0, "B word2");

        @(negedge clk_pcs);
        tx_abort = 1'b1;

        expect_tx(64'h1140_0040_0000_2C00,  1'b1, 1'b0, 1'b0, 3'h0, "B word3 abort asserted");

        @(negedge clk_pcs);
        tx_abort = 1'b0;

        expect_tx(64'h000A_0100_000A_BF26,  1'b1, 1'b0, 1'b0, 3'h0, "B word4");
        expect_tx(64'h1800_2923_2823_0200,  1'b1, 1'b0, 1'b0, 3'h0, "B word5");
        expect_tx(field_word6,              1'b1, 1'b0, 1'b0, 3'h0, "B word6 fields");
        expect_tx(field_word7,              1'b1, 1'b0, 1'b0, 3'h0, "B word7 fields");
        expect_tx(fcs_word_stomped,         1'b1, 1'b0, 1'b0, 3'h0, "B word8 stomped fcs");
        expect_tx(TERMINATE_WORD,           1'b1, 1'b0, 1'b1, 3'h0, "B word9 terminate");
        expect_tx(64'h0,                    1'b0, 1'b0, 1'b0, 3'h0, "B post-frame idle");

        expect_count(tx_stomps,       16'd1, "tx_stomps after abort");
        expect_count(tx_launch_drops, 16'd1, "tx_launch_drops unchanged by abort");

        // Frame C: risk_kill decided mid-frame must not truncate the frame
        // already in flight; its FCS stays valid.
        @(negedge clk_pcs);
        risk_pass = 1'b1;

        expect_tx(PREAMBLE_SFD_WORD,        1'b1, 1'b1, 1'b0, 3'h0, "C preamble launch");

        @(negedge clk_pcs);
        risk_pass = 1'b0;

        expect_tx(64'h7766_5544_3322_1100,  1'b1, 1'b0, 1'b0, 3'h0, "C word1");

        @(negedge clk_pcs);
        risk_kill = 1'b1;

        expect_tx(64'h0045_0008_BBAA_9988,  1'b1, 1'b0, 1'b0, 3'h0, "C word2 kill asserted");

        @(negedge clk_pcs);
        risk_kill = 1'b0;

        expect_tx(64'h1140_0040_0000_2C00,  1'b1, 1'b0, 1'b0, 3'h0, "C word3");
        expect_tx(64'h000A_0100_000A_BF26,  1'b1, 1'b0, 1'b0, 3'h0, "C word4");
        expect_tx(64'h1800_2923_2823_0200,  1'b1, 1'b0, 1'b0, 3'h0, "C word5");
        expect_tx(field_word6,              1'b1, 1'b0, 1'b0, 3'h0, "C word6 fields");
        expect_tx(field_word7,              1'b1, 1'b0, 1'b0, 3'h0, "C word7 fields");
        expect_tx(fcs_word,                 1'b1, 1'b0, 1'b0, 3'h0, "C word8 fcs good");
        expect_tx(TERMINATE_WORD,           1'b1, 1'b0, 1'b1, 3'h0, "C word9 terminate");
        expect_tx(64'h0,                    1'b0, 1'b0, 1'b0, 3'h0, "C post-frame idle");

        // Kill at idle: no launch, output stays idle.
        @(negedge clk_pcs);
        risk_kill = 1'b1;

        expect_tx(64'h0, 1'b0, 1'b0, 1'b0, 3'h0, "kill at idle no launch");

        @(negedge clk_pcs);
        risk_kill = 1'b0;

        expect_tx(64'h0, 1'b0, 1'b0, 1'b0, 3'h0, "kill idle");

        // Abort at idle: no effect and no count.
        @(negedge clk_pcs);
        tx_abort = 1'b1;

        expect_tx(64'h0, 1'b0, 1'b0, 1'b0, 3'h0, "abort at idle no effect");

        @(negedge clk_pcs);
        tx_abort = 1'b0;

        expect_count(tx_stomps, 16'd1, "tx_stomps unchanged by idle abort");

        repeat (2) @(posedge clk_pcs);
        $finish;
    end
endmodule
