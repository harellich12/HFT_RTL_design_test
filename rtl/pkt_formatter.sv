// Module     : pkt_formatter
// Description: Format risk-approved fields into outbound PCS order packet words
// Latency    : 1 cycle
// Clock      : clk_pcs @ 156.25 MHz
// Reset      : rst_n, active-low synchronous
//
// Pipeline role:
// - Turns a risk-approved symbol/price/quantity/side tuple into PCS TX words.
// - Inserts dynamic payload fields into static Ethernet/IP/UDP templates.
// - Suppresses all transmission immediately when risk_kill is asserted.
module pkt_formatter #(
    parameter int SYMBOL_ID_WIDTH = 10,  // Legal range: positive integer; changes symbol field width.
    parameter int PRICE_WIDTH     = 64,  // Legal range: positive integer; changes price field width.
    parameter int QTY_WIDTH       = 32   // Legal range: positive integer; changes quantity field width.
) (
    input  logic        clk_pcs,
    input  logic        rst_n,

    input  logic [SYMBOL_ID_WIDTH-1:0] symbol_idx,
    input  logic [PRICE_WIDTH-1:0]     price,
    input  logic [QTY_WIDTH-1:0]       quantity,
    input  logic [7:0]                 side,
    input  logic                       risk_pass,
    input  logic                       risk_kill,

    // To PCS TX
    output logic [63:0] pcs_txdata,
    output logic [7:0]  pcs_txctl,
    output logic        pcs_tx_valid,
    output logic        pcs_tx_sof,
    output logic        pcs_tx_eof,
    output logic [2:0]  pcs_tx_eof_bytes
);

    localparam int TX_WORDS        = 8;
    localparam int TX_WORD_IDX_W   = 3;
    localparam int FINAL_EOF_BYTES = 0;
    localparam logic [TX_WORD_IDX_W-1:0] LAST_WORD_IDX = 3'd7;

    localparam logic [31:0] CRC_INIT      = 32'hFFFFFFFF;
    localparam logic [31:0] CRC_POLY      = 32'h04C11DB7;
    localparam logic [31:0] CRC_FINAL_XOR = 32'hFFFFFFFF;

    // SPEC_GAP: The spec does not define destination/source addressing or order
    // payload layout. This static minimum-latency template emits Ethernet/IPv4/UDP
    // with a 16-byte payload plus two Ethernet pad bytes before FCS.
    localparam logic [63:0] TEMPLATE_WORD_0 = 64'h7766_5544_3322_1100;
    localparam logic [63:0] TEMPLATE_WORD_1 = 64'h0045_0008_BBAA_9988;
    localparam logic [63:0] TEMPLATE_WORD_2 = 64'h1140_0040_0000_2C00;
    localparam logic [63:0] TEMPLATE_WORD_3 = 64'h000A_0100_000A_BF26;
    localparam logic [63:0] TEMPLATE_WORD_4 = 64'h1800_2923_2823_0200;

    logic                       tx_active_r;
    logic [TX_WORD_IDX_W-1:0]   tx_word_idx_r;
    logic [SYMBOL_ID_WIDTH-1:0] symbol_idx_r;
    logic [PRICE_WIDTH-1:0]     price_r;
    logic [QTY_WIDTH-1:0]       quantity_r;
    logic [7:0]                 side_r;
    logic [31:0]                crc_r;

    logic                       launch;
    logic                       emit_word;
    logic                       final_word;
    logic [TX_WORD_IDX_W-1:0]   tx_word_idx;
    logic [15:0]                symbol_wire;
    logic [63:0]                price_wire;
    logic [31:0]                quantity_wire;
    logic [7:0]                 side_wire;
    logic [63:0]                frame_word;
    logic [63:0]                tx_word_next;
    logic [31:0]                crc_in;
    logic [31:0]                crc_after_word;
    logic [31:0]                crc_after_tail;
    logic [31:0]                final_fcs;

    function automatic logic [31:0] crc32_bit (
        input logic [31:0] crc_in_bit,
        input logic        data_bit
    );
        logic xor_bit;
        begin
            xor_bit   = crc_in_bit[31] ^ data_bit;
            crc32_bit = {crc_in_bit[30:0], 1'b0} ^ ({32{xor_bit}} & CRC_POLY);
        end
    endfunction

    function automatic logic [31:0] crc32_byte (
        input logic [31:0] crc_in_byte,
        input logic [7:0]  data_byte
    );
        logic [31:0] crc_b0;
        logic [31:0] crc_b1;
        logic [31:0] crc_b2;
        logic [31:0] crc_b3;
        logic [31:0] crc_b4;
        logic [31:0] crc_b5;
        logic [31:0] crc_b6;
        begin
            crc_b0     = crc32_bit(crc_in_byte, data_byte[0]);
            crc_b1     = crc32_bit(crc_b0,      data_byte[1]);
            crc_b2     = crc32_bit(crc_b1,      data_byte[2]);
            crc_b3     = crc32_bit(crc_b2,      data_byte[3]);
            crc_b4     = crc32_bit(crc_b3,      data_byte[4]);
            crc_b5     = crc32_bit(crc_b4,      data_byte[5]);
            crc_b6     = crc32_bit(crc_b5,      data_byte[6]);
            crc32_byte = crc32_bit(crc_b6,      data_byte[7]);
        end
    endfunction

    function automatic logic [31:0] crc32_word (
        input logic [31:0] crc_in_word,
        input logic [63:0] data_word
    );
        logic [31:0] crc_w0;
        logic [31:0] crc_w1;
        logic [31:0] crc_w2;
        logic [31:0] crc_w3;
        logic [31:0] crc_w4;
        logic [31:0] crc_w5;
        logic [31:0] crc_w6;
        begin
            crc_w0     = crc32_byte(crc_in_word, data_word[7:0]);
            crc_w1     = crc32_byte(crc_w0,      data_word[15:8]);
            crc_w2     = crc32_byte(crc_w1,      data_word[23:16]);
            crc_w3     = crc32_byte(crc_w2,      data_word[31:24]);
            crc_w4     = crc32_byte(crc_w3,      data_word[39:32]);
            crc_w5     = crc32_byte(crc_w4,      data_word[47:40]);
            crc_w6     = crc32_byte(crc_w5,      data_word[55:48]);
            crc32_word = crc32_byte(crc_w6,      data_word[63:56]);
        end
    endfunction

    function automatic logic [31:0] crc32_four_bytes (
        input logic [31:0] crc_in_tail,
        input logic [31:0] data_tail
    );
        logic [31:0] crc_t0;
        logic [31:0] crc_t1;
        logic [31:0] crc_t2;
        begin
            crc_t0           = crc32_byte(crc_in_tail, data_tail[7:0]);
            crc_t1           = crc32_byte(crc_t0,      data_tail[15:8]);
            crc_t2           = crc32_byte(crc_t1,      data_tail[23:16]);
            crc32_four_bytes = crc32_byte(crc_t2,      data_tail[31:24]);
        end
    endfunction

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            tx_active_r      <= 1'b0;
            tx_word_idx_r    <= '0;
            symbol_idx_r     <= '0;
            price_r          <= '0;
            quantity_r       <= '0;
            side_r           <= 8'h0;
            crc_r            <= CRC_INIT;
            pcs_txdata       <= 64'h0;
            pcs_txctl        <= 8'h0;
            pcs_tx_valid     <= 1'b0;
            pcs_tx_sof       <= 1'b0;
            pcs_tx_eof       <= 1'b0;
            pcs_tx_eof_bytes <= 3'h0;
        end else if (risk_kill) begin
            tx_active_r      <= 1'b0;
            tx_word_idx_r    <= '0;
            crc_r            <= CRC_INIT;
            pcs_txdata       <= 64'h0;
            pcs_txctl        <= 8'h0;
            pcs_tx_valid     <= 1'b0;
            pcs_tx_sof       <= 1'b0;
            pcs_tx_eof       <= 1'b0;
            pcs_tx_eof_bytes <= 3'h0;
        end else begin
            pcs_tx_valid     <= emit_word;
            pcs_tx_sof       <= launch;
            pcs_tx_eof       <= emit_word && final_word;
            pcs_tx_eof_bytes <= (emit_word && final_word) ? FINAL_EOF_BYTES[2:0] : 3'h0;
            pcs_txctl        <= 8'h00;
            pcs_txdata       <= emit_word ? tx_word_next : 64'h0;

            if (launch) begin
                symbol_idx_r <= symbol_idx;
                price_r      <= price;
                quantity_r   <= quantity;
                side_r       <= side;
            end

            if (emit_word && final_word) begin
                tx_active_r   <= 1'b0;
                tx_word_idx_r <= '0;
                crc_r         <= CRC_INIT;
            end else if (emit_word) begin
                tx_active_r   <= 1'b1;
                tx_word_idx_r <= tx_word_idx + {{(TX_WORD_IDX_W-1){1'b0}}, 1'b1};
                crc_r         <= crc_after_word;
            end
        end
    end

    always_comb begin
        launch      = risk_pass && !tx_active_r;
        emit_word   = tx_active_r || launch;
        tx_word_idx = tx_active_r ? tx_word_idx_r : '0;
        final_word  = tx_word_idx == LAST_WORD_IDX;

        symbol_wire   = launch ? 16'(symbol_idx) : 16'(symbol_idx_r);
        price_wire    = launch ? 64'(price)      : 64'(price_r);
        quantity_wire = launch ? 32'(quantity)   : 32'(quantity_r);
        side_wire     = launch ? side            : side_r;

        frame_word = TEMPLATE_WORD_0;
        unique case (tx_word_idx)
            3'd0: frame_word = TEMPLATE_WORD_0;
            3'd1: frame_word = TEMPLATE_WORD_1;
            3'd2: frame_word = TEMPLATE_WORD_2;
            3'd3: frame_word = TEMPLATE_WORD_3;
            3'd4: frame_word = TEMPLATE_WORD_4;
            3'd5: frame_word = {price_wire[39:32], price_wire[47:40],
                                price_wire[55:48], price_wire[63:56],
                                symbol_wire[7:0], symbol_wire[15:8],
                                8'h00, 8'h00};
            3'd6: frame_word = {quantity_wire[7:0],  quantity_wire[15:8],
                                quantity_wire[23:16], quantity_wire[31:24],
                                price_wire[7:0],      price_wire[15:8],
                                price_wire[23:16],    price_wire[31:24]};
            3'd7: frame_word = {32'h0, 8'h00, 8'h00, 8'h00, side_wire};
        endcase

        crc_in          = tx_active_r ? crc_r : CRC_INIT;
        crc_after_word  = final_word ? crc_in : crc32_word(crc_in, frame_word);
        crc_after_tail  = crc32_four_bytes(crc_in, frame_word[31:0]);
        final_fcs       = crc_after_tail ^ CRC_FINAL_XOR;
        tx_word_next    = final_word ? {final_fcs, 24'h0, side_wire}
                                     : frame_word;
    end

endmodule
