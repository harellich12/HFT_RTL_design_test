// Module     : sym_id_mapper
// Description: Map exchange-native instrument identifiers to internal symbol indexes
// Latency    : 1 cycle
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
//
// Pipeline role:
// - Maps an exchange-native 64-bit instrument token into a compact symbol index.
// - Uses a deterministic direct-mapped table lookup; misses kill the frame.
// - Keeps table loading/configuration outside the datapath timing path.
module sym_id_mapper #(
    parameter int SYMBOL_TABLE_DEPTH = 1024,  // Legal range: power of 2; changes inferred table depth.
    parameter int SYMBOL_ID_WIDTH    = 10     // Legal range: log2(SYMBOL_TABLE_DEPTH); changes index and tag width.
) (
    input  logic        clk_pcs,
    input  logic        rst_n,

    input  logic [63:0] instrument_id,
    input  logic        field_valid,
    input  logic        field_err,

    // Off-path table load. Load entries while the datapath is quiescent.
    input  logic [SYMBOL_ID_WIDTH-1:0]       sym_cfg_symbol_idx,
    input  logic [64-SYMBOL_ID_WIDTH-1:0]    sym_cfg_instrument_tag,
    input  logic                             sym_cfg_entry_valid,
    input  logic                             sym_cfg_valid,

    output logic [SYMBOL_ID_WIDTH-1:0] symbol_idx,
    output logic        sym_valid,
    output logic        sym_miss,
    output logic        sym_err
);

    localparam int TAG_WIDTH = 64 - SYMBOL_ID_WIDTH;

    logic [SYMBOL_ID_WIDTH-1:0] symbol_idx_next;
    logic [TAG_WIDTH-1:0]       instrument_tag;
    logic [TAG_WIDTH-1:0]       table_tag;
    logic                       table_entry_valid;
    logic                       tag_miss;

    logic [TAG_WIDTH-1:0] tag_table [SYMBOL_TABLE_DEPTH];
    logic                 entry_valid_table [SYMBOL_TABLE_DEPTH];

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            symbol_idx <= '0;
            sym_valid  <= 1'b0;
            sym_miss   <= 1'b0;
            sym_err    <= 1'b0;
        end else begin
            if (sym_cfg_valid) begin
                tag_table[sym_cfg_symbol_idx]         <= sym_cfg_instrument_tag;
                entry_valid_table[sym_cfg_symbol_idx] <= sym_cfg_entry_valid;
            end

            symbol_idx <= symbol_idx_next;
            sym_valid  <= field_valid;
            sym_miss   <= field_valid && !field_err && tag_miss;
            sym_err    <= field_valid && field_err;
        end
    end

    always_comb begin
        symbol_idx_next = instrument_id[SYMBOL_ID_WIDTH-1:0];
        instrument_tag  = instrument_id[63:SYMBOL_ID_WIDTH];
        table_tag       = tag_table[symbol_idx_next];
        table_entry_valid = entry_valid_table[symbol_idx_next];

        // SPEC_GAP: The spec calls for a reset-time serial loader but does not
        // define its pins. This direct load port is intentionally off-path and is
        // expected to be used only during reset/quiescent configuration.
        tag_miss = !table_entry_valid || (instrument_tag != table_tag);
    end

endmodule
