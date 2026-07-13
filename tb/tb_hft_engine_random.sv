`timescale 1ns/1ps

// Randomized full-engine scoreboard.
//
// A deterministic xorshift32 generator builds whole inbound frames - mixing
// header errors, truncated payloads, unknown symbols, non-tradeable message
// types, risk violations, junk sides, corrupt FCS, and short/long payloads -
// and a frame-level predictor decides for each frame whether an order must
// launch and, if so, the EXACT ten TX words expected on the wire (including
// the IEEE FCS, inverted when a late bad inbound FCS must stomp the order).
// The strategy decision inside the predictor is the same DPI golden model
// used by tb_strategy_core, so the decision spec has a single source of truth.
module tb_hft_engine_random;
    localparam int SYMBOL_TABLE_DEPTH = 1024;
    localparam int SYMBOL_ID_WIDTH    = 10;
    localparam int PRICE_WIDTH        = 64;
    localparam int QTY_WIDTH          = 32;

    localparam int NUM_FRAMES     = 60;
    localparam int MAX_FRAMES     = 64;
    localparam int SHORT_PAYLOAD  = 24;  // EOF before the risk decision
    localparam int LONG_PAYLOAD   = 80;  // EOF after the risk decision
    localparam int TRUNC_PAYLOAD  = 16;  // fields incomplete -> field_err

    localparam logic [15:0] TRADEABLE_MSG = 16'h1234;

    localparam logic [63:0] PREAMBLE_SFD_WORD = 64'hD5_55_55_55_55_55_55_55;
    localparam logic [63:0] TERMINATE_WORD    = 64'h07_07_07_07_07_07_07_FD;
    localparam logic [63:0] TEMPLATE_WORD_0   = 64'h7766_5544_3322_1100;
    localparam logic [63:0] TEMPLATE_WORD_1   = 64'h0045_0008_BBAA_9988;
    localparam logic [63:0] TEMPLATE_WORD_2   = 64'h1140_0040_0000_2C00;
    localparam logic [63:0] TEMPLATE_WORD_3   = 64'h000A_0100_000A_BF26;
    localparam logic [63:0] TEMPLATE_WORD_4   = 64'h1800_2923_2823_0200;

    import "DPI-C" function int strategy_ref_decide(
        input  int     market_valid,
        input  int     market_err,
        input  int     init_active,
        input  int     msg_type,
        input  int     cfg_msg_type,
        input  int     entry_enable,
        input  int     side_policy,
        input  longint entry_qty,
        input  int     market_side,
        output int     order_side,
        output longint order_qty
    );

    localparam int DECISION_VALID = 1;

    // Frame error classes produced by the generator.
    localparam int ERR_NONE      = 0;
    localparam int ERR_ETHERTYPE = 1;
    localparam int ERR_IHL       = 2;
    localparam int ERR_PROTO     = 3;
    localparam int ERR_TRUNC     = 4;
    localparam int ERR_BADFCS    = 5;

    logic        clk_pcs;
    logic        rst_n;
    logic [63:0] pcs_rxdata;
    logic [7:0]  pcs_rxctl;
    logic        pcs_rx_valid;
    logic        pcs_block_lock;
    logic        rx_mac_fcs_valid;
    logic [SYMBOL_ID_WIDTH-1:0]    sym_cfg_symbol_idx;
    logic [64-SYMBOL_ID_WIDTH-1:0] sym_cfg_instrument_tag;
    logic                          sym_cfg_entry_valid;
    logic                          sym_cfg_valid;
    logic [SYMBOL_ID_WIDTH-1:0]    risk_cfg_symbol_idx;
    logic [PRICE_WIDTH-1:0]        risk_cfg_price_floor;
    logic [PRICE_WIDTH-1:0]        risk_cfg_price_ceil;
    logic [QTY_WIDTH-1:0]          risk_cfg_qty_max;
    logic                          risk_cfg_valid;
    logic [15:0]                   strat_cfg_msg_type;
    logic                          strat_cfg_msg_type_valid;
    logic [SYMBOL_ID_WIDTH-1:0]    strat_cfg_symbol_idx;
    logic                          strat_cfg_entry_enable;
    logic [1:0]                    strat_cfg_side_policy;
    logic [QTY_WIDTH-1:0]          strat_cfg_qty;
    logic                          strat_cfg_valid;
    logic                          cfg_ready;
    logic                          risk_global_kill;
    logic [3:0]                    risk_kill_reason;
    logic                          risk_err;
    logic [15:0]                   tx_launch_drops;
    logic [15:0]                   tx_stomps;

    logic [63:0] pcs_txdata;
    logic [7:0]  pcs_txctl;
    logic        pcs_tx_valid;
    logic        pcs_tx_sof;
    logic        pcs_tx_eof;
    logic [2:0]  pcs_tx_eof_bytes;

    // Configuration mirrors (the testbench wrote them, so it knows them).
    logic                 cfg_sym_hit    [SYMBOL_TABLE_DEPTH];
    logic [63:0]          cfg_floor      [SYMBOL_TABLE_DEPTH];
    logic [63:0]          cfg_ceil       [SYMBOL_TABLE_DEPTH];
    logic [31:0]          cfg_qty_max    [SYMBOL_TABLE_DEPTH];
    logic                 cfg_str_enable [SYMBOL_TABLE_DEPTH];
    logic [1:0]           cfg_str_policy [SYMBOL_TABLE_DEPTH];
    logic [31:0]          cfg_str_qty    [SYMBOL_TABLE_DEPTH];

    // Generated frame byte buffer (after the preamble word).
    logic [7:0]  gen_bytes [0:191];
    int          gen_len;

    // Scoreboard storage.
    logic [63:0] exp_frames [0:MAX_FRAMES-1][0:9];
    int          exp_count;
    int          exp_stomp_count;
    logic [63:0] act_frames [0:MAX_FRAMES-1][0:9];
    int          act_count;
    int          act_widx;

    // Predictor state: a bad-FCS frame that never resolves leaves the launch
    // suppression armed for the next resolving frame (fail-safe corner).
    logic        pending_suppress;

    logic [31:0] rand_state;

    hft_engine #(
        .SYMBOL_TABLE_DEPTH(SYMBOL_TABLE_DEPTH),
        .SYMBOL_ID_WIDTH(SYMBOL_ID_WIDTH),
        .PRICE_WIDTH(PRICE_WIDTH),
        .QTY_WIDTH(QTY_WIDTH)
    ) dut (
        .clk_pcs(clk_pcs),
        .rst_n(rst_n),
        .pcs_rxdata(pcs_rxdata),
        .pcs_rxctl(pcs_rxctl),
        .pcs_rx_valid(pcs_rx_valid),
        .pcs_block_lock(pcs_block_lock),
        .rx_mac_fcs_valid(rx_mac_fcs_valid),
        .sym_cfg_symbol_idx(sym_cfg_symbol_idx),
        .sym_cfg_instrument_tag(sym_cfg_instrument_tag),
        .sym_cfg_entry_valid(sym_cfg_entry_valid),
        .sym_cfg_valid(sym_cfg_valid),
        .risk_cfg_symbol_idx(risk_cfg_symbol_idx),
        .risk_cfg_price_floor(risk_cfg_price_floor),
        .risk_cfg_price_ceil(risk_cfg_price_ceil),
        .risk_cfg_qty_max(risk_cfg_qty_max),
        .risk_cfg_valid(risk_cfg_valid),
        .strat_cfg_msg_type(strat_cfg_msg_type),
        .strat_cfg_msg_type_valid(strat_cfg_msg_type_valid),
        .strat_cfg_symbol_idx(strat_cfg_symbol_idx),
        .strat_cfg_entry_enable(strat_cfg_entry_enable),
        .strat_cfg_side_policy(strat_cfg_side_policy),
        .strat_cfg_qty(strat_cfg_qty),
        .strat_cfg_valid(strat_cfg_valid),
        .cfg_ready(cfg_ready),
        .risk_global_kill(risk_global_kill),
        .risk_kill_reason(risk_kill_reason),
        .risk_err(risk_err),
        .tx_launch_drops(tx_launch_drops),
        .tx_stomps(tx_stomps),
        .pcs_txdata(pcs_txdata),
        .pcs_txctl(pcs_txctl),
        .pcs_tx_valid(pcs_tx_valid),
        .pcs_tx_sof(pcs_tx_sof),
        .pcs_tx_eof(pcs_tx_eof),
        .pcs_tx_eof_bytes(pcs_tx_eof_bytes)
    );

    // ------------------------------------------------------------------ CRC
    function automatic logic [31:0] crc32_byte (
        input logic [31:0] crc_in,
        input logic [7:0]  data_byte
    );
        logic [31:0] c;
        logic        xor_bit;
        begin
            c = crc_in;
            for (int i = 0; i < 8; i++) begin
                xor_bit = c[31] ^ data_byte[i];
                c = {c[30:0], 1'b0} ^ ({32{xor_bit}} & 32'h04C11DB7);
            end
            crc32_byte = c;
        end
    endfunction

    function automatic logic [7:0] bitrev8 (input logic [7:0] b);
        bitrev8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
    endfunction

    function automatic logic [31:0] fcs_wire_bytes (input logic [31:0] crc_final);
        fcs_wire_bytes = {bitrev8(crc_final[7:0]), bitrev8(crc_final[15:8]),
                          bitrev8(crc_final[23:16]), bitrev8(crc_final[31:24])};
    endfunction

    // IEEE FCS (wire order) over gen_bytes[0..gen_len-1].
    function automatic logic [31:0] frame_fcs ();
        logic [31:0] c;
        begin
            c = 32'hFFFFFFFF;
            for (int i = 0; i < gen_len; i++) begin
                c = crc32_byte(c, gen_bytes[i]);
            end
            frame_fcs = fcs_wire_bytes(c ^ 32'hFFFFFFFF);
        end
    endfunction

    function automatic logic [31:0] xorshift32 (input logic [31:0] s_in);
        logic [31:0] s;
        begin
            s = s_in;
            s = s ^ (s << 13);
            s = s ^ (s >> 17);
            s = s ^ (s << 5);
            xorshift32 = s;
        end
    endfunction

    // ------------------------------------------------- expected TX frame
    // Replicates pkt_formatter's frame construction, FCS included.
    task automatic push_expected_tx (
        input logic [SYMBOL_ID_WIDTH-1:0] o_symbol,
        input logic [63:0]                o_price,
        input logic [31:0]                o_qty,
        input logic [7:0]                 o_side,
        input logic                       stomped
    );
        logic [63:0] w [0:9];
        logic [15:0] sym16;
        logic [31:0] c;
        logic [31:0] fcs;
        begin
            sym16 = 16'(o_symbol);
            w[0] = PREAMBLE_SFD_WORD;
            w[1] = TEMPLATE_WORD_0;
            w[2] = TEMPLATE_WORD_1;
            w[3] = TEMPLATE_WORD_2;
            w[4] = TEMPLATE_WORD_3;
            w[5] = TEMPLATE_WORD_4;
            w[6] = {o_price[39:32], o_price[47:40], o_price[55:48], o_price[63:56],
                    sym16[7:0], sym16[15:8], 8'h00, 8'h00};
            w[7] = {o_qty[7:0], o_qty[15:8], o_qty[23:16], o_qty[31:24],
                    o_price[7:0], o_price[15:8], o_price[23:16], o_price[31:24]};
            w[8] = {32'h0, 8'h00, 8'h00, 8'h00, o_side};
            c = 32'hFFFFFFFF;
            for (int wi = 1; wi <= 7; wi++) begin
                for (int b = 0; b < 8; b++) begin
                    c = crc32_byte(c, w[wi][b*8 +: 8]);
                end
            end
            for (int b = 0; b < 4; b++) begin
                c = crc32_byte(c, w[8][b*8 +: 8]);
            end
            fcs = fcs_wire_bytes(c ^ 32'hFFFFFFFF);
            if (stomped) begin
                fcs = ~fcs;
                exp_stomp_count++;
            end
            w[8][63:32] = fcs;
            w[9] = TERMINATE_WORD;
            for (int wi = 0; wi < 10; wi++) begin
                exp_frames[exp_count][wi] = w[wi];
            end
            exp_count++;
        end
    endtask

    // ------------------------------------------------- inbound frame drive
    task automatic drive_word (
        input logic [63:0] data_word,
        input logic [7:0]  ctl_word
    );
        @(negedge clk_pcs);
        pcs_rxdata   = data_word;
        pcs_rxctl    = ctl_word;
        pcs_rx_valid = 1'b1;
    endtask

    task automatic drive_idle_words (input int n);
        for (int i = 0; i < n; i++) begin
            @(negedge clk_pcs);
            pcs_rxdata   = 64'h0;
            pcs_rxctl    = 8'h00;
            pcs_rx_valid = 1'b0;
        end
    endtask

    // Sends preamble + gen_bytes (+FCS already appended) with terminate at
    // the correct lane.
    task automatic drive_gen_frame ();
        int          full_words;
        int          rem;
        logic [63:0] w;
        logic [7:0]  ctl;
        begin
            drive_word(PREAMBLE_SFD_WORD, 8'h00);
            full_words = gen_len / 8;
            rem        = gen_len % 8;
            for (int wi = 0; wi < full_words; wi++) begin
                w = 64'h0;
                for (int b = 0; b < 8; b++) begin
                    w[b*8 +: 8] = gen_bytes[wi*8 + b];
                end
                drive_word(w, 8'h00);
            end
            // Terminate word: 'rem' data bytes then /T/ plus idle controls.
            w   = {8{8'h07}};
            ctl = 8'hFF;
            for (int b = 0; b < 8; b++) begin
                if (b < rem) begin
                    w[b*8 +: 8] = gen_bytes[full_words*8 + b];
                    ctl[b]      = 1'b0;
                end else if (b == rem) begin
                    w[b*8 +: 8] = 8'hFD;
                end
            end
            drive_word(w, ctl);
        end
    endtask

    // ------------------------------------------------- frame generation
    // Builds gen_bytes for one frame and returns its parameters by side
    // effect on module-scope generation variables below.
    logic [63:0] g_instrument;
    logic [15:0] g_msg_type;
    logic [63:0] g_price;
    logic [7:0]  g_side;
    int          g_err_class;
    int          g_payload_len;

    task automatic build_gen_frame ();
        int p;
        logic [7:0] et_hi, et_lo, verihl, proto;
        begin
            et_hi  = 8'h08;
            et_lo  = (g_err_class == ERR_ETHERTYPE) ? 8'h06 : 8'h00;
            verihl = (g_err_class == ERR_IHL) ? 8'h46 : 8'h45;
            proto  = (g_err_class == ERR_PROTO) ? 8'h06 : 8'h11;

            p = 0;
            // Ethernet: DA, SA, EtherType
            for (int i = 0; i < 6; i++) begin gen_bytes[p] = 8'h10 + i[7:0]; p++; end
            for (int i = 0; i < 6; i++) begin gen_bytes[p] = 8'h20 + i[7:0]; p++; end
            gen_bytes[p] = et_hi; p++;
            gen_bytes[p] = et_lo; p++;
            // IPv4 (20 bytes, fixed shape; only IHL/protocol are checked)
            gen_bytes[p] = verihl; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h2C; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h40; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h40; p++;
            gen_bytes[p] = proto; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h0A; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h01; p++;
            gen_bytes[p] = 8'h0A; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h02; p++;
            // UDP (8 bytes)
            gen_bytes[p] = 8'h23; p++;
            gen_bytes[p] = 8'h28; p++;
            gen_bytes[p] = 8'h23; p++;
            gen_bytes[p] = 8'h29; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h18; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h00; p++;
            // Payload: msg_type, instrument, price, qty, side (big-endian)
            gen_bytes[p] = g_msg_type[15:8]; p++;
            gen_bytes[p] = g_msg_type[7:0];  p++;
            for (int i = 7; i >= 0; i--) begin gen_bytes[p] = g_instrument[i*8 +: 8]; p++; end
            for (int i = 7; i >= 0; i--) begin gen_bytes[p] = g_price[i*8 +: 8]; p++; end
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h00; p++;
            gen_bytes[p] = 8'h37; p++;  // market qty: must never appear in TX
            gen_bytes[p] = g_side; p++;
            while (p < 42 + g_payload_len) begin
                gen_bytes[p] = 8'h5A;
                p++;
            end
            gen_len = p;

            // Append the FCS (corrupted when requested).
            begin
                logic [31:0] f;
                f = frame_fcs();
                if (g_err_class == ERR_BADFCS) begin
                    f = f ^ 32'h0000_0001;
                end
                gen_bytes[gen_len]   = f[7:0];
                gen_bytes[gen_len+1] = f[15:8];
                gen_bytes[gen_len+2] = f[23:16];
                gen_bytes[gen_len+3] = f[31:24];
                gen_len = gen_len + 4;
            end
        end
    endtask

    // ------------------------------------------------- frame prediction
    task automatic predict_frame ();
        logic [SYMBOL_ID_WIDTH-1:0] idx;
        logic       parse_ok;
        logic       symbol_miss;
        int         decision;
        int         o_side;
        longint     o_qty;
        logic       killed;
        logic       resolves;
        begin
            idx = g_instrument[SYMBOL_ID_WIDTH-1:0];

            parse_ok = (g_err_class != ERR_ETHERTYPE)
                    && (g_err_class != ERR_IHL)
                    && (g_err_class != ERR_PROTO)
                    && (g_payload_len >= 23);

            if (!parse_ok) begin
                // No field_valid, so no strategy/risk resolution. A corrupt
                // FCS on such a frame leaves the launch suppression armed.
                if (g_err_class == ERR_BADFCS) begin
                    pending_suppress = 1'b1;
                end
                return;
            end

            symbol_miss = !(cfg_sym_hit[idx]
                            && (g_instrument[63:SYMBOL_ID_WIDTH] == '0));

            decision = strategy_ref_decide(
                1, 0, 0,
                {16'h0, g_msg_type}, {16'h0, TRADEABLE_MSG},
                cfg_str_enable[idx] ? 1 : 0,
                {30'h0, cfg_str_policy[idx]},
                {32'h0, cfg_str_qty[idx]},
                {24'h0, g_side},
                o_side, o_qty);

            resolves = 1'b1;  // valid, suppress: both consume the window

            if (decision == DECISION_VALID) begin
                killed = symbol_miss
                      || (g_price < cfg_floor[idx])
                      || (g_price > cfg_ceil[idx])
                      || (o_qty[31:0] > cfg_qty_max[idx]);

                if (!killed) begin
                    if (pending_suppress) begin
                        // Armed by an earlier unresolved bad-FCS frame:
                        // this launch is dropped (fail-safe), then cleared.
                    end else if (g_err_class == ERR_BADFCS) begin
                        if (g_payload_len >= LONG_PAYLOAD) begin
                            // EOF lands after launch: frame goes out stomped.
                            push_expected_tx(idx, g_price, o_qty[31:0],
                                             o_side[7:0], 1'b1);
                        end
                        // Short frame: EOF precedes the decision, launch is
                        // suppressed; no TX.
                    end else begin
                        push_expected_tx(idx, g_price, o_qty[31:0],
                                         o_side[7:0], 1'b0);
                    end
                end
            end

            if (resolves) begin
                pending_suppress = 1'b0;
            end
        end
    endtask

    // ------------------------------------------------- TX monitor
    always @(posedge clk_pcs) begin
        if (rst_n && pcs_tx_valid) begin
            if (pcs_tx_sof) begin
                act_widx = 0;
            end
            if (act_widx < 10) begin
                act_frames[act_count][act_widx] = pcs_txdata;
            end
            act_widx = act_widx + 1;
            if (pcs_tx_eof) begin
                if (act_widx != 10) begin
                    $error("TX frame %0d length %0d words, expected 10",
                           act_count, act_widx);
                    $fatal;
                end
                act_count = act_count + 1;
            end
        end
    end

    task automatic load_all_config ();
        // Symbols: 0x011 opposite/64, 0x022 same/200 (risk max 100 -> qty
        // kill on every trade), 0x033 fixed-buy/500 with a narrow price band,
        // 0x044 mapped but strategy-disabled.
        sym_load(10'h011); sym_load(10'h022); sym_load(10'h033); sym_load(10'h044);
        risk_load(10'h011, 64'd10,  64'd1_000_000, 32'd1000);
        risk_load(10'h022, 64'd10,  64'd1_000_000, 32'd100);
        risk_load(10'h033, 64'd500, 64'd1000,      32'd1000);
        risk_load(10'h044, 64'd10,  64'd1_000_000, 32'd1000);
        strat_load(10'h011, 1'b1, 2'b01, 32'd64);
        strat_load(10'h022, 1'b1, 2'b00, 32'd200);
        strat_load(10'h033, 1'b1, 2'b10, 32'd500);
        strat_load(10'h044, 1'b0, 2'b00, 32'd1);

        @(negedge clk_pcs);
        strat_cfg_msg_type       = TRADEABLE_MSG;
        strat_cfg_msg_type_valid = 1'b1;
        @(negedge clk_pcs);
        strat_cfg_msg_type_valid = 1'b0;
    endtask

    task automatic sym_load (input logic [SYMBOL_ID_WIDTH-1:0] idx);
        @(negedge clk_pcs);
        sym_cfg_symbol_idx     = idx;
        sym_cfg_instrument_tag = '0;
        sym_cfg_entry_valid    = 1'b1;
        sym_cfg_valid          = 1'b1;
        cfg_sym_hit[idx] = 1'b1;
        @(negedge clk_pcs);
        sym_cfg_valid = 1'b0;
    endtask

    task automatic risk_load (
        input logic [SYMBOL_ID_WIDTH-1:0] idx,
        input logic [63:0] floor_v,
        input logic [63:0] ceil_v,
        input logic [31:0] qmax_v
    );
        @(negedge clk_pcs);
        risk_cfg_symbol_idx  = idx;
        risk_cfg_price_floor = floor_v;
        risk_cfg_price_ceil  = ceil_v;
        risk_cfg_qty_max     = qmax_v;
        risk_cfg_valid       = 1'b1;
        cfg_floor[idx]   = floor_v;
        cfg_ceil[idx]    = ceil_v;
        cfg_qty_max[idx] = qmax_v;
        @(negedge clk_pcs);
        risk_cfg_valid = 1'b0;
    endtask

    task automatic strat_load (
        input logic [SYMBOL_ID_WIDTH-1:0] idx,
        input logic        en,
        input logic [1:0]  pol,
        input logic [31:0] q
    );
        @(negedge clk_pcs);
        strat_cfg_symbol_idx   = idx;
        strat_cfg_entry_enable = en;
        strat_cfg_side_policy  = pol;
        strat_cfg_qty          = q;
        strat_cfg_valid        = 1'b1;
        cfg_str_enable[idx] = en;
        cfg_str_policy[idx] = pol;
        cfg_str_qty[idx]    = q;
        @(negedge clk_pcs);
        strat_cfg_valid = 1'b0;
    endtask

    always #3.2 clk_pcs = ~clk_pcs;

    initial begin
        int gap;

        $dumpfile("tb/hft_engine_random_smoke.vcd");
        $dumpvars(0, tb_hft_engine_random);

        clk_pcs        = 1'b0;
        rst_n          = 1'b0;
        pcs_rxdata     = 64'h0;
        pcs_rxctl      = 8'h00;
        pcs_rx_valid   = 1'b0;
        pcs_block_lock = 1'b0;
        sym_cfg_symbol_idx = '0;
        sym_cfg_instrument_tag = '0;
        sym_cfg_entry_valid = 1'b0;
        sym_cfg_valid = 1'b0;
        risk_cfg_symbol_idx = '0;
        risk_cfg_price_floor = '0;
        risk_cfg_price_ceil = '0;
        risk_cfg_qty_max = '0;
        risk_cfg_valid = 1'b0;
        strat_cfg_msg_type = 16'h0;
        strat_cfg_msg_type_valid = 1'b0;
        strat_cfg_symbol_idx = '0;
        strat_cfg_entry_enable = 1'b0;
        strat_cfg_side_policy = 2'b00;
        strat_cfg_qty = 32'h0;
        strat_cfg_valid = 1'b0;
        risk_global_kill = 1'b0;

        for (int i = 0; i < SYMBOL_TABLE_DEPTH; i++) begin
            cfg_sym_hit[i]    = 1'b0;
            cfg_floor[i]      = '1;
            cfg_ceil[i]       = '0;
            cfg_qty_max[i]    = '0;
            cfg_str_enable[i] = 1'b0;
            cfg_str_policy[i] = 2'b00;
            cfg_str_qty[i]    = '0;
        end

        exp_count        = 0;
        exp_stomp_count  = 0;
        act_count        = 0;
        act_widx         = 0;
        pending_suppress = 1'b0;
        rand_state       = 32'h5EED_F00D;

        repeat (3) @(posedge clk_pcs);
        rst_n = 1'b1;

        wait (cfg_ready === 1'b1);
        load_all_config();

        @(negedge clk_pcs);
        pcs_block_lock = 1'b1;

        for (int f = 0; f < NUM_FRAMES; f++) begin
            // Error class: mostly clean, each fault class reachable.
            rand_state = xorshift32(rand_state);
            case (rand_state[3:0])
                4'd10:   g_err_class = ERR_ETHERTYPE;
                4'd11:   g_err_class = ERR_IHL;
                4'd12:   g_err_class = ERR_PROTO;
                4'd13:   g_err_class = ERR_TRUNC;
                4'd14:   g_err_class = ERR_BADFCS;
                4'd15:   g_err_class = ERR_BADFCS;
                default: g_err_class = ERR_NONE;
            endcase

            // Instrument: configured hits, a tag miss, and an unmapped index,
            // weighted toward tradeable symbols so launches stay frequent.
            rand_state = xorshift32(rand_state);
            case (rand_state[2:0])
                3'd0, 3'd1, 3'd2: g_instrument = 64'h011;
                3'd3:             g_instrument = 64'h022;
                3'd4:             g_instrument = 64'h033;
                3'd5:             g_instrument = 64'h044;
                3'd6:             g_instrument = 64'h1_0000_0011;  // tag miss on 0x011
                default:          g_instrument = 64'h300;          // unmapped index
            endcase

            rand_state = xorshift32(rand_state);
            g_msg_type = (rand_state[4:3] != 2'b00) ? TRADEABLE_MSG
                                                    : {8'h43, rand_state[12:5]};

            rand_state = xorshift32(rand_state);
            case (rand_state[1:0])
                2'd0: g_price = 64'd100;   // below 0x033's floor
                2'd1: g_price = 64'd600;   // inside every band
                2'd2: g_price = 64'd2000;  // above 0x033's ceiling
                2'd3: g_price = 64'd5;     // below every floor
            endcase

            rand_state = xorshift32(rand_state);
            case (rand_state[1:0])
                2'd0, 2'd1: g_side = 8'h42;
                2'd2:       g_side = 8'h53;
                2'd3:       g_side = rand_state[10:3];  // usually junk
            endcase

            rand_state = xorshift32(rand_state);
            if (g_err_class == ERR_TRUNC) begin
                g_payload_len = TRUNC_PAYLOAD;
            end else begin
                g_payload_len = rand_state[5] ? LONG_PAYLOAD : SHORT_PAYLOAD;
            end

            build_gen_frame();
            predict_frame();
            drive_gen_frame();

            rand_state = xorshift32(rand_state);
            gap = 1 + {30'h0, rand_state[1:0]};
            drive_idle_words(gap);
        end

        // Directed epilogue: corners that must be exercised regardless of
        // how the random seed happens to fall.

        // 1. Long tradeable frame with corrupt FCS: launches, then the late
        //    bad EOF stomps the outbound FCS.
        g_err_class   = ERR_BADFCS;
        g_instrument  = 64'h011;
        g_msg_type    = TRADEABLE_MSG;
        g_price       = 64'd600;
        g_side        = 8'h42;
        g_payload_len = LONG_PAYLOAD;
        build_gen_frame();
        predict_frame();
        drive_gen_frame();
        drive_idle_words(2);

        // 2. Corrupt-FCS frame that never resolves (bad EtherType kills the
        //    parse), followed by a clean tradeable frame whose launch must be
        //    eaten by the armed fail-safe suppression.
        g_err_class   = ERR_ETHERTYPE;  // build_gen_frame keys FCS on class...
        g_instrument  = 64'h011;
        g_msg_type    = TRADEABLE_MSG;
        g_price       = 64'd600;
        g_side        = 8'h42;
        g_payload_len = SHORT_PAYLOAD;
        build_gen_frame();
        // Corrupt the FCS by hand: the class only encodes one fault, and this
        // frame needs both a parse failure and a bad FCS.
        gen_bytes[gen_len-4] = gen_bytes[gen_len-4] ^ 8'h01;
        pending_suppress = 1'b1;  // predictor: unresolved bad-FCS frame arms it
        drive_gen_frame();
        drive_idle_words(2);

        g_err_class   = ERR_NONE;
        g_instrument  = 64'h011;
        g_msg_type    = TRADEABLE_MSG;
        g_price       = 64'd600;
        g_side        = 8'h53;
        g_payload_len = SHORT_PAYLOAD;
        build_gen_frame();
        predict_frame();  // pending_suppress eats this launch, then clears
        drive_gen_frame();
        drive_idle_words(2);

        // 3. Same clean frame again: suppression is spent, this one launches.
        build_gen_frame();
        predict_frame();
        drive_gen_frame();

        // Drain: let the last frames decide and transmit.
        drive_idle_words(2);
        @(negedge clk_pcs);
        pcs_rx_valid = 1'b0;
        repeat (60) @(posedge clk_pcs);

        if (act_count != exp_count) begin
            $error("scoreboard: %0d TX frames observed, %0d predicted",
                   act_count, exp_count);
            $fatal;
        end

        for (int fi = 0; fi < exp_count; fi++) begin
            for (int wi = 0; wi < 10; wi++) begin
                if (act_frames[fi][wi] !== exp_frames[fi][wi]) begin
                    $error("scoreboard: frame %0d word %0d mismatch: actual=%016h expected=%016h",
                           fi, wi, act_frames[fi][wi], exp_frames[fi][wi]);
                    $fatal;
                end
            end
        end

        if (tx_stomps !== exp_stomp_count[15:0]) begin
            $error("scoreboard: tx_stomps=%0d, predicted %0d",
                   tx_stomps, exp_stomp_count);
            $fatal;
        end

        if (tx_launch_drops !== 16'h0) begin
            $error("scoreboard: unexpected launch drops: %0d", tx_launch_drops);
            $fatal;
        end

        $display("engine scoreboard: %0d random + 4 directed frames driven, %0d orders predicted and matched word-for-word, %0d stomps",
                 NUM_FRAMES, exp_count, exp_stomp_count);

        repeat (2) @(posedge clk_pcs);
        $finish;
    end
endmodule
