// Module     : risk_gate_assertions
// Description: Assertion bind checks for risk_gate pass/kill timing and reasons
// Latency    : N/A assertion bind
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
module risk_gate_assertions #(
    parameter int SYMBOL_TABLE_DEPTH = 1024,  // Legal range: power of 2; matches bound risk_gate table depth.
    parameter int SYMBOL_ID_WIDTH    = 10,    // Legal range: log2(SYMBOL_TABLE_DEPTH); matches bound risk_gate index width.
    parameter int PRICE_WIDTH        = 64,    // Legal range: positive integer; matches bound risk_gate price width.
    parameter int QTY_WIDTH          = 32     // Legal range: positive integer; matches bound risk_gate quantity width.
) (
    input logic                         clk_pcs,
    input logic                         rst_n,

    input logic [SYMBOL_ID_WIDTH-1:0]   symbol_idx,
    input logic [PRICE_WIDTH-1:0]       price,
    input logic [QTY_WIDTH-1:0]         quantity,
    input logic                         sym_valid,
    input logic                         sym_miss,
    input logic                         sym_err,

    input logic [SYMBOL_ID_WIDTH-1:0]   risk_cfg_symbol_idx,
    input logic [PRICE_WIDTH-1:0]       risk_cfg_price_floor,
    input logic [PRICE_WIDTH-1:0]       risk_cfg_price_ceil,
    input logic [QTY_WIDTH-1:0]         risk_cfg_qty_max,
    input logic                         risk_cfg_valid,
    input logic                         risk_global_kill,

    input logic                         risk_pass,
    input logic                         risk_kill,
    input logic [3:0]                   kill_reason,
    input logic                         risk_err
);

    logic [PRICE_WIDTH-1:0] price_floor_table [SYMBOL_TABLE_DEPTH];
    logic [PRICE_WIDTH-1:0] price_ceil_table [SYMBOL_TABLE_DEPTH];
    logic [QTY_WIDTH-1:0]   qty_max_table [SYMBOL_TABLE_DEPTH];
    logic                   global_kill_r;
    logic [PRICE_WIDTH-1:0] price_floor_limit;
    logic [PRICE_WIDTH-1:0] price_ceil_limit;
    logic [QTY_WIDTH-1:0]   qty_max_limit;
    logic price_floor_violation;
    logic price_ceil_violation;
    logic quantity_violation;
    logic global_kill_violation;
    logic multi_violation;
    logic in_range_condition;
    logic clean_pass_condition;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            global_kill_r <= 1'b0;
        end else begin
            global_kill_r <= risk_global_kill;

            if (risk_cfg_valid) begin
                price_floor_table[risk_cfg_symbol_idx] <= risk_cfg_price_floor;
                price_ceil_table[risk_cfg_symbol_idx]  <= risk_cfg_price_ceil;
                qty_max_table[risk_cfg_symbol_idx]     <= risk_cfg_qty_max;
            end
        end
    end

    always_comb begin
        price_floor_limit = price_floor_table[symbol_idx];
        price_ceil_limit  = price_ceil_table[symbol_idx];
        qty_max_limit     = qty_max_table[symbol_idx];

        price_floor_violation = price < price_floor_limit;
        price_ceil_violation  = price > price_ceil_limit;
        quantity_violation    = quantity > qty_max_limit;
        global_kill_violation = global_kill_r;
        multi_violation       = (price_floor_violation && (price_ceil_violation
                                                        || quantity_violation
                                                        || global_kill_violation
                                                        || sym_miss
                                                        || sym_err))
                             || (price_ceil_violation  && (quantity_violation
                                                        || global_kill_violation
                                                        || sym_miss
                                                        || sym_err))
                             || (quantity_violation    && (global_kill_violation
                                                        || sym_miss
                                                        || sym_err))
                             || (global_kill_violation && (sym_miss || sym_err))
                             || (sym_miss              && sym_err);
        in_range_condition    = !price_floor_violation
                              && !price_ceil_violation
                              && !quantity_violation
                              && !global_kill_violation;
        clean_pass_condition  = in_range_condition
                              && !sym_miss
                              && !sym_err;
    end

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        risk_pass |-> !risk_kill);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        risk_kill |-> !risk_pass);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        risk_kill |-> (kill_reason != 4'h0));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        !risk_kill |-> (kill_reason == 4'h0));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (!sym_valid) |=> (!risk_pass && !risk_kill && !risk_err && (kill_reason == 4'h0)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (sym_valid && clean_pass_condition) |=> (risk_pass && !risk_kill && !risk_err && (kill_reason == 4'h0)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (sym_valid && price_floor_violation && !price_ceil_violation && !quantity_violation && !global_kill_violation && !sym_miss && !sym_err)
        |=> (!risk_pass && risk_kill && !risk_err && (kill_reason == 4'h1)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (sym_valid && price_ceil_violation && !price_floor_violation && !quantity_violation && !global_kill_violation && !sym_miss && !sym_err)
        |=> (!risk_pass && risk_kill && !risk_err && (kill_reason == 4'h2)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (sym_valid && quantity_violation && !price_floor_violation && !price_ceil_violation && !global_kill_violation && !sym_miss && !sym_err)
        |=> (!risk_pass && risk_kill && !risk_err && (kill_reason == 4'h3)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (sym_valid && global_kill_violation && !price_floor_violation && !price_ceil_violation && !quantity_violation && !sym_miss && !sym_err)
        |=> (!risk_pass && risk_kill && !risk_err && (kill_reason == 4'h4)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (sym_valid && sym_miss && in_range_condition && !sym_err)
        |=> (!risk_pass && risk_kill && !risk_err && (kill_reason == 4'h5)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (sym_valid && sym_err && in_range_condition && !sym_miss)
        |=> (!risk_pass && risk_kill && risk_err && (kill_reason == 4'hF)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (sym_valid && multi_violation)
        |=> (!risk_pass && risk_kill && (risk_err == $past(sym_err)) && (kill_reason == 4'hE)));

endmodule

bind risk_gate risk_gate_assertions #(
    .SYMBOL_TABLE_DEPTH(SYMBOL_TABLE_DEPTH),
    .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH),
    .PRICE_WIDTH(PRICE_WIDTH),
    .QTY_WIDTH(QTY_WIDTH)
) u_risk_gate_assertions (
    .clk_pcs(clk_pcs),
    .rst_n(rst_n),
    .symbol_idx(symbol_idx),
    .price(price),
    .quantity(quantity),
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
