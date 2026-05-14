// Module     : sym_id_mapper_assertions
// Description: Assertion bind checks for sym_id_mapper latency and miss behavior
// Latency    : N/A assertion bind
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
module sym_id_mapper_assertions #(
    parameter int SYMBOL_TABLE_DEPTH = 1024,  // Legal range: power of 2; matches bound sym_id_mapper table depth.
    parameter int SYMBOL_ID_WIDTH    = 10     // Legal range: log2(SYMBOL_TABLE_DEPTH); matches bound sym_id_mapper index width.
) (
    input logic                         clk_pcs,
    input logic                         rst_n,

    input logic [63:0]                  instrument_id,
    input logic                         field_valid,
    input logic                         field_err,

    input logic [SYMBOL_ID_WIDTH-1:0]   symbol_idx,
    input logic                         sym_valid,
    input logic                         sym_miss,
    input logic                         sym_err
);

    localparam int TAG_WIDTH = 64 - SYMBOL_ID_WIDTH;

    logic [SYMBOL_ID_WIDTH-1:0] expected_symbol_idx;
    logic [TAG_WIDTH-1:0]       expected_tag;
    logic                       expected_tag_miss;

    always_comb begin
        expected_symbol_idx = instrument_id[SYMBOL_ID_WIDTH-1:0];
        expected_tag        = instrument_id[63:SYMBOL_ID_WIDTH];
        expected_tag_miss   = expected_tag != '0;
    end

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (!field_valid) |=> (!sym_valid && !sym_miss && !sym_err));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        field_valid |=> sym_valid);

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        field_valid |=> (symbol_idx == $past(expected_symbol_idx)));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (field_valid && field_err) |=> (sym_valid && sym_err && !sym_miss));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (field_valid && !field_err && expected_tag_miss) |=> (sym_valid && sym_miss && !sym_err));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        (field_valid && !field_err && !expected_tag_miss) |=> (sym_valid && !sym_miss && !sym_err));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        sym_err |-> (sym_valid && !sym_miss));

    assert property (@(posedge clk_pcs) disable iff (!rst_n)
        sym_miss |-> (sym_valid && !sym_err));

endmodule

bind sym_id_mapper sym_id_mapper_assertions #(
    .SYMBOL_TABLE_DEPTH(SYMBOL_TABLE_DEPTH),
    .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH)
) u_sym_id_mapper_assertions (
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
