`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 10/12/2026 02:48:29 PM
// Design Name:
// Module Name: tb_ascon_aead_axi
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
// Testbench for ascon_aead_axi through its AXI4-Lite interface.
//  - Runs all encrypt_tv.txt and decrypt_tv.txt vectors back to back,
//    driving the registers the way software would.
//  - Even messages poll ad_ready / pt_ready before each block ("polled");
//    odd messages write AD_CTRL / PT_CTRL without waiting for the core
//    ("fast"), relying on the held valid.
//  - Checks STATUS right after every start (busy = 1, tag_valid = 0).
//  - Strict AXI master + protocol monitor: BVALID / RVALID must come
//    after the AW+W / AR handshake.
//
// Dependencies: ascon_aead_axi
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module tb_ascon_aead_axi(

    );

    // ----------------------------------------------------------
    // Register map / STATUS bits (see ascon_aead_axi)
    // ----------------------------------------------------------
    localparam [11:0] ADDR_CONTROL  = 12'h000;
    localparam [11:0] ADDR_MODE     = 12'h004;
    localparam [11:0] ADDR_STATUS   = 12'h008;
    localparam [11:0] ADDR_KEY      = 12'h010;
    localparam [11:0] ADDR_NONCE    = 12'h020;
    localparam [11:0] ADDR_AD       = 12'h040;
    localparam [11:0] ADDR_AD_CTRL  = 12'h050;
    localparam [11:0] ADDR_PT       = 12'h060;
    localparam [11:0] ADDR_PT_CTRL  = 12'h070;
    localparam [11:0] ADDR_OUT      = 12'h080;
    localparam [11:0] ADDR_TAG      = 12'h0a0;
    localparam [11:0] ADDR_CYCLE_LO = 12'h0e0;

    localparam ST_AD_READY  = 0;
    localparam ST_PT_READY  = 1;
    localparam ST_OUT_VALID = 2;
    localparam ST_TAG_VALID = 3;
    localparam ST_BUSY      = 4;
    localparam ST_AD_PEND   = 5;
    localparam ST_PT_PEND   = 6;

    localparam N_TESTS      = 100;  // vectors per file
    localparam POLL_LIMIT   = 1000;

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

    ascon_aead_axi dut (
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
    // AXI protocol monitor
    // ----------------------------------------------------------
    reg w_hs_done = 0;   // AW+W handshake seen, B not yet completed
    reg r_hs_done = 0;   // AR handshake seen, R not yet completed

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
            if (bvalid && bresp != 2'b00) begin
                $display("%0t AXI ERROR: BRESP = %b", $time, bresp);
                proto_errs = proto_errs + 1;
            end
        end
        if (awvalid && awready && wvalid && wready) w_hs_done <= 1'b1;
        else if (bvalid && bready)                  w_hs_done <= 1'b0;
        if (arvalid && arready)                     r_hs_done <= 1'b1;
        else if (rvalid && rready)                  r_hs_done <= 1'b0;
    end

    // ----------------------------------------------------------
    // Strict AXI4-Lite master: request handshake first, then response
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

    // Poll STATUS until bit == value
    task poll_status;
        input integer bit_idx;
        input         value;
        reg   [31:0]  st;
        integer       n;
        begin
            n = 0;
            axi_read(ADDR_STATUS, st);
            while (st[bit_idx] !== value && n < POLL_LIMIT) begin
                axi_read(ADDR_STATUS, st);
                n = n + 1;
            end
            if (n >= POLL_LIMIT) begin
                $display("%0t TIMEOUT: STATUS bit %0d never became %b (STATUS=%b)", $time, bit_idx, value, st[6:0]);
                errors = errors + 1;
            end
        end
    endtask

    // ----------------------------------------------------------
    // One AEAD message
    // ----------------------------------------------------------
    reg [127:0] key, nonce, tag_exp, got;
    reg [127:0] ad_blk  [0:10];
    reg [127:0] in_blk  [0:10];
    reg [127:0] exp_blk [0:10];
    reg [7:0]   valid_ref;
    reg [31:0]  st;
    integer     ad_len, pt_len, n_ad, n_pt;
    integer     c_start, c_end;
    reg [31:0]  cyc;

    task run_message;
        input integer idx;
        input         decrypt;
        input         fast;
        integer       j, len;
        begin
            write128(ADDR_KEY,   key);
            write128(ADDR_NONCE, nonce);
            axi_write(ADDR_MODE, {30'd0, (ad_len > 0), decrypt});

            poll_status(ST_BUSY, 1'b0);
            axi_write(ADDR_CONTROL, 32'h2);                      // start
            axi_read(ADDR_CYCLE_LO, cyc); c_start = cyc;

            // Right after start: busy, no (stale) tag
            axi_read(ADDR_STATUS, st);
            if (!st[ST_BUSY] || st[ST_TAG_VALID]) begin
                $display("%s %0d FAIL: STATUS after start = %b (busy=%b tag_valid=%b)",
                         decrypt ? "DEC" : "ENC", idx, st[6:0], st[ST_BUSY], st[ST_TAG_VALID]);
                errors = errors + 1;
            end

            // AD blocks
            for (j = 0; j < n_ad; j = j + 1) begin
                len = (j == n_ad - 1) ? ad_len - 16 * j : 16;
                poll_status(ST_AD_PEND, 1'b0);                   // data register free
                if (!fast) poll_status(ST_AD_READY, 1'b1);
                write128(ADDR_AD, ad_blk[j]);
                axi_write(ADDR_AD_CTRL, 32'h1 | ((j == n_ad - 1) << 1) | (len << 8));
            end

            // PT / CT blocks
            for (j = 0; j < n_pt; j = j + 1) begin
                len = (j == n_pt - 1) ? pt_len - 16 * j : 16;
                poll_status(ST_PT_PEND, 1'b0);
                if (!fast) poll_status(ST_PT_READY, 1'b1);
                write128(ADDR_PT, in_blk[j]);
                axi_write(ADDR_PT_CTRL, 32'h1 | ((j == n_pt - 1) << 1) | (len << 8));
                poll_status(ST_OUT_VALID, 1'b1);
                read128(ADDR_OUT, got);
                if (got !== exp_blk[j]) begin
                    $display("%s %0d FAIL: %s block %0d expected %h, got %h",
                             decrypt ? "DEC" : "ENC", idx, decrypt ? "PT" : "CT", j, exp_blk[j], got);
                    errors = errors + 1;
                end
            end

            // Tag
            poll_status(ST_TAG_VALID, 1'b1);
            axi_read(ADDR_CYCLE_LO, cyc); c_end = cyc;
            read128(ADDR_TAG, got);
            if (got !== tag_exp) begin
                $display("%s %0d FAIL: tag expected %h, got %h", decrypt ? "DEC" : "ENC", idx, tag_exp, got);
                errors = errors + 1;
            end

            if (idx % 10 == 0)
                $display("%s %0d (%s): ad_len=%0d len=%0d  %0d cycles start->tag incl. AXI",
                         decrypt ? "DEC" : "ENC", idx, fast ? "fast" : "polled",
                         ad_len, pt_len, c_end - c_start);
        end
    endtask

    // ----------------------------------------------------------
    // Vector files (same format as tb_encypt / tb_decrypt)
    // ----------------------------------------------------------
    integer fd, r, i, j, m;
    reg [127:0] block;

    function integer open_tv;
        input decrypt;
        integer f;
        begin
            // Project root (regression scripts) or Vivado GUI run dir
            // (ascon_aead.sim/sim_1/behav/xsim)
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

    initial begin
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (5) @(posedge clk);

        for (m = 0; m < 2; m = m + 1) begin
            fd = open_tv(m);
            if (fd == 0) begin
                $display("Error opening %s_tv.txt", m ? "decrypt" : "encrypt");
                $finish;
            end

            for (i = 0; i < N_TESTS; i = i + 1) begin
                r = $fscanf(fd, "%h\n", key);
                r = $fscanf(fd, "%h\n", nonce);
                r = $fscanf(fd, "%d\n", ad_len);
                n_ad = (ad_len > 0) ? (ad_len / 16) + 1 : 0;
                for (j = 0; j < (ad_len / 16) + 1; j = j + 1) begin
                    r = $fscanf(fd, "%h\n", block);
                    ad_blk[j] = block;
                end

                r = $fscanf(fd, "%d\n", pt_len);
                n_pt = (pt_len / 16) + 1;
                if (!m) begin
                    // encrypt: PT blocks, CT blocks, tag
                    for (j = 0; j < n_pt; j = j + 1) begin r = $fscanf(fd, "%h\n", block); in_blk[j]  = block; end
                    for (j = 0; j < n_pt; j = j + 1) begin r = $fscanf(fd, "%h\n", block); exp_blk[j] = block; end
                    r = $fscanf(fd, "%h\n", tag_exp);
                end else begin
                    // decrypt: CT blocks, tag, PT blocks, valid flag
                    for (j = 0; j < n_pt; j = j + 1) begin r = $fscanf(fd, "%h\n", block); in_blk[j]  = block; end
                    r = $fscanf(fd, "%h\n", tag_exp);
                    for (j = 0; j < n_pt; j = j + 1) begin r = $fscanf(fd, "%h\n", block); exp_blk[j] = block; end
                    r = $fscanf(fd, "%h\n", valid_ref);
                end

                run_message(i, m[0], i[0]);
            end
            $fclose(fd);
        end

        $display("\n================================================================");
        $display("AXI REGRESSION: %0d messages, %0d errors, %0d AXI protocol errors",
                 2 * N_TESTS, errors, proto_errs);
        if (errors == 0 && proto_errs == 0) $display("ALL AXI TESTS PASSED");
        else                                $display("%0d AXI TESTS FAILED", errors + proto_errs);
        $display("================================================================\n");
        $finish;
    end

endmodule
