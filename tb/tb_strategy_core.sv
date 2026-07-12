`timescale 1ns/1ps

// Smoke + reference-model testbench for strategy_core.
//
// Every driven market cycle is checked against the C++ golden model in
// verif/strategy_ref_model.cpp via DPI: directed cases first, then a
// deterministic pseudo-random stream (xorshift32, fixed seed) that mixes
// configured/unconfigured symbols, matching/mismatching msg_types, known and
// junk sides, and upstream errors, driven back-to-back with no idle gaps.
module tb_strategy_core;
    localparam int SYMBOL_TABLE_DEPTH = 1024;
    localparam int SYMBOL_ID_WIDTH    = 10;
    localparam int PRICE_WIDTH        = 64;
    localparam int QTY_WIDTH          = 32;

    import "DPI-C" function int strategy_ref_decide(
        input  int     market_valid,
        input  int     market_err,
        input  int     init_active,
        input  int     msg_type,
        input  int     cfg_msg_type,
        input  int     entry_enable,
        input  int     side_policy,
        input  longint entry_qty,
        input  int     market_side,
        output int     order_side,
        output longint order_qty
    );

    localparam int DECISION_IDLE     = 0;
    localparam int DECISION_VALID    = 1;
    localparam int DECISION_SUPPRESS = 2;
    localparam int DECISION_ERR      = 3;

    logic        clk_pcs;
    logic        rst_n;
    logic [SYMBOL_ID_WIDTH-1:0] symbol_idx;
    logic [15:0]                msg_type;
    logic [PRICE_WIDTH-1:0]     market_price;
    logic [QTY_WIDTH-1:0]       market_quantity;
    logic [7:0]                 market_side;
    logic                       market_valid;
    logic                       market_err;

    logic [15:0]                strat_cfg_msg_type;
    logic                       strat_cfg_msg_type_valid;
    logic [SYMBOL_ID_WIDTH-1:0] strat_cfg_symbol_idx;
    logic                       strat_cfg_entry_enable;
    logic [1:0]                 strat_cfg_side_policy;
    logic [QTY_WIDTH-1:0]       strat_cfg_qty;
    logic                       strat_cfg_valid;
    logic                       cfg_ready;

    logic [SYMBOL_ID_WIDTH-1:0] order_symbol_idx;
    logic [PRICE_WIDTH-1:0]     order_price;
    logic [QTY_WIDTH-1:0]       order_quantity;
    logic [7:0]                 order_side;
    logic                       order_valid;
    logic                       order_err;
    logic                       order_suppress;

    // Testbench mirror of the configuration it drives, used as model input.
    logic        tb_enable [SYMBOL_TABLE_DEPTH];
    logic [1:0]  tb_policy [SYMBOL_TABLE_DEPTH];
    logic [31:0] tb_qty    [SYMBOL_TABLE_DEPTH];
    logic [15:0] tb_cfg_msg_type;

    // Inputs of the cycle being checked (sampled at drive time).
    logic [SYMBOL_ID_WIDTH-1:0] chk_symbol;
    logic [15:0]                chk_msg_type;
    logic [PRICE_WIDTH-1:0]     chk_price;
    logic [7:0]                 chk_side;
    logic                       chk_valid;
    logic                       chk_err;
    logic                       chk_init;

    logic [31:0] rand_state;

    int unsigned checked_count;

    strategy_core #(
        .SYMBOL_TABLE_DEPTH(SYMBOL_TABLE_DEPTH),
        .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH),
        .PRICE_WIDTH(PRICE_WIDTH),
        .QTY_WIDTH(QTY_WIDTH)
    ) dut (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .symbol_idx(symbol_idx),
        .msg_type(msg_type),
        .market_price(market_price),
        .market_quantity(market_quantity),
        .market_side(market_side),
        .market_valid(market_valid),
        .market_err(market_err),
        .strat_cfg_msg_type(strat_cfg_msg_type),
        .strat_cfg_msg_type_valid(strat_cfg_msg_type_valid),
        .strat_cfg_symbol_idx(strat_cfg_symbol_idx),
        .strat_cfg_entry_enable(strat_cfg_entry_enable),
        .strat_cfg_side_policy(strat_cfg_side_policy),
        .strat_cfg_qty(strat_cfg_qty),
        .strat_cfg_valid(strat_cfg_valid),
        .cfg_ready(cfg_ready),
        .order_symbol_idx(order_symbol_idx),
        .order_price(order_price),
        .order_quantity(order_quantity),
        .order_side(order_side),
        .order_valid(order_valid),
        .order_err(order_err),
        .order_suppress(order_suppress)
    );

    function automatic logic [31:0] xorshift32 (
        input logic [31:0] state_in
    );
        logic [31:0] s;
        begin
            s = state_in;
            s = s ^ (s << 13);
            s = s ^ (s >> 17);
            s = s ^ (s << 5);
            xorshift32 = s;
        end
    endfunction

    task automatic drive_market (
        input logic [SYMBOL_ID_WIDTH-1:0] t_symbol,
        input logic [15:0]                t_msg_type,
        input logic [PRICE_WIDTH-1:0]     t_price,
        input logic [7:0]                 t_side,
        input logic                       t_valid,
        input logic                       t_err
    );
        @(negedge clk_pcs);
        symbol_idx      = t_symbol;
        msg_type        = t_msg_type;
        market_price    = t_price;
        market_quantity = 32'hDEAD_BEEF;  // market qty must never reach the order
        market_side     = t_side;
        market_valid    = t_valid;
        market_err      = t_err;

        chk_symbol   = t_symbol;
        chk_msg_type = t_msg_type;
        chk_price    = t_price;
        chk_side     = t_side;
        chk_valid    = t_valid;
        chk_err      = t_err;
        chk_init     = (cfg_ready !== 1'b1);
    endtask

    task automatic check_against_model (
        input string name
    );
        int     exp_decision;
        int     exp_side;
        longint exp_qty;

        @(posedge clk_pcs);
        #0.1;

        exp_decision = strategy_ref_decide(
            chk_valid ? 1 : 0,
            chk_err ? 1 : 0,
            chk_init ? 1 : 0,
            {16'h0, chk_msg_type},
            {16'h0, tb_cfg_msg_type},
            tb_enable[chk_symbol] ? 1 : 0,
            {30'h0, tb_policy[chk_symbol]},
            {32'h0, tb_qty[chk_symbol]},
            {24'h0, chk_side},
            exp_side,
            exp_qty);

        checked_count++;

        case (exp_decision)
            DECISION_IDLE: begin
                if (order_valid || order_suppress || order_err) begin
                    $error("%s: model=idle but DUT pulsed v=%0b s=%0b e=%0b",
                           name, order_valid, order_suppress, order_err);
                    $fatal;
                end
            end
            DECISION_VALID: begin
                if (!order_valid || order_suppress || order_err) begin
                    $error("%s: model=valid but DUT v=%0b s=%0b e=%0b",
                           name, order_valid, order_suppress, order_err);
                    $fatal;
                end
                if ((order_symbol_idx !== chk_symbol)
                 || (order_price !== chk_price)
                 || (order_quantity !== exp_qty[31:0])
                 || (order_side !== exp_side[7:0])) begin
                    $error("%s: field mismatch sym=%0h/%0h price=%0h/%0h qty=%0h/%0h side=%0h/%0h",
                           name,
                           order_symbol_idx, chk_symbol,
                           order_price, chk_price,
                           order_quantity, exp_qty[31:0],
                           order_side, exp_side[7:0]);
                    $fatal;
                end
            end
            DECISION_SUPPRESS: begin
                if (order_valid || !order_suppress || order_err) begin
                    $error("%s: model=suppress but DUT v=%0b s=%0b e=%0b",
                           name, order_valid, order_suppress, order_err);
                    $fatal;
                end
            end
            DECISION_ERR: begin
                if (order_valid || order_suppress || !order_err) begin
                    $error("%s: model=err but DUT v=%0b s=%0b e=%0b",
                           name, order_valid, order_suppress, order_err);
                    $fatal;
                end
            end
            default: begin
                $error("%s: model returned unknown decision %0d", name, exp_decision);
                $fatal;
            end
        endcase
    endtask

    task automatic load_entry (
        input logic [SYMBOL_ID_WIDTH-1:0] t_symbol,
        input logic                       t_enable,
        input logic [1:0]                 t_policy,
        input logic [31:0]                t_qty
    );
        @(negedge clk_pcs);
        strat_cfg_symbol_idx   = t_symbol;
        strat_cfg_entry_enable = t_enable;
        strat_cfg_side_policy  = t_policy;
        strat_cfg_qty          = t_qty;
        strat_cfg_valid        = 1'b1;
        tb_enable[t_symbol] = t_enable;
        tb_policy[t_symbol] = t_policy;
        tb_qty[t_symbol]    = t_qty;
        @(negedge clk_pcs);
        strat_cfg_valid = 1'b0;
    endtask

    always #3.2 clk_pcs = ~clk_pcs;

    initial begin
        logic [SYMBOL_ID_WIDTH-1:0] rand_symbol;
        logic [15:0]                rand_msg;
        logic [7:0]                 rand_side;
        logic                       rand_err;

        $dumpfile("tb/strategy_core_smoke.vcd");
        $dumpvars(0, tb_strategy_core);

        clk_pcs         = 1'b0;
        rst_n           = 1'b0;
        symbol_idx      = '0;
        msg_type        = 16'h0;
        market_price    = '0;
        market_quantity = '0;
        market_side     = 8'h0;
        market_valid    = 1'b0;
        market_err      = 1'b0;
        strat_cfg_msg_type       = 16'h0;
        strat_cfg_msg_type_valid = 1'b0;
        strat_cfg_symbol_idx     = '0;
        strat_cfg_entry_enable   = 1'b0;
        strat_cfg_side_policy    = 2'b00;
        strat_cfg_qty            = 32'h0;
        strat_cfg_valid          = 1'b0;
        rand_state    = 32'hC0FFEE01;
        checked_count = 0;

        for (int i = 0; i < SYMBOL_TABLE_DEPTH; i++) begin
            tb_enable[i] = 1'b0;
            tb_policy[i] = 2'b00;
            tb_qty[i]    = 32'h0;
        end
        tb_cfg_msg_type = 16'h0;

        repeat (3) @(posedge clk_pcs);
        rst_n = 1'b1;

        // Lookup during the init sweep must suppress deterministically.
        drive_market(10'h042, 16'h0000, 64'd10, 8'h42, 1'b1, 1'b0);
        check_against_model("init sweep suppress");
        drive_market('0, 16'h0, '0, 8'h0, 1'b0, 1'b0);
        check_against_model("init sweep idle");

        wait (cfg_ready === 1'b1);

        // Tradeable msg_type register load.
        @(negedge clk_pcs);
        strat_cfg_msg_type       = 16'h1234;
        strat_cfg_msg_type_valid = 1'b1;
        tb_cfg_msg_type          = 16'h1234;
        @(negedge clk_pcs);
        strat_cfg_msg_type_valid = 1'b0;

        // One symbol per side policy, plus one explicitly disabled entry.
        load_entry(10'h011, 1'b1, 2'b00, 32'd11);  // same-side
        load_entry(10'h022, 1'b1, 2'b01, 32'd22);  // opposite
        load_entry(10'h033, 1'b1, 2'b10, 32'd33);  // fixed buy
        load_entry(10'h044, 1'b1, 2'b11, 32'd44);  // fixed sell
        load_entry(10'h055, 1'b0, 2'b00, 32'd55);  // disabled

        // Directed decisions, one per policy and one per suppress/err cause.
        drive_market(10'h011, 16'h1234, 64'd100, 8'h42, 1'b1, 1'b0);
        check_against_model("same-side buy");
        drive_market(10'h022, 16'h1234, 64'd101, 8'h42, 1'b1, 1'b0);
        check_against_model("opposite of buy");
        drive_market(10'h022, 16'h1234, 64'd102, 8'h53, 1'b1, 1'b0);
        check_against_model("opposite of sell");
        drive_market(10'h033, 16'h1234, 64'd103, 8'hA5, 1'b1, 1'b0);
        check_against_model("fixed buy ignores junk side");
        drive_market(10'h044, 16'h1234, 64'd104, 8'h42, 1'b1, 1'b0);
        check_against_model("fixed sell");
        drive_market(10'h011, 16'h1234, 64'd105, 8'hA5, 1'b1, 1'b0);
        check_against_model("junk side with same policy suppresses");
        drive_market(10'h022, 16'h1234, 64'd106, 8'h00, 1'b1, 1'b0);
        check_against_model("junk side with opposite policy suppresses");
        drive_market(10'h011, 16'h4321, 64'd107, 8'h42, 1'b1, 1'b0);
        check_against_model("msg_type mismatch suppresses");
        drive_market(10'h055, 16'h1234, 64'd108, 8'h42, 1'b1, 1'b0);
        check_against_model("disabled entry suppresses");
        drive_market(10'h066, 16'h1234, 64'd109, 8'h42, 1'b1, 1'b0);
        check_against_model("unconfigured entry suppresses");
        drive_market(10'h011, 16'h1234, 64'd110, 8'h42, 1'b1, 1'b1);
        check_against_model("upstream error");
        drive_market('0, 16'h0, '0, 8'h0, 1'b0, 1'b0);
        check_against_model("idle");

        // Deterministic pseudo-random stream, back-to-back with no gaps.
        for (int i = 0; i < 300; i++) begin
            rand_state = xorshift32(rand_state);
            case (rand_state[2:0])
                3'd0: rand_symbol = 10'h011;
                3'd1: rand_symbol = 10'h022;
                3'd2: rand_symbol = 10'h033;
                3'd3: rand_symbol = 10'h044;
                3'd4: rand_symbol = 10'h055;
                3'd5: rand_symbol = 10'h066;
                3'd6: rand_symbol = {2'h0, rand_state[10:3]};
                3'd7: rand_symbol = 10'h011;
            endcase
            rand_msg  = rand_state[3] ? 16'h1234 : {8'h43, rand_state[11:4]};
            rand_side = rand_state[4] ? (rand_state[5] ? 8'h42 : 8'h53)
                                      : rand_state[12:5];
            rand_err  = (rand_state[31:29] == 3'b111);

            drive_market(rand_symbol, rand_msg,
                         {32'h0, rand_state}, rand_side, 1'b1, rand_err);
            check_against_model($sformatf("random iter %0d", i));
        end

        drive_market('0, 16'h0, '0, 8'h0, 1'b0, 1'b0);
        check_against_model("final idle");

        $display("strategy_core reference-model comparison: %0d cycles checked", checked_count);

        repeat (2) @(posedge clk_pcs);
        $finish;
    end
endmodule
