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

    input logic [PRICE_WIDTH-1:0]       price,
    input logic [QTY_WIDTH-1:0]         quantity,
    input logic                         sym_valid,
    input logic                         sym_miss,
    input logic                         sym_err,

    input logic                         risk_pass,
    input logic                         risk_kill,
    input logic [3:0]                   kill_reason,
    input logic                         risk_err
);

    localparam logic [PRICE_WIDTH-1:0] ASSERT_PRICE_FLOOR = PRICE_WIDTH'(10);
    localparam logic [PRICE_WIDTH-1:0] ASSERT_PRICE_CEIL  = PRICE_WIDTH'(1_000_000);
    localparam logic [QTY_WIDTH-1:0]   ASSERT_QTY_MAX     = QTY_WIDTH'(1_000);

    logic price_floor_violation;
    logic price_ceil_violation;
    logic quantity_violation;
    logic multi_violation;
    logic in_range_condition;
    logic clean_pass_condition;

    always_comb begin
        price_floor_violation = price < ASSERT_PRICE_FLOOR;
        price_ceil_violation  = price > ASSERT_PRICE_CEIL;
        quantity_violation    = quantity > ASSERT_QTY_MAX;
        multi_violation       = (price_floor_violation && (price_ceil_violation
                                                        || quantity_violation
                                                        || sym_miss
                                                        || sym_err))
                             || (price_ceil_violation  && (quantity_violation
                                                        || sym_miss
                                                        || sym_err))
                             || (quantity_violation    && (sym_miss || sym_err))
                             || (sym_miss              && sym_err);
        in_range_condition    = !price_floor_violation
                              && !price_ceil_violation
                              && !quantity_violation;
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
        (sym_valid && price_floor_violation && !price_ceil_violation && !quantity_violation && !sym_miss && !sym_err)
        |=> (!risk_pass && risk_kill && !risk_err && (kill_reason == 4'h1)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (sym_valid && price_ceil_violation && !price_floor_violation && !quantity_violation && !sym_miss && !sym_err)
        |=> (!risk_pass && risk_kill && !risk_err && (kill_reason == 4'h2)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (sym_valid && quantity_violation && !price_floor_violation && !price_ceil_violation && !sym_miss && !sym_err)
        |=> (!risk_pass && risk_kill && !risk_err && (kill_reason == 4'h3)));

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
    .price(price),
    .quantity(quantity),
    .sym_valid(sym_valid),
    .sym_miss(sym_miss),
    .sym_err(sym_err),
    .risk_pass(risk_pass),
    .risk_kill(risk_kill),
    .kill_reason(kill_reason),
    .risk_err(risk_err)
);
