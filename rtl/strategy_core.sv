// Module     : strategy_core
// Description: Stage-1 deterministic trading decision between mapper and risk
// Latency    : 1 cycle from market_valid to order_valid/order_suppress/order_err
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
//
// Pipeline role:
// - Converts normalized market data into order intent so risk_gate validates
//   what would actually trade, not raw parsed market fields.
// - Stage-1 policy (integration proof, per recorded architecture decisions):
//   take liquidity only, one configured tradeable msg_type, per-symbol
//   enable/side-policy/quantity from an off-path loaded parameter table.
// - Every market_valid resolves to exactly one of order_valid,
//   order_suppress, or order_err on the next cycle.
module strategy_core #(
    parameter int SYMBOL_TABLE_DEPTH = 1024,  // Legal range: power of 2; changes parameter table depth.
    parameter int SYMBOL_ID_WIDTH    = 10,    // Legal range: log2(SYMBOL_TABLE_DEPTH); changes symbol index width.
    parameter int PRICE_WIDTH        = 64,    // Legal range: positive integer; changes price datapath width.
    parameter int QTY_WIDTH          = 32     // Legal range: positive integer; changes quantity datapath width.
) (
    input  logic        clk_pcs,
    input  logic        rst_n,

    // Normalized market data, aligned with the sym_id_mapper output cycle.
    input  logic [SYMBOL_ID_WIDTH-1:0] symbol_idx,
    input  logic [15:0]                msg_type,
    input  logic [PRICE_WIDTH-1:0]     market_price,
    input  logic [QTY_WIDTH-1:0]       market_quantity,
    input  logic [7:0]                 market_side,
    input  logic                       market_valid,
    input  logic                       market_err,

    // Off-path configuration. Load entries after cfg_ready while the datapath
    // is quiescent; table loads issued during the init sweep are ignored.
    input  logic [15:0]                strat_cfg_msg_type,
    input  logic                       strat_cfg_msg_type_valid,
    input  logic [SYMBOL_ID_WIDTH-1:0] strat_cfg_symbol_idx,
    input  logic                       strat_cfg_entry_enable,
    input  logic [1:0]                 strat_cfg_side_policy,
    input  logic [QTY_WIDTH-1:0]       strat_cfg_qty,
    input  logic                       strat_cfg_valid,
    output logic                       cfg_ready,

    // Order intent to risk_gate.
    output logic [SYMBOL_ID_WIDTH-1:0] order_symbol_idx,
    output logic [PRICE_WIDTH-1:0]     order_price,
    output logic [QTY_WIDTH-1:0]       order_quantity,
    output logic [7:0]                 order_side,
    output logic                       order_valid,
    output logic                       order_err,
    output logic                       order_suppress
);

    localparam logic [7:0] SIDE_BUY  = 8'h42;
    localparam logic [7:0] SIDE_SELL = 8'h53;

    // Side policy encoding for the per-symbol parameter table.
    localparam logic [1:0] POLICY_SAME       = 2'b00;
    localparam logic [1:0] POLICY_OPPOSITE   = 2'b01;
    localparam logic [1:0] POLICY_FIXED_BUY  = 2'b10;
    localparam logic [1:0] POLICY_FIXED_SELL = 2'b11;

    logic                 enable_table [SYMBOL_TABLE_DEPTH];
    logic [1:0]           side_policy_table [SYMBOL_TABLE_DEPTH];
    logic [QTY_WIDTH-1:0] qty_table [SYMBOL_TABLE_DEPTH];

    logic [15:0]                tradeable_msg_type_r;
    logic                       init_active_r;
    logic [SYMBOL_ID_WIDTH-1:0] init_idx_r;

    logic                 entry_enable;
    logic [1:0]           entry_policy;
    logic [QTY_WIDTH-1:0] entry_qty;
    logic                 side_known;
    logic                 policy_needs_side;
    logic [7:0]           decided_side;
    logic                 tradeable;
    logic                 suppress_now;
    logic                 err_now;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            tradeable_msg_type_r <= 16'h0;
            init_active_r        <= 1'b1;
            init_idx_r           <= '0;
            order_symbol_idx     <= '0;
            order_price          <= '0;
            order_quantity       <= '0;
            order_side           <= 8'h0;
            order_valid          <= 1'b0;
            order_err            <= 1'b0;
            order_suppress       <= 1'b0;
        end else begin
            // Post-reset init sweep: disable one entry per cycle so no table
            // cell is ever read undefined, without a synthesizable loop.
            if (init_active_r) begin
                enable_table[init_idx_r] <= 1'b0;
                init_idx_r               <= init_idx_r + {{(SYMBOL_ID_WIDTH-1){1'b0}}, 1'b1};
                if (init_idx_r == {SYMBOL_ID_WIDTH{1'b1}}) begin
                    init_active_r <= 1'b0;
                end
            end else if (strat_cfg_valid) begin
                enable_table[strat_cfg_symbol_idx]      <= strat_cfg_entry_enable;
                side_policy_table[strat_cfg_symbol_idx] <= strat_cfg_side_policy;
                qty_table[strat_cfg_symbol_idx]         <= strat_cfg_qty;
            end

            // The tradeable msg_type is a plain register with a reset value,
            // so it may load at any time, including during the sweep.
            if (strat_cfg_msg_type_valid) begin
                tradeable_msg_type_r <= strat_cfg_msg_type;
            end

            order_valid    <= tradeable;
            order_suppress <= suppress_now;
            order_err      <= err_now;

            if (tradeable) begin
                order_symbol_idx <= symbol_idx;
                order_price      <= market_price;
                order_quantity   <= entry_qty;
                order_side       <= decided_side;
            end
        end
    end

    always_comb begin
        cfg_ready = !init_active_r;

        entry_enable = enable_table[symbol_idx];
        entry_policy = side_policy_table[symbol_idx];
        entry_qty    = qty_table[symbol_idx];

        side_known        = (market_side == SIDE_BUY) || (market_side == SIDE_SELL);
        policy_needs_side = (entry_policy == POLICY_SAME)
                         || (entry_policy == POLICY_OPPOSITE);

        decided_side = SIDE_BUY;
        unique case (entry_policy)
            POLICY_SAME:       decided_side = market_side;
            POLICY_OPPOSITE:   decided_side = (market_side == SIDE_BUY) ? SIDE_SELL
                                                                        : SIDE_BUY;
            POLICY_FIXED_BUY:  decided_side = SIDE_BUY;
            POLICY_FIXED_SELL: decided_side = SIDE_SELL;
        endcase

        // Trade only on the configured msg_type for an enabled symbol whose
        // side policy can form a definite side. Lookups during the init sweep
        // suppress deterministically. An unknown market side under a
        // side-dependent policy suppresses rather than guessing.
        tradeable = market_valid
                 && !market_err
                 && !init_active_r
                 && (msg_type == tradeable_msg_type_r)
                 && entry_enable
                 && (!policy_needs_side || side_known);

        suppress_now = market_valid && !market_err && !tradeable;
        err_now      = market_valid && market_err;
    end

endmodule
