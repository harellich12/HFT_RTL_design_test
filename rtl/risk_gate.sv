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

    // Off-path limit load. Load entries while the datapath is quiescent.
    input  logic [SYMBOL_ID_WIDTH-1:0] risk_cfg_symbol_idx,
    input  logic [PRICE_WIDTH-1:0]     risk_cfg_price_floor,
    input  logic [PRICE_WIDTH-1:0]     risk_cfg_price_ceil,
    input  logic [QTY_WIDTH-1:0]       risk_cfg_qty_max,
    input  logic                       risk_cfg_valid,
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
    logic multi_violation;
    logic risk_kill_next;
    logic [3:0] kill_reason_next;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            risk_pass   <= 1'b0;
            risk_kill   <= 1'b0;
            kill_reason <= 4'h0;
            risk_err    <= 1'b0;
            global_kill_r <= 1'b0;
        end else begin
            global_kill_r <= risk_global_kill;

            if (risk_cfg_valid) begin
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
        price_floor_limit = price_floor_table[symbol_idx];
        price_ceil_limit  = price_ceil_table[symbol_idx];
        qty_max_limit     = qty_max_table[symbol_idx];

        // SPEC_GAP: The spec requires reset-loaded risk tables, but does not
        // define loader pins. These ports are off-path and expected to be used
        // only during reset/quiescent configuration.
        price_floor_violation = sym_valid && (price < price_floor_limit);
        price_ceil_violation  = sym_valid && (price > price_ceil_limit);
        quantity_violation    = sym_valid && (quantity > qty_max_limit);
        global_kill_violation = sym_valid && global_kill_r;
        symbol_miss_violation = sym_valid && sym_miss;
        upstream_err_violation = sym_valid && sym_err;

        risk_kill_next = price_floor_violation
                      || price_ceil_violation
                      || quantity_violation
                      || global_kill_violation
                      || symbol_miss_violation
                      || upstream_err_violation;

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
        kill_reason_next = multi_violation ? 4'hE :
                           (({4{price_floor_violation}}  & 4'h1)
                          | ({4{price_ceil_violation}}   & 4'h2)
                          | ({4{quantity_violation}}     & 4'h3)
                          | ({4{global_kill_violation}}  & 4'h4)
                          | ({4{symbol_miss_violation}}  & 4'h5)
                          | ({4{upstream_err_violation}} & 4'hF));
    end

endmodule
