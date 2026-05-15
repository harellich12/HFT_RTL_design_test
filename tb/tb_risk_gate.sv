`timescale 1ns/1ps

module tb_risk_gate;
    localparam int SYMBOL_TABLE_DEPTH = 1024;
    localparam int SYMBOL_ID_WIDTH    = 10;
    localparam int PRICE_WIDTH        = 64;
    localparam int QTY_WIDTH          = 32;

    logic        clk_pcs;
    logic        rst_n;
    logic [SYMBOL_ID_WIDTH-1:0] symbol_idx;
    logic [PRICE_WIDTH-1:0]     price;
    logic [QTY_WIDTH-1:0]       quantity;
    logic [7:0]                 side;
    logic                       sym_valid;
    logic                       sym_miss;
    logic                       sym_err;
    logic [SYMBOL_ID_WIDTH-1:0] risk_cfg_symbol_idx;
    logic [PRICE_WIDTH-1:0]     risk_cfg_price_floor;
    logic [PRICE_WIDTH-1:0]     risk_cfg_price_ceil;
    logic [QTY_WIDTH-1:0]       risk_cfg_qty_max;
    logic                       risk_cfg_valid;
    logic                       risk_global_kill;

    logic        risk_pass;
    logic        risk_kill;
    logic [3:0]  kill_reason;
    logic        risk_err;

    risk_gate #(
        .SYMBOL_TABLE_DEPTH(SYMBOL_TABLE_DEPTH),
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
        .sym_valid(sym_valid),
        .sym_miss(sym_miss),
        .sym_err(sym_err),
        .risk_cfg_symbol_idx(risk_cfg_symbol_idx),
        .risk_cfg_price_floor(risk_cfg_price_floor),
        .risk_cfg_price_ceil(risk_cfg_price_ceil),
        .risk_cfg_qty_max(risk_cfg_qty_max),
        .risk_cfg_valid(risk_cfg_valid),
        .risk_global_kill(risk_global_kill),
        .risk_pass(risk_pass),
        .risk_kill(risk_kill),
        .kill_reason(kill_reason),
        .risk_err(risk_err)
    );

    task automatic drive_case (
        input logic [PRICE_WIDTH-1:0] test_price,
        input logic [QTY_WIDTH-1:0]   test_quantity,
        input logic                   test_sym_miss,
        input logic                   test_sym_err
    );
        @(negedge clk_pcs);
        symbol_idx = 10'h155;
        price      = test_price;
        quantity   = test_quantity;
        side       = 8'h42;
        sym_valid  = 1'b1;
        sym_miss   = test_sym_miss;
        sym_err    = test_sym_err;
    endtask

    task automatic expect_risk (
        input logic       expected_pass,
        input logic       expected_kill,
        input logic [3:0] expected_reason,
        input logic       expected_err,
        input string      name
    );
        @(posedge clk_pcs);
        #0.1;
        if ((risk_pass !== expected_pass)
         || (risk_kill !== expected_kill)
         || (kill_reason !== expected_reason)
         || (risk_err !== expected_err)) begin
            $error("%s mismatch: pass=%0b/%0b kill=%0b/%0b reason=0x%0h/0x%0h err=%0b/%0b",
                   name,
                   risk_pass, expected_pass,
                   risk_kill, expected_kill,
                   kill_reason, expected_reason,
                   risk_err, expected_err);
            $fatal;
        end
    endtask

    always #3.2 clk_pcs = ~clk_pcs;

    initial begin
        $dumpfile("tb/risk_gate_smoke.vcd");
        $dumpvars(0, tb_risk_gate);

        clk_pcs    = 1'b0;
        rst_n      = 1'b0;
        symbol_idx = '0;
        price      = '0;
        quantity   = '0;
        side       = 8'h0;
        sym_valid  = 1'b0;
        sym_miss   = 1'b0;
        sym_err    = 1'b0;
        risk_cfg_symbol_idx = '0;
        risk_cfg_price_floor = '0;
        risk_cfg_price_ceil = '0;
        risk_cfg_qty_max = '0;
        risk_cfg_valid = 1'b0;
        risk_global_kill = 1'b0;

        repeat (3) @(posedge clk_pcs);
        rst_n = 1'b1;

        @(negedge clk_pcs);
        risk_cfg_symbol_idx  = 10'h155;
        risk_cfg_price_floor = 64'd10;
        risk_cfg_price_ceil  = 64'd1_000_000;
        risk_cfg_qty_max     = 32'd1_000;
        risk_cfg_valid       = 1'b1;

        @(posedge clk_pcs);
        #0.1;
        @(negedge clk_pcs);
        risk_cfg_valid = 1'b0;

        drive_case(64'd100, 32'd100, 1'b0, 1'b0);
        expect_risk(1'b1, 1'b0, 4'h0, 1'b0, "pass");

        drive_case(64'd5, 32'd100, 1'b0, 1'b0);
        expect_risk(1'b0, 1'b1, 4'h1, 1'b0, "price floor");

        drive_case(64'd1_000_001, 32'd100, 1'b0, 1'b0);
        expect_risk(1'b0, 1'b1, 4'h2, 1'b0, "price ceiling");

        drive_case(64'd100, 32'd1_001, 1'b0, 1'b0);
        expect_risk(1'b0, 1'b1, 4'h3, 1'b0, "quantity");

        drive_case(64'd100, 32'd100, 1'b1, 1'b0);
        expect_risk(1'b0, 1'b1, 4'h5, 1'b0, "symbol miss");

        drive_case(64'd100, 32'd100, 1'b0, 1'b1);
        expect_risk(1'b0, 1'b1, 4'hF, 1'b1, "upstream error");

        @(negedge clk_pcs);
        risk_global_kill = 1'b1;
        sym_valid = 1'b0;

        @(posedge clk_pcs);
        #0.1;
        drive_case(64'd100, 32'd100, 1'b0, 1'b0);
        expect_risk(1'b0, 1'b1, 4'h4, 1'b0, "global kill");

        @(negedge clk_pcs);
        risk_global_kill = 1'b0;
        sym_valid = 1'b0;

        @(posedge clk_pcs);
        #0.1;

        drive_case(64'd1_000_001, 32'd1_001, 1'b0, 1'b0);
        expect_risk(1'b0, 1'b1, 4'hE, 1'b0, "multi ceiling quantity");

        drive_case(64'd100, 32'd1_001, 1'b1, 1'b0);
        expect_risk(1'b0, 1'b1, 4'hE, 1'b0, "multi quantity miss");

        drive_case(64'd100, 32'd1_001, 1'b0, 1'b1);
        expect_risk(1'b0, 1'b1, 4'hE, 1'b1, "multi quantity upstream error");

        @(negedge clk_pcs);
        sym_valid = 1'b0;
        sym_miss  = 1'b0;
        sym_err   = 1'b0;

        expect_risk(1'b0, 1'b0, 4'h0, 1'b0, "idle");

        repeat (2) @(posedge clk_pcs);
        $finish;
    end
endmodule
