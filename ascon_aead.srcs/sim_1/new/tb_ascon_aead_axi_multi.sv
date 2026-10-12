`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 10/12/2026 05:00:00 PM
// Design Name:
// Module Name: tb_ascon_aead_axi_multi
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
// Testbench for ascon_aead_axi_multi #(K) through AXI4-Lite.
//  - Reads encrypt_tv.txt / decrypt_tv.txt and runs the messages in
//    batches of K, one message per core, all cores in flight together:
//      1. per core: stage KEY / NONCE / MODE, start core i
//      2. AD blocks interleaved over the cores (block j of every core)
//      3. PT/CT blocks interleaved over the cores, then read OUT per core
//      4. read TAG per core
//  - Checks ID, GSTATUS (busy bits after start) and the AXI protocol.
//  - K is a parameter (scripts/run_axi_multi_regression.tcl -k N).
//
// Dependencies: ascon_aead_axi_multi
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module tb_ascon_aead_axi_multi #(
        parameter integer K = 4
    )(

    );

    // ----------------------------------------------------------
    // Register map (see ascon_aead_axi_multi)
    // ----------------------------------------------------------
    localparam [11:0] G_CONTROL = 12'h000;
    localparam [11:0] G_MODE    = 12'h004;
    localparam [11:0] G_STATUS  = 12'h008;
    localparam [11:0] G_ID      = 12'h00c;
    localparam [11:0] G_KEY     = 12'h010;
    localparam [11:0] G_NONCE   = 12'h020;

    localparam [7:0]  C_CONTROL = 8'h00;
    localparam [7:0]  C_STATUS  = 8'h08;
    localparam [7:0]  C_AD      = 8'h40;
    localparam [7:0]  C_AD_CTRL = 8'h50;
    localparam [7:0]  C_PT      = 8'h60;
    localparam [7:0]  C_PT_CTRL = 8'h70;
    localparam [7:0]  C_OUT     = 8'h80;
    localparam [7:0]  C_TAG     = 8'ha0;

    localparam ST_OUT_VALID = 2;
    localparam ST_TAG_VALID = 3;
    localparam ST_AD_PEND   = 5;
    localparam ST_PT_PEND   = 6;

    localparam N_TESTS    = 100;
    localparam POLL_LIMIT = 1000;

    function [11:0] core_addr;
        input integer core;
        input [7:0]   off;
        begin
            core_addr = ((core + 1) << 8) | off;
        end
    endfunction

    // ----------------------------------------------------------
    // DUT
    // ----------------------------------------------------------
    reg         clk  = 0;
    reg         rstn = 0;

    reg  [11:0] awaddr  = 0;
    reg         awvalid = 0;
    wire        awready;
    reg  [31:0] wdata   = 0;
    reg  [3:0]  wstrb   = 4'hf;
    reg         wvalid  = 0;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready  = 0;
    reg  [11:0] araddr  = 0;
    reg         arvalid = 0;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready  = 0;

    always #5 clk = ~clk;

    ascon_aead_axi_multi #(.K(K)) dut (
        .s_axi_aclk   (clk),
        .s_axi_aresetn(rstn),
        .s_axi_awaddr (awaddr),
        .s_axi_awprot (3'd0),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata  (wdata),
        .s_axi_wstrb  (wstrb),
        .s_axi_wvalid (wvalid),
        .s_axi_wready (wready),
        .s_axi_bresp  (bresp),
        .s_axi_bvalid (bvalid),
        .s_axi_bready (bready),
        .s_axi_araddr (araddr),
        .s_axi_arprot (3'd0),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata  (rdata),
        .s_axi_rresp  (rresp),
        .s_axi_rvalid (rvalid),
        .s_axi_rready (rready)
    );

    integer errors     = 0;
    integer proto_errs = 0;

    // ----------------------------------------------------------
    // AXI protocol monitor: responses only after the handshake
    // ----------------------------------------------------------
    reg w_hs_done = 0;
    reg r_hs_done = 0;

    always @(posedge clk) begin
        if (rstn) begin
            if (bvalid && !w_hs_done) begin
                if (proto_errs < 5) $display("%0t AXI ERROR: BVALID before AW/W handshake", $time);
                proto_errs = proto_errs + 1;
            end
            if (rvalid && !r_hs_done) begin
                if (proto_errs < 5) $display("%0t AXI ERROR: RVALID before AR handshake", $time);
                proto_errs = proto_errs + 1;
            end
        end
        if (awvalid && awready && wvalid && wready) w_hs_done <= 1'b1;
        else if (bvalid && bready)                  w_hs_done <= 1'b0;
        if (arvalid && arready)                     r_hs_done <= 1'b1;
        else if (rvalid && rready)                  r_hs_done <= 1'b0;
    end

    // ----------------------------------------------------------
    // Strict AXI4-Lite master
    // ----------------------------------------------------------
    task axi_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            awaddr = addr; wdata = data; awvalid = 1; wvalid = 1;
            @(posedge clk);
            while (!(awready && wready)) @(posedge clk);
            @(negedge clk);
            awvalid = 0; wvalid = 0; bready = 1;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            @(negedge clk);
            bready = 0;
        end
    endtask

    task axi_read;
        input  [11:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            araddr = addr; arvalid = 1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            @(negedge clk);
            arvalid = 0; rready = 1;
            @(posedge clk);
            while (!rvalid) @(posedge clk);
            data = rdata;
            @(negedge clk);
            rready = 0;
        end
    endtask

    task write128;
        input [11:0]  base;
        input [127:0] v;
        begin
            axi_write(base,      v[127:96]);
            axi_write(base + 4,  v[95:64]);
            axi_write(base + 8,  v[63:32]);
            axi_write(base + 12, v[31:0]);
        end
    endtask

    task read128;
        input  [11:0]  base;
        output [127:0] v;
        reg    [31:0]  w;
        begin
            axi_read(base,      w); v[127:96] = w;
            axi_read(base + 4,  w); v[95:64]  = w;
            axi_read(base + 8,  w); v[63:32]  = w;
            axi_read(base + 12, w); v[31:0]   = w;
        end
    endtask

    task poll_core;
        input integer core;
        input integer bit_idx;
        input         value;
        reg   [31:0]  st;
        integer       n;
        begin
            n = 0;
            axi_read(core_addr(core, C_STATUS), st);
            while (st[bit_idx] !== value && n < POLL_LIMIT) begin
                axi_read(core_addr(core, C_STATUS), st);
                n = n + 1;
            end
            if (n >= POLL_LIMIT) begin
                $display("%0t TIMEOUT: core %0d STATUS bit %0d never became %b", $time, core, bit_idx, value);
                errors = errors + 1;
            end
        end
    endtask

    // ----------------------------------------------------------
    // Batch storage (one message per core)
    // ----------------------------------------------------------
    reg [127:0] b_key   [0:K-1];
    reg [127:0] b_nonce [0:K-1];
    reg [127:0] b_tag   [0:K-1];
    integer     b_idx   [0:K-1];
    integer     b_adl   [0:K-1];
    integer     b_ptl   [0:K-1];
    reg [127:0] b_ad    [0:K-1][0:10];
    reg [127:0] b_in    [0:K-1][0:10];
    reg [127:0] b_exp   [0:K-1][0:10];

    integer fd, r, i, j, c, m, n_batch, max_ad, max_pt, n_ad, n_pt, len, msgs;
    reg [127:0] block, got;
    reg [7:0]   valid_ref;
    reg [31:0]  st, id;
    integer     cyc0, cyc1, total_cycles;
    reg [31:0]  cyc;

    function integer open_tv;
        input decrypt;
        integer f;
        begin
            if (!decrypt) begin
                f = $fopen("python_simulation/encrypt_tv.txt", "r");
                if (f == 0) f = $fopen("../../../../python_simulation/encrypt_tv.txt", "r");
            end else begin
                f = $fopen("python_simulation/decrypt_tv.txt", "r");
                if (f == 0) f = $fopen("../../../../python_simulation/decrypt_tv.txt", "r");
            end
            open_tv = f;
        end
    endfunction

    // Read one vector into batch slot c
    task read_vector;
        input integer slot;
        input         decrypt;
        begin
            r = $fscanf(fd, "%h\n", b_key[slot]);
            r = $fscanf(fd, "%h\n", b_nonce[slot]);
            r = $fscanf(fd, "%d\n", b_adl[slot]);
            for (j = 0; j < (b_adl[slot] / 16) + 1; j = j + 1) begin
                r = $fscanf(fd, "%h\n", block); b_ad[slot][j] = block;
            end
            r = $fscanf(fd, "%d\n", b_ptl[slot]);
            n_pt = (b_ptl[slot] / 16) + 1;
            if (!decrypt) begin
                for (j = 0; j < n_pt; j = j + 1) begin r = $fscanf(fd, "%h\n", block); b_in[slot][j]  = block; end
                for (j = 0; j < n_pt; j = j + 1) begin r = $fscanf(fd, "%h\n", block); b_exp[slot][j] = block; end
                r = $fscanf(fd, "%h\n", b_tag[slot]);
            end else begin
                for (j = 0; j < n_pt; j = j + 1) begin r = $fscanf(fd, "%h\n", block); b_in[slot][j]  = block; end
                r = $fscanf(fd, "%h\n", b_tag[slot]);
                for (j = 0; j < n_pt; j = j + 1) begin r = $fscanf(fd, "%h\n", block); b_exp[slot][j] = block; end
                r = $fscanf(fd, "%h\n", valid_ref);
            end
        end
    endtask

    // Run one batch of n_batch messages on cores 0..n_batch-1
    task run_batch;
        input decrypt;
        begin
            // 1. stage + start every core
            for (c = 0; c < n_batch; c = c + 1) begin
                write128(G_KEY,   b_key[c]);
                write128(G_NONCE, b_nonce[c]);
                axi_write(G_MODE, {30'd0, (b_adl[c] > 0), decrypt});
                axi_write(core_addr(c, C_CONTROL), 32'h2);
            end
            axi_read(G_STATUS, st);
            for (c = 0; c < n_batch; c = c + 1)
                if (!st[c] && !st[8 + c]) begin
                    $display("FAIL: GSTATUS after start: core %0d neither busy nor done (%h)", c, st);
                    errors = errors + 1;
                end

            // 2. AD blocks, interleaved over the cores
            max_ad = 0;
            for (c = 0; c < n_batch; c = c + 1) begin
                n_ad = (b_adl[c] > 0) ? (b_adl[c] / 16) + 1 : 0;
                if (n_ad > max_ad) max_ad = n_ad;
            end
            for (j = 0; j < max_ad; j = j + 1)
                for (c = 0; c < n_batch; c = c + 1) begin
                    n_ad = (b_adl[c] > 0) ? (b_adl[c] / 16) + 1 : 0;
                    if (j < n_ad) begin
                        len = (j == n_ad - 1) ? b_adl[c] - 16 * j : 16;
                        poll_core(c, ST_AD_PEND, 1'b0);
                        write128(core_addr(c, C_AD), b_ad[c][j]);
                        axi_write(core_addr(c, C_AD_CTRL), 32'h1 | ((j == n_ad - 1) << 1) | (len << 8));
                    end
                end

            // 3. PT / CT blocks, interleaved over the cores
            max_pt = 0;
            for (c = 0; c < n_batch; c = c + 1) begin
                n_pt = (b_ptl[c] / 16) + 1;
                if (n_pt > max_pt) max_pt = n_pt;
            end
            for (j = 0; j < max_pt; j = j + 1) begin
                for (c = 0; c < n_batch; c = c + 1) begin
                    n_pt = (b_ptl[c] / 16) + 1;
                    if (j < n_pt) begin
                        len = (j == n_pt - 1) ? b_ptl[c] - 16 * j : 16;
                        poll_core(c, ST_PT_PEND, 1'b0);
                        write128(core_addr(c, C_PT), b_in[c][j]);
                        axi_write(core_addr(c, C_PT_CTRL), 32'h1 | ((j == n_pt - 1) << 1) | (len << 8));
                    end
                end
                for (c = 0; c < n_batch; c = c + 1) begin
                    n_pt = (b_ptl[c] / 16) + 1;
                    if (j < n_pt) begin
                        poll_core(c, ST_OUT_VALID, 1'b1);
                        read128(core_addr(c, C_OUT), got);
                        if (got !== b_exp[c][j]) begin
                            $display("%s %0d (core %0d) FAIL: block %0d expected %h, got %h",
                                     decrypt ? "DEC" : "ENC", b_idx[c], c, j, b_exp[c][j], got);
                            errors = errors + 1;
                        end
                    end
                end
            end

            // 4. tags
            for (c = 0; c < n_batch; c = c + 1) begin
                poll_core(c, ST_TAG_VALID, 1'b1);
                read128(core_addr(c, C_TAG), got);
                if (got !== b_tag[c]) begin
                    $display("%s %0d (core %0d) FAIL: tag expected %h, got %h",
                             decrypt ? "DEC" : "ENC", b_idx[c], c, b_tag[c], got);
                    errors = errors + 1;
                end
            end
            msgs = msgs + n_batch;
        end
    endtask

    initial begin
        msgs = 0;
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (5) @(posedge clk);

        axi_read(G_ID, id);
        if (id !== {16'hA5C0, 8'd0, K[7:0]}) begin
            $display("FAIL: ID = %h, expected %h", id, {16'hA5C0, 8'd0, K[7:0]});
            errors = errors + 1;
        end

        axi_read(12'h0e0, cyc); cyc0 = cyc;
        for (m = 0; m < 2; m = m + 1) begin
            fd = open_tv(m);
            if (fd == 0) begin
                $display("Error opening %s_tv.txt", m ? "decrypt" : "encrypt");
                $finish;
            end
            i = 0;
            while (i < N_TESTS) begin
                n_batch = (N_TESTS - i < K) ? N_TESTS - i : K;
                for (c = 0; c < n_batch; c = c + 1) begin
                    b_idx[c] = i + c;
                    read_vector(c, m[0]);
                end
                run_batch(m[0]);
                i = i + n_batch;
            end
            $fclose(fd);
        end
        axi_read(12'h0e0, cyc); cyc1 = cyc;
        total_cycles = cyc1 - cyc0;

        $display("\n================================================================");
        $display("AXI MULTI (K=%0d): %0d messages, %0d errors, %0d AXI protocol errors, %0d cycles (%0d per message incl. AXI)",
                 K, msgs, errors, proto_errs, total_cycles, total_cycles / msgs);
        if (errors == 0 && proto_errs == 0) $display("ALL AXI MULTI TESTS PASSED");
        else                                $display("%0d AXI MULTI TESTS FAILED", errors + proto_errs);
        $display("================================================================\n");
        $finish;
    end

endmodule
