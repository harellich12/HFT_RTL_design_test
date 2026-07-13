// Module     : risk_gate
// Description: Evaluate symbol, price, quantity, and kill-switch risk checks
// Latency    : 1 cycle
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
//
// Pipeline role:
// - Performs the hard stop/pass decision for a decoded symbol update/order.
// - Evaluates all configured risk limits in parallel for deterministic latency.
// - Drives the kill path that prevents pkt_formatter from emitting bad orders.
module risk_gate #(
    parameter int SYMBOL_TABLE_DEPTH = 1024,  // Legal range: power of 2; changes inferred risk table depth.
    parameter int SYMBOL_ID_WIDTH    = 10,    // Legal range: log2(SYMBOL_TABLE_DEPTH); changes risk table index width.
    parameter int PRICE_WIDTH        = 64,    // Legal range: positive integer; changes comparator and price table width.
    parameter int QTY_WIDTH          = 32     // Legal range: positive integer; changes comparator and quantity table width.
) (
    input  logic        clk_pcs,
    input  logic        rst_n,

    input  logic [SYMBOL_ID_WIDTH-1:0] symbol_idx,
    input  logic [PRICE_WIDTH-1:0]     price,
    input  logic [QTY_WIDTH-1:0]       quantity,
    input  logic [7:0]                 side,
    input  logic                       sym_valid,
    input  logic                       sym_miss,
    input  logic                       sym_err,

    // Off-path limit load. Load entries after cfg_ready while the datapath is
    // quiescent; loads issued during the post-reset init sweep are ignored.
    input  logic [SYMBOL_ID_WIDTH-1:0] risk_cfg_symbol_idx,
    input  logic [PRICE_WIDTH-1:0]     risk_cfg_price_floor,
    input  logic [PRICE_WIDTH-1:0]     risk_cfg_price_ceil,
    input  logic [QTY_WIDTH-1:0]       risk_cfg_qty_max,
    input  logic                       risk_cfg_valid,
    output logic                       cfg_ready,
    input  logic                       risk_global_kill,

    output logic        risk_pass,
    output logic        risk_kill,
    output logic [3:0]  kill_reason,
    output logic        risk_err
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
    logic symbol_miss_violation;
    logic upstream_err_violation;
    logic init_violation;
    logic multi_violation;
    logic risk_kill_next;
    logic [3:0] kill_reason_next;
    logic init_active_r;
    logic [SYMBOL_ID_WIDTH-1:0] init_idx_r;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            risk_pass   <= 1'b0;
            risk_kill   <= 1'b0;
            kill_reason <= 4'h0;
            risk_err    <= 1'b0;
            global_kill_r <= 1'b0;
            init_active_r <= 1'b1;
            init_idx_r    <= '0;
        end else begin
            global_kill_r <= risk_global_kill;

            // Post-reset init sweep: every entry is written to fail-safe limits
            // (floor = max, ceiling/quantity = 0) so an unconfigured symbol can
            // never pass and no table cell is ever read undefined.
            if (init_active_r) begin
                price_floor_table[init_idx_r] <= {PRICE_WIDTH{1'b1}};
                price_ceil_table[init_idx_r]  <= '0;
                qty_max_table[init_idx_r]     <= '0;
                init_idx_r                    <= init_idx_r + {{(SYMBOL_ID_WIDTH-1){1'b0}}, 1'b1};
                if (init_idx_r == {SYMBOL_ID_WIDTH{1'b1}}) begin
                    init_active_r <= 1'b0;
                end
            end else if (risk_cfg_valid) begin
                price_floor_table[risk_cfg_symbol_idx] <= risk_cfg_price_floor;
                price_ceil_table[risk_cfg_symbol_idx]  <= risk_cfg_price_ceil;
                qty_max_table[risk_cfg_symbol_idx]     <= risk_cfg_qty_max;
            end

            risk_pass   <= sym_valid && !risk_kill_next;
            risk_kill   <= risk_kill_next;
            kill_reason <= risk_kill_next ? kill_reason_next : 4'h0;
            risk_err    <= sym_valid && sym_err;
        end
    end

    always_comb begin
        cfg_ready = !init_active_r;

        price_floor_limit = price_floor_table[symbol_idx];
        price_ceil_limit  = price_ceil_table[symbol_idx];
        qty_max_limit     = qty_max_table[symbol_idx];

        // SPEC_GAP: The spec requires reset-loaded risk tables, but does not
        // define loader pins. These ports are off-path and expected to be used
        // only during reset/quiescent configuration.
        // Table-backed checks are masked during the init sweep because unswept
        // entries are still undefined; init_violation kills instead.
        price_floor_violation = sym_valid && !init_active_r && (price < price_floor_limit);
        price_ceil_violation  = sym_valid && !init_active_r && (price > price_ceil_limit);
        quantity_violation    = sym_valid && !init_active_r && (quantity > qty_max_limit);
        global_kill_violation = sym_valid && global_kill_r;
        symbol_miss_violation = sym_valid && sym_miss;
        upstream_err_violation = sym_valid && sym_err;
        init_violation        = sym_valid && init_active_r;

        risk_kill_next = price_floor_violation
                      || price_ceil_violation
                      || quantity_violation
                      || global_kill_violation
                      || symbol_miss_violation
                      || upstream_err_violation
                      || init_violation;

        multi_violation = (price_floor_violation  && (price_ceil_violation
                                                    || quantity_violation
                                                    || global_kill_violation
                                                    || symbol_miss_violation
                                                    || upstream_err_violation))
                       || (price_ceil_violation   && (quantity_violation
                                                    || global_kill_violation
                                                    || symbol_miss_violation
                                                    || upstream_err_violation))
                       || (quantity_violation     && (global_kill_violation
                                                    || symbol_miss_violation
                                                    || upstream_err_violation))
                       || (global_kill_violation  && (symbol_miss_violation
                                                    || upstream_err_violation))
                       || (symbol_miss_violation  && upstream_err_violation);

        // SPEC_GAP: Simultaneous violation priority is not defined. Encode any
        // multi-cause kill as 4'hE so parallel checks cannot alias a single cause.
        // Evaluations during the init sweep also report reserved 4'hE: the
        // tables are not yet trustworthy, so no single spec cause applies.
        kill_reason_next = (multi_violation || init_violation) ? 4'hE :
                           (({4{price_floor_violation}}  & 4'h1)
                          | ({4{price_ceil_violation}}   & 4'h2)
                          | ({4{quantity_violation}}     & 4'h3)
                          | ({4{global_kill_violation}}  & 4'h4)
                          | ({4{symbol_miss_violation}}  & 4'h5)
                          | ({4{upstream_err_violation}} & 4'hF));
    end

endmodule
