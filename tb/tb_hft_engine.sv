`timescale 1ns/1ps

module tb_hft_engine;
    localparam int SYMBOL_TABLE_DEPTH = 1024;
    localparam int SYMBOL_ID_WIDTH    = 10;
    localparam int PRICE_WIDTH        = 64;
    localparam int QTY_WIDTH          = 32;

    logic        clk_pcs;
    logic        rst_n;
    logic [63:0] pcs_rxdata;
    logic [7:0]  pcs_rxctl;
    logic        pcs_rx_valid;
    logic        pcs_block_lock;

    logic [63:0] pcs_txdata;
    logic [7:0]  pcs_txctl;
    logic        pcs_tx_valid;
    logic        pcs_tx_sof;
    logic        pcs_tx_eof;
    logic [2:0]  pcs_tx_eof_bytes;

    int unsigned cycle_count;
    int unsigned mac_sof_cycle;
    int unsigned payload_sof_cycle;
    int unsigned field_valid_cycle;
    int unsigned sym_valid_cycle;
    int unsigned risk_decision_cycle;
    int unsigned tx_sof_cycle;
    int unsigned tx_eof_cycle;

    logic saw_mac_sof;
    logic saw_payload_sof;
    logic saw_field_valid;
    logic saw_sym_valid;
    logic saw_risk_decision;
    logic saw_tx_sof;
    logic saw_tx_eof;

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
        .pcs_txdata(pcs_txdata),
        .pcs_txctl(pcs_txctl),
        .pcs_tx_valid(pcs_tx_valid),
        .pcs_tx_sof(pcs_tx_sof),
        .pcs_tx_eof(pcs_tx_eof),
        .pcs_tx_eof_bytes(pcs_tx_eof_bytes)
    );

    function automatic logic [63:0] pack8 (
        input logic [7:0] b0,
        input logic [7:0] b1,
        input logic [7:0] b2,
        input logic [7:0] b3,
        input logic [7:0] b4,
        input logic [7:0] b5,
        input logic [7:0] b6,
        input logic [7:0] b7
    );
        pack8 = {b7, b6, b5, b4, b3, b2, b1, b0};
    endfunction

    task automatic drive_pcs_word (
        input logic [63:0] data_word,
        input logic [7:0]  ctl_word
    );
        @(negedge clk_pcs);
        pcs_rxdata  = data_word;
        pcs_rxctl   = ctl_word;
        pcs_rx_valid = 1'b1;
    endtask

    task automatic expect_seen (
        input logic  seen,
        input string name
    );
        if (!seen) begin
            $error("%s was not observed", name);
            $fatal;
        end
    endtask

    always #3.2 clk_pcs = ~clk_pcs;

    always_ff @(posedge clk_pcs) begin
        if (!rst_n) begin
            cycle_count        <= 0;
            mac_sof_cycle      <= 0;
            payload_sof_cycle  <= 0;
            field_valid_cycle  <= 0;
            sym_valid_cycle    <= 0;
            risk_decision_cycle <= 0;
            tx_sof_cycle       <= 0;
            tx_eof_cycle       <= 0;
            saw_mac_sof        <= 1'b0;
            saw_payload_sof    <= 1'b0;
            saw_field_valid    <= 1'b0;
            saw_sym_valid      <= 1'b0;
            saw_risk_decision  <= 1'b0;
            saw_tx_sof         <= 1'b0;
            saw_tx_eof         <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (dut.mac_rx_sof && !saw_mac_sof) begin
                mac_sof_cycle <= cycle_count;
                saw_mac_sof   <= 1'b1;
            end

            if (dut.payload_sof && !saw_payload_sof) begin
                payload_sof_cycle <= cycle_count;
                saw_payload_sof   <= 1'b1;
            end

            if (dut.field_valid && !saw_field_valid) begin
                field_valid_cycle <= cycle_count;
                saw_field_valid   <= 1'b1;
            end

            if (dut.sym_valid && !saw_sym_valid) begin
                sym_valid_cycle <= cycle_count;
                saw_sym_valid   <= 1'b1;
            end

            if ((dut.risk_pass || dut.risk_kill) && !saw_risk_decision) begin
                risk_decision_cycle <= cycle_count;
                saw_risk_decision   <= 1'b1;
            end

            if (pcs_tx_sof && !saw_tx_sof) begin
                tx_sof_cycle <= cycle_count;
                saw_tx_sof   <= 1'b1;
            end

            if (pcs_tx_eof && !saw_tx_eof) begin
                tx_eof_cycle <= cycle_count;
                saw_tx_eof   <= 1'b1;
            end
        end
    end

    initial begin
        $dumpfile("tb/hft_engine_smoke.vcd");
        $dumpvars(0, tb_hft_engine);

        clk_pcs        = 1'b0;
        rst_n          = 1'b0;
        pcs_rxdata     = 64'h0;
        pcs_rxctl      = 8'h0;
        pcs_rx_valid   = 1'b0;
        pcs_block_lock = 1'b0;

        repeat (3) @(posedge clk_pcs);
        rst_n = 1'b1;

        @(negedge clk_pcs);
        pcs_block_lock = 1'b1;

        // Preamble/SFD word, then fixed Ethernet/IP/UDP header words. Header
        // bytes are chosen to satisfy the current hdr_stripper fixed checks:
        // EtherType 0x0800, IPv4 IHL 5, UDP protocol 0x11.
        drive_pcs_word(64'hD5_55_55_55_55_55_55_55, 8'h00);
        drive_pcs_word(pack8(8'h00, 8'h11, 8'h22, 8'h33, 8'h44, 8'h55, 8'h66, 8'h77), 8'h00);
        drive_pcs_word(pack8(8'h88, 8'h99, 8'hAA, 8'hBB, 8'h08, 8'h00, 8'h45, 8'h00), 8'h00);
        drive_pcs_word(pack8(8'h00, 8'h2C, 8'h00, 8'h00, 8'h40, 8'h00, 8'h40, 8'h11), 8'h00);
        drive_pcs_word(pack8(8'h00, 8'h00, 8'h0A, 8'h00, 8'h00, 8'h01, 8'h0A, 8'h00), 8'h00);
        drive_pcs_word(pack8(8'h00, 8'h02, 8'h23, 8'h28, 8'h23, 8'h29, 8'h00, 8'h18), 8'h00);

        // Header bytes 40-41, then UDP payload bytes 0-5:
        // msg_type=0x1234, instrument_id upper bytes are zero.
        drive_pcs_word(pack8(8'h00, 8'h00, 8'h12, 8'h34, 8'h00, 8'h00, 8'h00, 8'h00), 8'h00);

        // UDP payload bytes 6-13:
        // instrument_id=0x0000000000000155 and price upper bytes zero.
        drive_pcs_word(pack8(8'h00, 8'h00, 8'h01, 8'h55, 8'h00, 8'h00, 8'h00, 8'h00), 8'h00);

        // UDP payload bytes 14-21:
        // price=100, quantity upper bytes zero and lower byte 100.
        drive_pcs_word(pack8(8'h00, 8'h00, 8'h00, 8'h64, 8'h00, 8'h00, 8'h00, 8'h64), 8'h00);

        // UDP payload bytes 22-23, then terminate at byte 2.
        drive_pcs_word(pack8(8'h42, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00), 8'b0000_0100);

        @(negedge clk_pcs);
        pcs_rx_valid = 1'b0;
        pcs_rxctl    = 8'h0;
        pcs_rxdata   = 64'h0;

        repeat (30) @(posedge clk_pcs);

        expect_seen(saw_mac_sof, "mac_sof");
        expect_seen(saw_payload_sof, "payload_sof");
        expect_seen(saw_field_valid, "field_valid");
        expect_seen(saw_sym_valid, "sym_valid");
        expect_seen(saw_risk_decision, "risk_decision");
        expect_seen(saw_tx_sof, "pcs_tx_sof");
        expect_seen(saw_tx_eof, "pcs_tx_eof");

        if (dut.frame_err || dut.field_err || dut.sym_miss || dut.sym_err || dut.risk_kill) begin
            $error("unexpected error path: frame_err=%0b field_err=%0b sym_miss=%0b sym_err=%0b risk_kill=%0b",
                   dut.frame_err, dut.field_err, dut.sym_miss, dut.sym_err, dut.risk_kill);
            $fatal;
        end

        if (tx_sof_cycle <= mac_sof_cycle) begin
            $error("invalid latency measurement: tx_sof_cycle=%0d mac_sof_cycle=%0d",
                   tx_sof_cycle, mac_sof_cycle);
            $fatal;
        end

        $display("HFT engine latency summary:");
        $display("  mac_sof -> payload_sof     : %0d cycles", payload_sof_cycle - mac_sof_cycle);
        $display("  payload_sof -> field_valid : %0d cycles", field_valid_cycle - payload_sof_cycle);
        $display("  field_valid -> sym_valid   : %0d cycles", sym_valid_cycle - field_valid_cycle);
        $display("  sym_valid -> risk decision : %0d cycles", risk_decision_cycle - sym_valid_cycle);
        $display("  risk decision -> tx_sof    : %0d cycles", tx_sof_cycle - risk_decision_cycle);
        $display("  mac_sof -> tx_sof          : %0d cycles", tx_sof_cycle - mac_sof_cycle);
        $display("  mac_sof -> tx_sof          : %0f ns", (tx_sof_cycle - mac_sof_cycle) * 6.4);
        $display("  tx_sof -> tx_eof           : %0d cycles", tx_eof_cycle - tx_sof_cycle);

        $finish;
    end
endmodule
