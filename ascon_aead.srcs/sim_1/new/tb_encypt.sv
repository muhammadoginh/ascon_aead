`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/12/2026 01:34:55 PM
// Design Name: 
// Module Name: tb_encypt
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module tb_encypt();
    reg clk;
    reg rst;

    reg [127:0] key;
    reg [127:0] nonce;
    reg mode;
    reg start;
    reg has_ad;

    reg ad_valid;
    reg [127:0] ad_data;
    reg ad_last;
    reg [4:0] ad_len;
    wire ad_ready;

    reg pt_valid;
    reg [127:0] pt_data;
    reg pt_last;
    reg [4:0] pt_len;
    wire pt_ready;

    wire out_valid;
    wire [127:0] out_data;
    wire out_last;
    wire [4:0] out_len;
    reg out_ready;

    wire tag_valid;
    wire [127:0] tag;
    wire tag_fail;

    ascon_aead dut (
        .clk(clk),
        .rst(rst),
        .key(key),
        .nonce(nonce),
        .mode(mode),
        .start(start),
        .has_ad(has_ad),
        .ad_valid(ad_valid),
        .ad_data(ad_data),
        .ad_last(ad_last),
        .ad_len(ad_len),
        .ad_ready(ad_ready),
        .pt_valid(pt_valid),
        .pt_data(pt_data),
        .pt_last(pt_last),
        .pt_len(pt_len),
        .pt_ready(pt_ready),
        .out_valid(out_valid),
        .out_data(out_data),
        .out_last(out_last),
        .out_len(out_len),
        .out_ready(out_ready),
        .tag_valid(tag_valid),
        .tag(tag),
        .tag_fail(tag_fail)
    );

    always #5 clk = ~clk;

    // Helper task: drive AD block when FSM is ready.
    task send_ad_block;
        input [127:0] data;
        input         last;
        input [4:0]   len;
        begin
            @(posedge clk);
            while (!ad_ready) @(posedge clk);
            @(negedge clk);
            ad_valid = 1;
            ad_data  = data;
            ad_last  = last;
            ad_len   = len;
            @(posedge clk);
            @(negedge clk);
            ad_valid = 0;
            ad_last  = 0;
        end
    endtask

    // Helper task: drive PT block and capture CT output.
    task send_pt_block;
        input  [127:0] data;
        input          last;
        input  [4:0]   len;
        output [127:0] captured_ct;
        begin
            @(posedge clk);
            while (!pt_ready) @(posedge clk);
            @(negedge clk);
            pt_valid = 1;
            pt_data  = data;
            pt_last  = last;
            pt_len   = len;
            // FSM samples pt and drives out_valid/out_data combinatorially
            @(posedge clk);
            captured_ct = out_data;
            @(negedge clk);
            pt_valid = 0;
            pt_last  = 0;
        end
    endtask

    // ----------------------------------------------------------
    // Latency monitor (clock cycles)
    // Passive: watches DUT handshakes at every posedge clk.
    // Latency = number of clock edges from the edge that accepts
    // an input to the first edge at which the DUT is ready again
    // (or tag_valid is high).
    // ----------------------------------------------------------
    localparam LAT_INIT       = 0;  // start      -> ad_ready / pt_ready
    localparam LAT_AD         = 1;  // AD block   -> ad_ready (non-last)
    localparam LAT_AD_LAST_P  = 2;  // AD last, partial -> pt_ready
    localparam LAT_AD_LAST_F  = 3;  // AD last, full    -> pt_ready
    localparam LAT_PT         = 4;  // PT/CT block -> pt_ready (non-last)
    localparam LAT_FINAL_P    = 5;  // PT/CT last, partial -> tag_valid
    localparam LAT_FINAL_F    = 6;  // PT/CT last, full    -> tag_valid
    localparam LAT_TOTAL      = 7;  // start      -> tag_valid (incl. TB idle cycles)
    localparam LAT_N          = 8;

    integer cycle;
    integer lat_min [0:LAT_N-1];
    integer lat_max [0:LAT_N-1];
    integer lat_sum [0:LAT_N-1];
    integer lat_cnt [0:LAT_N-1];

    integer t_start, t_req;
    integer req_cat;          // category waiting for ready, -1 = none
    reg     wait_tag;
    integer k;
    integer cur_dut;          // DUT busy cycles of current test
    integer last_dut;         // DUT cycles of last completed test
    integer last_total;       // start -> tag of last completed test

    task lat_add;
        input integer cat;
        input integer val;
        begin
            if (lat_cnt[cat] == 0 || val < lat_min[cat]) lat_min[cat] = val;
            if (lat_cnt[cat] == 0 || val > lat_max[cat]) lat_max[cat] = val;
            lat_sum[cat] = lat_sum[cat] + val;
            lat_cnt[cat] = lat_cnt[cat] + 1;
            if (cat != LAT_TOTAL) cur_dut = cur_dut + val;
        end
    endtask

    initial begin
        cycle    = 0;
        req_cat  = -1;
        wait_tag = 0;
        cur_dut  = 0;
        last_dut = 0;
        last_total = 0;
        for (k = 0; k < LAT_N; k = k + 1) begin
            lat_min[k] = 0; lat_max[k] = 0; lat_sum[k] = 0; lat_cnt[k] = 0;
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            cycle = cycle + 1;

            // Completion of a pending request (checked before new requests)
            if (req_cat >= 0) begin
                if ((req_cat == LAT_AD && ad_ready) ||
                    (req_cat != LAT_AD && req_cat != LAT_FINAL_P &&
                     req_cat != LAT_FINAL_F && (ad_ready || pt_ready))) begin
                    lat_add(req_cat, cycle - t_req);
                    req_cat = -1;
                end else if ((req_cat == LAT_FINAL_P || req_cat == LAT_FINAL_F) && tag_valid) begin
                    lat_add(req_cat, cycle - t_req);
                    req_cat = -1;
                end
            end
            if (wait_tag && tag_valid) begin
                lat_add(LAT_TOTAL, cycle - t_start);
                last_total = cycle - t_start;
                last_dut   = cur_dut;
                wait_tag = 0;
            end

            // New requests accepted at this edge
            if (start) begin
                t_start  = cycle;
                cur_dut  = 0;
                t_req    = cycle;
                req_cat  = LAT_INIT;
                wait_tag = 1;
            end else if (ad_valid && ad_ready) begin
                t_req   = cycle;
                req_cat = !ad_last ? LAT_AD : (ad_len == 16) ? LAT_AD_LAST_F : LAT_AD_LAST_P;
            end else if (pt_valid && pt_ready) begin
                t_req   = cycle;
                req_cat = !pt_last ? LAT_PT : (pt_len == 16) ? LAT_FINAL_F : LAT_FINAL_P;
            end
        end
    end

    task lat_print_one;
        input integer cat;
        input [8*40-1:0] name;
        begin
            if (lat_cnt[cat] > 0)
                $display("  %0s %6d %6d %8.2f %6d", name, lat_min[cat], lat_max[cat],
                         lat_sum[cat] * 1.0 / lat_cnt[cat], lat_cnt[cat]);
            else
                $display("  %0s %6s %6s %8s %6d", name, "-", "-", "-", 0);
        end
    endtask

    task lat_print;
        begin
            $display("\n================================================================");
            $display("LATENCY (clock cycles)");
            $display("================================================================");
            $display("  %-40s %6s %6s %8s %6s", "", "min", "max", "avg", "count");
            lat_print_one(LAT_INIT,      "init        : start -> ready           ");
            lat_print_one(LAT_AD,        "AD block    : accept -> ad_ready       ");
            lat_print_one(LAT_AD_LAST_P, "AD last (partial) : accept -> pt_ready ");
            lat_print_one(LAT_AD_LAST_F, "AD last (full)    : accept -> pt_ready ");
            lat_print_one(LAT_PT,        "PT block    : accept -> pt_ready       ");
            lat_print_one(LAT_FINAL_P,   "PT last (partial) : accept -> tag      ");
            lat_print_one(LAT_FINAL_F,   "PT last (full)    : accept -> tag      ");
            lat_print_one(LAT_TOTAL,     "total       : start -> tag (incl. TB)  ");
            $display("================================================================\n");
        end
    endtask

    integer fd;
    integer r;
    integer my_ad_len, my_pt_len;
    reg [127:0] block;
    reg [127:0] pt_blocks  [0:10];
    reg [127:0] ct_blocks  [0:10];
    reg [127:0] hw_ct_blocks [0:10];
    reg [127:0] expected_tag;
    reg [127:0] captured_ct;
    integer errors;
    integer i, j, blocks;
    integer n_ad_blk, n_pt_blk, exp_cc, cc_err, fd_cc;

    initial begin
        clk      = 0;
        rst      = 1;
        errors   = 0;
        start    = 0;
        mode     = 0; // Encrypt
        has_ad   = 0;
        ad_valid = 0;
        ad_data  = 0;
        ad_last  = 0;
        ad_len   = 0;
        pt_valid = 0;
        pt_data  = 0;
        pt_last  = 0;
        pt_len   = 0;
        out_ready = 1;

        #20;
        rst = 0;

        // Project root (regression scripts) or Vivado GUI run dir
        // (ascon_aead.sim/sim_1/behav/xsim)
        fd = $fopen("python_simulation/encrypt_tv.txt", "r");
        if (fd == 0)
            fd = $fopen("../../../../python_simulation/encrypt_tv.txt", "r");
        if (fd == 0) begin
            $display("Error opening encrypt_tv.txt");
            $finish;
        end

        cc_err = 0;
        fd_cc  = $fopen("latency_encrypt.csv", "w");
        $fdisplay(fd_cc, "test,ad_len,pt_len,ad_blocks,pt_blocks,dut_cc,expected_cc,total_cc");
        $display("\nPER-TEST LATENCY (clock cycles)");
        $display("  dut_cc   = start -> tag_valid, DUT only (TB idle cycles removed)");
        $display("  total_cc = start -> tag_valid, as measured with this TB");
        $display("  %4s %6s %6s %6s %6s %7s %7s %8s", "test", "ad_len", "pt_len", "ad_blk", "pt_blk", "dut_cc", "exp_cc", "total_cc");

        for (i = 0; i < 100; i = i + 1) begin
            r = $fscanf(fd, "%h\n", key);
            r = $fscanf(fd, "%h\n", nonce);
            r = $fscanf(fd, "%d\n", my_ad_len);

            has_ad = (my_ad_len > 0);

            // Pulse start for one cycle
            @(negedge clk);
            start = 1;
            @(posedge clk);
            @(negedge clk);
            start = 0;

            // Send AD blocks
            blocks = (my_ad_len / 16) + 1;
            for (j = 0; j < blocks; j = j + 1) begin
                r = $fscanf(fd, "%h\n", block);
                if (my_ad_len > 0) begin
                    if (j == blocks - 1)
                        send_ad_block(block, 1, my_ad_len - (j * 16));
                    else
                        send_ad_block(block, 0, 16);
                end
            end

            // Read PT/CT vectors
            r = $fscanf(fd, "%d\n", my_pt_len);
            blocks = (my_pt_len / 16) + 1;

            for (j = 0; j < blocks; j = j + 1) begin
                r = $fscanf(fd, "%h\n", block);
                pt_blocks[j] = block;
            end
            for (j = 0; j < blocks; j = j + 1) begin
                r = $fscanf(fd, "%h\n", block);
                ct_blocks[j] = block;
            end
            r = $fscanf(fd, "%h\n", expected_tag);

            // Drive PT blocks and check CT output
            for (j = 0; j < blocks; j = j + 1) begin
                if (j == blocks - 1)
                    send_pt_block(pt_blocks[j], 1, my_pt_len - (j * 16), captured_ct);
                else
                    send_pt_block(pt_blocks[j], 0, 16, captured_ct);

                hw_ct_blocks[j] = captured_ct;

                if (captured_ct !== ct_blocks[j]) begin
                    $display("Test %0d FAIL: CT block %0d expected %h, got %h", i, j, ct_blocks[j], captured_ct);
                    errors = errors + 1;
                end
            end

            // Wait for tag (perm12 finalization = 12 cycles; generous timeout guard)
            wait(tag_valid);

            if (i == 0) begin
                $display("\n================================================================");
                $display("TEST 0: ENCRYPTION RESULTS COMPARISON");
                $display("================================================================");
                $display("Inputs:");
                $display("  Key:    %h", key);
                $display("  Nonce:  %h", nonce);
                $display("  AD Len: %0d", my_ad_len);
                $display("  PT Len: %0d", my_pt_len);
                $display("\nGolden Model (Python Reference):");
                for (j = 0; j < blocks; j = j + 1) begin
                    $display("  CT Block %0d: %h", j, ct_blocks[j]);
                end
                $display("  Tag:        %h", expected_tag);
                $display("\nCalculated HW (Verilog Simulation):");
                for (j = 0; j < blocks; j = j + 1) begin
                    $display("  CT Block %0d: %h", j, hw_ct_blocks[j]);
                end
                $display("  Tag:        %h", tag);
                $display("================================================================\n");
            end

            if (tag !== expected_tag) begin
                $display("Test %0d FAIL: Tag expected %h, got %h", i, expected_tag, tag);
                errors = errors + 1;
            end else begin
                if (i % 10 == 0) $display("Test %0d passed", i);
            end

            // Allow FSM to settle before next test (accounts for perm12 latency)
            repeat(15) @(posedge clk);

            // Per-test latency: 14 (init) + 9 per block except the last
            // + 1 (AD domain sep, only with AD) + 14 (final)
            n_ad_blk = (my_ad_len > 0) ? (my_ad_len / 16) + 1 : 0;
            n_pt_blk = (my_pt_len / 16) + 1;
            exp_cc   = 14 + 9 * (n_ad_blk + n_pt_blk - 1) + ((n_ad_blk > 0) ? 1 : 0) + 14;
            $display("  %4d %6d %6d %6d %6d %7d %7d %8d%s", i, my_ad_len, my_pt_len,
                     n_ad_blk, n_pt_blk, last_dut, exp_cc, last_total,
                     (last_dut != exp_cc) ? "  <-- MISMATCH" : "");
            $fdisplay(fd_cc, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d", i, my_ad_len, my_pt_len,
                      n_ad_blk, n_pt_blk, last_dut, exp_cc, last_total);
            if (last_dut != exp_cc) cc_err = cc_err + 1;
        end

        $fclose(fd_cc);
        if (cc_err != 0) $display("WARNING: %0d tests with dut_cc != expected", cc_err);
        lat_print;

        if (errors == 0) $display("ALL ENCRYPTION TESTS PASSED");
        else $display("%0d ENCRYPTION TESTS FAILED", errors);

        $fclose(fd);
        $finish;
    end
endmodule
