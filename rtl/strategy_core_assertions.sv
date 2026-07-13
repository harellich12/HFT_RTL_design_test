// Module     : strategy_core_assertions
// Description: Assertion bind checks for strategy_core decision determinism
// Latency    : N/A assertion bind
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
module strategy_core_assertions #(
    parameter int SYMBOL_TABLE_DEPTH = 1024,  // Legal range: power of 2; matches bound strategy_core table depth.
    parameter int SYMBOL_ID_WIDTH    = 10,    // Legal range: log2(SYMBOL_TABLE_DEPTH); matches bound index width.
    parameter int PRICE_WIDTH        = 64,    // Legal range: positive integer; matches bound price width.
    parameter int QTY_WIDTH          = 32     // Legal range: positive integer; matches bound quantity width.
) (
    input logic        clk_pcs,
    input logic        rst_n,

    input logic [SYMBOL_ID_WIDTH-1:0] symbol_idx,
    input logic [15:0]                msg_type,
    input logic [PRICE_WIDTH-1:0]     market_price,
    input logic [QTY_WIDTH-1:0]       market_quantity,
    input logic [7:0]                 market_side,
    input logic                       market_valid,
    input logic                       market_err,

    input logic [15:0]                strat_cfg_msg_type,
    input logic                       strat_cfg_msg_type_valid,
    input logic [SYMBOL_ID_WIDTH-1:0] strat_cfg_symbol_idx,
    input logic                       strat_cfg_entry_enable,
    input logic [1:0]                 strat_cfg_side_policy,
    input logic [QTY_WIDTH-1:0]       strat_cfg_qty,
    input logic                       strat_cfg_valid,
    input logic                       cfg_ready,

    input logic [SYMBOL_ID_WIDTH-1:0] order_symbol_idx,
    input logic [PRICE_WIDTH-1:0]     order_price,
    input logic [QTY_WIDTH-1:0]       order_quantity,
    input logic [7:0]                 order_side,
    input logic                       order_valid,
    input logic                       order_err,
    input logic                       order_suppress
);

    localparam logic [7:0] SIDE_BUY  = 8'h42;
    localparam logic [7:0] SIDE_SELL = 8'h53;

    logic                 enable_table [SYMBOL_TABLE_DEPTH];
    logic [1:0]           side_policy_table [SYMBOL_TABLE_DEPTH];
    logic [QTY_WIDTH-1:0] qty_table [SYMBOL_TABLE_DEPTH];
    logic [15:0]          msg_type_mirror_r;
    logic                 init_mirror_active_r;
    logic [SYMBOL_ID_WIDTH-1:0] init_mirror_idx_r;

    logic                 expected_enable;
    logic [1:0]           expected_policy;
    logic [QTY_WIDTH-1:0] expected_qty;
    logic                 expected_side_known;
    logic                 expected_needs_side;
    logic [7:0]           expected_side;
    logic                 expected_tradeable;

    // Mirror the bound module's config state and post-reset init sweep.
    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            msg_type_mirror_r    <= 16'h0;
            init_mirror_active_r <= 1'b1;
            init_mirror_idx_r    <= '0;
        end else begin
            if (init_mirror_active_r) begin
                enable_table[init_mirror_idx_r] <= 1'b0;
                init_mirror_idx_r <= init_mirror_idx_r + {{(SYMBOL_ID_WIDTH-1){1'b0}}, 1'b1};
                if (init_mirror_idx_r == {SYMBOL_ID_WIDTH{1'b1}}) begin
                    init_mirror_active_r <= 1'b0;
                end
            end else if (strat_cfg_valid) begin
                enable_table[strat_cfg_symbol_idx]      <= strat_cfg_entry_enable;
                side_policy_table[strat_cfg_symbol_idx] <= strat_cfg_side_policy;
                qty_table[strat_cfg_symbol_idx]         <= strat_cfg_qty;
            end

            if (strat_cfg_msg_type_valid) begin
                msg_type_mirror_r <= strat_cfg_msg_type;
            end
        end
    end

    always_comb begin
        expected_enable = enable_table[symbol_idx];
        expected_policy = side_policy_table[symbol_idx];
        expected_qty    = qty_table[symbol_idx];

        expected_side_known = (market_side == SIDE_BUY) || (market_side == SIDE_SELL);
        expected_needs_side = (expected_policy == 2'b00) || (expected_policy == 2'b01);

        expected_side = SIDE_BUY;
        unique case (expected_policy)
            2'b00: expected_side = market_side;
            2'b01: expected_side = (market_side == SIDE_BUY) ? SIDE_SELL : SIDE_BUY;
            2'b10: expected_side = SIDE_BUY;
            2'b11: expected_side = SIDE_SELL;
        endcase

        expected_tradeable = market_valid
                          && !market_err
                          && !init_mirror_active_r
                          && (msg_type == msg_type_mirror_r)
                          && expected_enable
                          && (!expected_needs_side || expected_side_known);
    end

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        cfg_ready == !init_mirror_active_r);

    // Every market_valid resolves to exactly one outcome one cycle later.
    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        market_valid |=> ($countones({order_valid, order_suppress, order_err}) == 1));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (!market_valid) |=> (!order_valid && !order_suppress && !order_err));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (market_valid && market_err) |=> order_err);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        expected_tradeable |=> order_valid);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (market_valid && !market_err && !expected_tradeable) |=> order_suppress);

    // Order intent fields must match the golden model on a valid decision.
    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        expected_tradeable |=> (order_symbol_idx == $past(symbol_idx)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        expected_tradeable |=> (order_price == $past(market_price)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        expected_tradeable |=> (order_quantity == $past(expected_qty)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        expected_tradeable |=> (order_side == $past(expected_side)));

endmodule

bind strategy_core strategy_core_assertions #(
    .SYMBOL_TABLE_DEPTH(SYMBOL_TABLE_DEPTH),
    .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH),
    .PRICE_WIDTH(PRICE_WIDTH),
    .QTY_WIDTH(QTY_WIDTH)
) u_strategy_core_assertions (
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
