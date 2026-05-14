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

    output logic [SYMBOL_ID_WIDTH-1:0] symbol_idx,
    output logic        sym_valid,
    output logic        sym_miss,
    output logic        sym_err
);

    localparam int TAG_WIDTH = 64 - SYMBOL_ID_WIDTH;

    logic [SYMBOL_ID_WIDTH-1:0] symbol_idx_next;
    logic [TAG_WIDTH-1:0]       instrument_tag;
    logic                       tag_miss;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            symbol_idx <= '0;
            sym_valid  <= 1'b0;
            sym_miss   <= 1'b0;
            sym_err    <= 1'b0;
        end else begin
            symbol_idx <= symbol_idx_next;
            sym_valid  <= field_valid;
            sym_miss   <= field_valid && !field_err && tag_miss;
            sym_err    <= field_valid && field_err;
        end
    end

    always_comb begin
        symbol_idx_next = instrument_id[SYMBOL_ID_WIDTH-1:0];
        instrument_tag  = instrument_id[63:SYMBOL_ID_WIDTH];

        // SPEC_GAP: The spec requires a reset-time serial table load, but the frozen
        // interface has no load pins. Minimum-latency placeholder is an identity map
        // with all valid entries tagged zero; any non-zero tag is a deterministic miss.
        tag_miss = instrument_tag != '0;
    end

endmodule
