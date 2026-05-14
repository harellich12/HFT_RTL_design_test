`timescale 1ns/1ps

module tb_sym_id_mapper;
    localparam int SYMBOL_TABLE_DEPTH = 1024;
    localparam int SYMBOL_ID_WIDTH    = 10;

    logic        clk_pcs;
    logic        rst_n;
    logic [63:0] instrument_id;
    logic        field_valid;
    logic        field_err;

    logic [SYMBOL_ID_WIDTH-1:0] symbol_idx;
    logic        sym_valid;
    logic        sym_miss;
    logic        sym_err;

    sym_id_mapper #(
        .SYMBOL_TABLE_DEPTH(SYMBOL_TABLE_DEPTH),
        .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH)
    ) dut (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .instrument_id(instrument_id),
        .field_valid(field_valid),
        .field_err(field_err),
        .symbol_idx(symbol_idx),
        .sym_valid(sym_valid),
        .sym_miss(sym_miss),
        .sym_err(sym_err)
    );

    task automatic expect_symbol (
        input logic [SYMBOL_ID_WIDTH-1:0] expected_idx,
        input logic                       expected_valid,
        input logic                       expected_miss,
        input logic                       expected_err,
        input string                      name
    );
        if (symbol_idx !== expected_idx) begin
            $error("%s symbol_idx mismatch: actual=0x%0h expected=0x%0h",
                   name, symbol_idx, expected_idx);
            $fatal;
        end

        if ((sym_valid !== expected_valid)
         || (sym_miss  !== expected_miss)
         || (sym_err   !== expected_err)) begin
            $error("%s flags mismatch: valid=%0b/%0b miss=%0b/%0b err=%0b/%0b",
                   name, sym_valid, expected_valid,
                   sym_miss, expected_miss,
                   sym_err, expected_err);
            $fatal;
        end
    endtask

    always #3.2 clk_pcs = ~clk_pcs;

    initial begin
        $dumpfile("tb/sym_id_mapper_smoke.vcd");
        $dumpvars(0, tb_sym_id_mapper);

        clk_pcs       = 1'b0;
        rst_n         = 1'b0;
        instrument_id = 64'h0;
        field_valid   = 1'b0;
        field_err     = 1'b0;

        repeat (3) @(posedge clk_pcs);
        rst_n = 1'b1;

        @(negedge clk_pcs);
        instrument_id = 64'h0000_0000_0000_0155;
        field_valid   = 1'b1;
        field_err     = 1'b0;

        @(posedge clk_pcs);
        #0.1;
        expect_symbol(10'h155, 1'b1, 1'b0, 1'b0, "identity hit");

        @(negedge clk_pcs);
        instrument_id = 64'h0000_0000_0004_0155;
        field_valid   = 1'b1;
        field_err     = 1'b0;

        @(posedge clk_pcs);
        #0.1;
        expect_symbol(10'h155, 1'b1, 1'b1, 1'b0, "tag miss");

        @(negedge clk_pcs);
        instrument_id = 64'h0000_0000_0000_002a;
        field_valid   = 1'b1;
        field_err     = 1'b1;

        @(posedge clk_pcs);
        #0.1;
        expect_symbol(10'h02a, 1'b1, 1'b0, 1'b1, "field error");

        @(negedge clk_pcs);
        field_valid = 1'b0;
        field_err   = 1'b0;

        @(posedge clk_pcs);
        #0.1;
        expect_symbol(10'h02a, 1'b0, 1'b0, 1'b0, "idle");

        repeat (2) @(posedge clk_pcs);
        $finish;
    end
endmodule
