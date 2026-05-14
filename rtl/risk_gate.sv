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

    output logic        risk_pass,
    output logic        risk_kill,
    output logic [3:0]  kill_reason,
    output logic        risk_err
);

    localparam logic [PRICE_WIDTH-1:0] DEFAULT_PRICE_FLOOR = PRICE_WIDTH'(10);
    localparam logic [PRICE_WIDTH-1:0] DEFAULT_PRICE_CEIL  = PRICE_WIDTH'(1_000_000);
    localparam logic [QTY_WIDTH-1:0]   DEFAULT_QTY_MAX     = QTY_WIDTH'(1_000);
    localparam logic                   DEFAULT_GLOBAL_KILL = 1'b0;

    logic price_floor_violation;
    logic price_ceil_violation;
    logic quantity_violation;
    logic global_kill_violation;
    logic symbol_miss_violation;
    logic upstream_err_violation;
    logic risk_kill_next;
    logic [3:0] kill_reason_next;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            risk_pass   <= 1'b0;
            risk_kill   <= 1'b0;
            kill_reason <= 4'h0;
            risk_err    <= 1'b0;
        end else begin
            risk_pass   <= sym_valid && !risk_kill_next;
            risk_kill   <= risk_kill_next;
            kill_reason <= risk_kill_next ? kill_reason_next : 4'h0;
            risk_err    <= sym_valid && sym_err;
        end
    end

    always_comb begin
        // SPEC_GAP: Risk tables and risk_global_kill are specified but absent from
        // the frozen interface. These constants are reset-time stand-ins that keep
        // the one-cycle datapath behavior testable until config ports are defined.
        price_floor_violation = sym_valid && (price < DEFAULT_PRICE_FLOOR);
        price_ceil_violation  = sym_valid && (price > DEFAULT_PRICE_CEIL);
        quantity_violation    = sym_valid && (quantity > DEFAULT_QTY_MAX);
        global_kill_violation = sym_valid && DEFAULT_GLOBAL_KILL;
        symbol_miss_violation = sym_valid && sym_miss;
        upstream_err_violation = sym_valid && sym_err;

        risk_kill_next = price_floor_violation
                      || price_ceil_violation
                      || quantity_violation
                      || global_kill_violation
                      || symbol_miss_violation
                      || upstream_err_violation;

        // SPEC_GAP: Simultaneous violation priority is not defined. OR-masked
        // reason generation keeps all checks parallel and avoids a priority chain.
        kill_reason_next = ({4{price_floor_violation}}  & 4'h1)
                         | ({4{price_ceil_violation}}   & 4'h2)
                         | ({4{quantity_violation}}     & 4'h3)
                         | ({4{global_kill_violation}}  & 4'h4)
                         | ({4{symbol_miss_violation}}  & 4'h5)
                         | ({4{upstream_err_violation}} & 4'hF);
    end

endmodule
