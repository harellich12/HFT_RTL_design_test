`timescale 1ns/1ps

module tb_field_aligner;
    logic        clk_pcs;
    logic        rst_n;
    logic [63:0] payload_data;
    logic        payload_valid;
    logic        payload_sof;
    logic        payload_eof;
    logic        frame_err;

    logic [15:0] msg_type;
    logic [63:0] instrument_id;
    logic [63:0] price;
    logic [31:0] quantity;
    logic [7:0]  side;
    logic        field_valid;
    logic        field_err;
    logic [15:0] alt_msg_type;
    logic [63:0] alt_instrument_id;
    logic [63:0] alt_price;
    logic [31:0] alt_quantity;
    logic [7:0]  alt_side;
    logic        alt_field_valid;
    logic        alt_field_err;

    field_aligner dut (
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

    field_aligner #(
        .MSG_TYPE_OFFSET(1),
        .INSTRUMENT_ID_OFFSET(3),
        .PRICE_OFFSET(11),
        .QUANTITY_OFFSET(19),
        .SIDE_OFFSET(23)
    ) alt_dut (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .payload_data(payload_data),
        .payload_valid(payload_valid),
        .payload_sof(payload_sof),
        .payload_eof(payload_eof),
        .frame_err(frame_err),
        .msg_type(alt_msg_type),
        .instrument_id(alt_instrument_id),
        .price(alt_price),
        .quantity(alt_quantity),
        .side(alt_side),
        .field_valid(alt_field_valid),
        .field_err(alt_field_err)
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

    task automatic expect_equal64 (
        input logic [63:0] actual,
        input logic [63:0] expected,
        input string       name
    );
        if (actual !== expected) begin
            $error("%s mismatch: actual=0x%016h expected=0x%016h",
                   name, actual, expected);
            $fatal;
        end
    endtask

    task automatic expect_equal32 (
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string       name
    );
        if (actual !== expected) begin
            $error("%s mismatch: actual=0x%08h expected=0x%08h",
                   name, actual, expected);
            $fatal;
        end
    endtask

    task automatic expect_equal16 (
        input logic [15:0] actual,
        input logic [15:0] expected,
        input string       name
    );
        if (actual !== expected) begin
            $error("%s mismatch: actual=0x%04h expected=0x%04h",
                   name, actual, expected);
            $fatal;
        end
    endtask

    task automatic expect_equal8 (
        input logic [7:0] actual,
        input logic [7:0] expected,
        input string      name
    );
        if (actual !== expected) begin
            $error("%s mismatch: actual=0x%02h expected=0x%02h",
                   name, actual, expected);
            $fatal;
        end
    endtask

    always #3.2 clk_pcs = ~clk_pcs;

    initial begin
        $dumpfile("tb/field_aligner_smoke.vcd");
        $dumpvars(0, tb_field_aligner);

        clk_pcs       = 1'b0;
        rst_n         = 1'b0;
        payload_data  = 64'h0;
        payload_valid = 1'b0;
        payload_sof   = 1'b0;
        payload_eof   = 1'b0;
        frame_err     = 1'b0;

        repeat (3) @(posedge clk_pcs);
        rst_n = 1'b1;

        @(negedge clk_pcs);
        payload_valid = 1'b1;
        payload_sof   = 1'b1;
        payload_eof   = 1'b0;
        payload_data  = pack8(8'h12, 8'h34, 8'h01, 8'h02,
                              8'h03, 8'h04, 8'h05, 8'h06);

        @(negedge clk_pcs);
        payload_sof  = 1'b0;
        payload_data = pack8(8'h07, 8'h08, 8'h10, 8'h20,
                             8'h30, 8'h40, 8'h50, 8'h60);

        @(negedge clk_pcs);
        payload_eof  = 1'b1;
        payload_data = pack8(8'h70, 8'h80, 8'h00, 8'h00,
                             8'h03, 8'hE8, 8'h42, 8'h00);

        @(posedge clk_pcs);
        #0.1;

        if (!field_valid) begin
            $error("field_valid did not assert on third payload word");
            $fatal;
        end

        if (field_err) begin
            $error("field_err asserted during nominal smoke frame");
            $fatal;
        end

        expect_equal16(msg_type,      16'h1234, "msg_type");
        expect_equal64(instrument_id, 64'h0102030405060708, "instrument_id");
        expect_equal64(price,         64'h1020304050607080, "price");
        expect_equal32(quantity,      32'h000003E8, "quantity");
        expect_equal8(side,           8'h42, "side");

        if (!alt_field_valid) begin
            $error("alt_field_valid did not assert on third payload word");
            $fatal;
        end

        if (alt_field_err) begin
            $error("alt_field_err asserted during alternate-offset smoke frame");
            $fatal;
        end

        expect_equal16(alt_msg_type,      16'h3401, "alt_msg_type");
        expect_equal64(alt_instrument_id, 64'h0203040506070810, "alt_instrument_id");
        expect_equal64(alt_price,         64'h2030405060708000, "alt_price");
        expect_equal32(alt_quantity,      32'h0003E842, "alt_quantity");
        expect_equal8(alt_side,           8'h00, "alt_side");

        @(negedge clk_pcs);
        payload_valid = 1'b0;
        payload_eof   = 1'b0;
        payload_data  = 64'h0;

        repeat (2) @(posedge clk_pcs);
        $finish;
    end
endmodule
