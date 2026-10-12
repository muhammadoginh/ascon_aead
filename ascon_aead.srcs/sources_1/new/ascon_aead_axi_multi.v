`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 10/12/2026 05:00:00 PM
// Design Name:
// Module Name: ascon_aead_axi_multi
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
// ascon_aead_axi_multi: K ascon_aead cores behind one AXI4-Lite slave, for
// a gateway serving many C2 / telemetry links in parallel.
//
// Address map (12-bit):
//   Global page 0x000..0x0FF
//     0x000 CONTROL  W: bit0 reset all cores
//     0x004 MODE     RW: bit0 mode (0 enc, 1 dec), bit1 has_ad   (staging)
//     0x008 GSTATUS  R: [7:0] busy, [15:8] tag_valid, [23:16] out_valid,
//                       [31:24] pending (ad_pending | pt_pending), bit i = core i
//     0x00C ID       R: {16'hA5C0, 8'd0, K}
//     0x010..0x01C KEY   [127:96] .. [31:0]                      (staging)
//     0x020..0x02C NONCE [127:96] .. [31:0]                      (staging)
//     0x0E0 / 0x0E4  CYCLE_LO / CYCLE_HI
//   Core i page at 0x100 * (i + 1), same offsets as ascon_aead_axi:
//     +0x000 CONTROL  W: bit1 start (core latches the staged KEY / NONCE / MODE)
//     +0x008 STATUS   R: [0] ad_ready [1] pt_ready [2] out_valid [3] tag_valid
//                        [4] busy [5] ad_pending [6] pt_pending
//     +0x040..0x04C AD, +0x050 AD_CTRL (bit0 valid, bit1 last, [12:8] len)
//     +0x060..0x06C PT, +0x070 PT_CTRL (bit0 valid, bit1 last, [12:8] len)
//     +0x080..0x08C OUT, +0x090 OUT_CTRL ([0] valid, [1] last, [12:8] len)
//     +0x0A0..0x0AC TAG
//
// A core copies key / mode at start and uses the nonce only in its load
// cycle, so one staging set serves all cores: write KEY / NONCE / MODE,
// then start core i; then stage the next link's values for core j.
// AD / PT valid is held until the core accepts the block (see
// ascon_aead_axi). Reads take two cycles (registered read mux).
//
// Dependencies: ascon_aead
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// K = 1..15, C_S_AXI_ADDR_WIDTH must be >= 12.
//
//////////////////////////////////////////////////////////////////////////////////


module ascon_aead_axi_multi #(
        parameter integer K                  = 4,
        parameter integer C_S_AXI_DATA_WIDTH = 32,
        parameter integer C_S_AXI_ADDR_WIDTH = 12
    )(
        input  wire                                  s_axi_aclk,
        input  wire                                  s_axi_aresetn,

        input  wire [C_S_AXI_ADDR_WIDTH-1:0]         s_axi_awaddr,
        input  wire [2:0]                            s_axi_awprot,
        input  wire                                  s_axi_awvalid,
        output reg                                   s_axi_awready,

        input  wire [C_S_AXI_DATA_WIDTH-1:0]         s_axi_wdata,
        input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]     s_axi_wstrb,
        input  wire                                  s_axi_wvalid,
        output reg                                   s_axi_wready,

        output reg  [1:0]                            s_axi_bresp,
        output reg                                   s_axi_bvalid,
        input  wire                                  s_axi_bready,

        input  wire [C_S_AXI_ADDR_WIDTH-1:0]         s_axi_araddr,
        input  wire [2:0]                            s_axi_arprot,
        input  wire                                  s_axi_arvalid,
        output reg                                   s_axi_arready,

        output reg  [C_S_AXI_DATA_WIDTH-1:0]         s_axi_rdata,
        output reg  [1:0]                            s_axi_rresp,
        output reg                                   s_axi_rvalid,
        input  wire                                  s_axi_rready
    );

    // ----------------------------------------------------------
    // Register offsets
    // ----------------------------------------------------------
    // Global page
    localparam [7:0] G_CONTROL     = 8'h00;
    localparam [7:0] G_MODE        = 8'h04;
    localparam [7:0] G_STATUS      = 8'h08;
    localparam [7:0] G_ID          = 8'h0c;
    localparam [7:0] G_KEY_127_96  = 8'h10;
    localparam [7:0] G_KEY_95_64   = 8'h14;
    localparam [7:0] G_KEY_63_32   = 8'h18;
    localparam [7:0] G_KEY_31_0    = 8'h1c;
    localparam [7:0] G_NONCE_127_96 = 8'h20;
    localparam [7:0] G_NONCE_95_64 = 8'h24;
    localparam [7:0] G_NONCE_63_32 = 8'h28;
    localparam [7:0] G_NONCE_31_0  = 8'h2c;
    localparam [7:0] G_CYCLE_LO    = 8'he0;
    localparam [7:0] G_CYCLE_HI    = 8'he4;

    // Core page
    localparam [7:0] C_CONTROL     = 8'h00;
    localparam [7:0] C_STATUS      = 8'h08;
    localparam [7:0] C_AD_127_96   = 8'h40;
    localparam [7:0] C_AD_95_64    = 8'h44;
    localparam [7:0] C_AD_63_32    = 8'h48;
    localparam [7:0] C_AD_31_0     = 8'h4c;
    localparam [7:0] C_AD_CTRL     = 8'h50;
    localparam [7:0] C_PT_127_96   = 8'h60;
    localparam [7:0] C_PT_95_64    = 8'h64;
    localparam [7:0] C_PT_63_32    = 8'h68;
    localparam [7:0] C_PT_31_0     = 8'h6c;
    localparam [7:0] C_PT_CTRL     = 8'h70;
    localparam [7:0] C_OUT_127_96  = 8'h80;
    localparam [7:0] C_OUT_95_64   = 8'h84;
    localparam [7:0] C_OUT_63_32   = 8'h88;
    localparam [7:0] C_OUT_31_0    = 8'h8c;
    localparam [7:0] C_OUT_CTRL    = 8'h90;
    localparam [7:0] C_TAG_127_96  = 8'ha0;
    localparam [7:0] C_TAG_95_64   = 8'ha4;
    localparam [7:0] C_TAG_63_32   = 8'ha8;
    localparam [7:0] C_TAG_31_0    = 8'hac;

    // ----------------------------------------------------------
    // AXI4-Lite handshake
    // Write: ready pulse, access on the handshake, BVALID next cycle.
    // Read : handshake -> address registered -> data mux registered ->
    //        RVALID (two cycles after the handshake).
    // ----------------------------------------------------------
    wire wr_en = s_axi_awvalid && s_axi_awready && s_axi_wvalid && s_axi_wready;
    wire rd_en = s_axi_arvalid && s_axi_arready;

    wire [3:0] wr_page = s_axi_awaddr[11:8];
    wire [7:0] wr_off  = s_axi_awaddr[7:0];
    wire       wr_glob = (wr_page == 4'd0);

    reg        rd_busy;            // read accepted, data not yet returned
    reg        rd_stage;           // address registered, mux this cycle
    reg [3:0]  rd_page_q;
    reg [7:0]  rd_off_q;

    // Apply WSTRB byte enables to a 32-bit register
    function [31:0] wmask;
        input [31:0] old;
        input [31:0] wdat;
        input [3:0]  strb;
        integer b;
        begin
            for (b = 0; b < 4; b = b + 1)
                wmask[b*8 +: 8] = strb[b] ? wdat[b*8 +: 8] : old[b*8 +: 8];
        end
    endfunction

    // ----------------------------------------------------------
    // Global registers
    // ----------------------------------------------------------
    reg [127:0] key_reg;
    reg [127:0] nonce_reg;
    reg         mode_reg;
    reg         has_ad_reg;
    reg [63:0]  cycle_counter;
    reg         aead_rst;          // registered reset for all cores

    // ----------------------------------------------------------
    // Per-core registers
    // ----------------------------------------------------------
    reg [127:0] ad_data_reg  [0:K-1];
    reg         ad_last_reg  [0:K-1];
    reg [4:0]   ad_len_reg   [0:K-1];
    reg [127:0] pt_data_reg  [0:K-1];
    reg         pt_last_reg  [0:K-1];
    reg [4:0]   pt_len_reg   [0:K-1];
    reg [127:0] out_data_r   [0:K-1];
    reg         out_last_r   [0:K-1];
    reg [4:0]   out_len_r    [0:K-1];
    reg [127:0] tag_r        [0:K-1];

    reg [K-1:0] ad_valid_reg;
    reg [K-1:0] pt_valid_reg;
    reg [K-1:0] start_pulse;
    reg [K-1:0] busy;
    reg [K-1:0] out_valid_r;
    reg [K-1:0] tag_valid_r;

    wire [K-1:0]   core_ad_ready;
    wire [K-1:0]   core_pt_ready;
    wire [K-1:0]   core_out_valid;
    wire [K-1:0]   core_out_last;
    wire [K-1:0]   core_tag_valid;
    wire [128*K-1:0] core_out_data;
    wire [5*K-1:0]   core_out_len;
    wire [128*K-1:0] core_tag;

    // ----------------------------------------------------------
    // Cores
    // ----------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < K; gi = gi + 1) begin : g_core
            ascon_aead u_ascon_aead (
                .clk      (s_axi_aclk),
                .rst      (aead_rst),
                .key      (key_reg),
                .nonce    (nonce_reg),
                .mode     (mode_reg),
                .start    (start_pulse[gi]),
                .has_ad   (has_ad_reg),
                .ad_valid (ad_valid_reg[gi]),
                .ad_data  (ad_data_reg[gi]),
                .ad_last  (ad_last_reg[gi]),
                .ad_len   (ad_len_reg[gi]),
                .ad_ready (core_ad_ready[gi]),
                .pt_valid (pt_valid_reg[gi]),
                .pt_data  (pt_data_reg[gi]),
                .pt_last  (pt_last_reg[gi]),
                .pt_len   (pt_len_reg[gi]),
                .pt_ready (core_pt_ready[gi]),
                .out_valid(core_out_valid[gi]),
                .out_data (core_out_data[128*gi +: 128]),
                .out_last (core_out_last[gi]),
                .out_len  (core_out_len[5*gi +: 5]),
                .out_ready(1'b1),
                .tag_valid(core_tag_valid[gi]),
                .tag      (core_tag[128*gi +: 128]),
                .tag_fail ()
            );
        end
    endgenerate

    // Global status (bit i = core i, up to 8 cores per field)
    wire [7:0] g_busy, g_tag, g_out, g_pend;
    genvar gs;
    generate
        for (gs = 0; gs < 8; gs = gs + 1) begin : g_stat
            if (gs < K) begin : used
                assign g_busy[gs] = busy[gs];
                assign g_tag[gs]  = tag_valid_r[gs];
                assign g_out[gs]  = out_valid_r[gs];
                assign g_pend[gs] = ad_valid_reg[gs] | pt_valid_reg[gs];
            end else begin : unused
                assign g_busy[gs] = 1'b0;
                assign g_tag[gs]  = 1'b0;
                assign g_out[gs]  = 1'b0;
                assign g_pend[gs] = 1'b0;
            end
        end
    endgenerate

    // ----------------------------------------------------------
    // Core reset: AXI reset or global CONTROL bit0, from a flip-flop
    // ----------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        aead_rst <= !s_axi_aresetn ||
                    (wr_en && wr_glob && wr_off == G_CONTROL && s_axi_wstrb[0] && s_axi_wdata[0]);
    end

    // ----------------------------------------------------------
    // Main sequential block
    // ----------------------------------------------------------
    integer i;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            s_axi_bvalid  <= 1'b0;
            s_axi_arready <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
            s_axi_rvalid  <= 1'b0;
            rd_busy       <= 1'b0;
            rd_stage      <= 1'b0;
            rd_page_q     <= 4'd0;
            rd_off_q      <= 8'd0;

            key_reg       <= 128'd0;
            nonce_reg     <= 128'd0;
            mode_reg      <= 1'b0;
            has_ad_reg    <= 1'b0;
            cycle_counter <= 64'd0;

            ad_valid_reg  <= {K{1'b0}};
            pt_valid_reg  <= {K{1'b0}};
            start_pulse   <= {K{1'b0}};
            busy          <= {K{1'b0}};
            out_valid_r   <= {K{1'b0}};
            tag_valid_r   <= {K{1'b0}};
            for (i = 0; i < K; i = i + 1) begin
                ad_data_reg[i] <= 128'd0;
                ad_last_reg[i] <= 1'b0;
                ad_len_reg[i]  <= 5'd0;
                pt_data_reg[i] <= 128'd0;
                pt_last_reg[i] <= 1'b0;
                pt_len_reg[i]  <= 5'd0;
                out_data_r[i]  <= 128'd0;
                out_last_r[i]  <= 1'b0;
                out_len_r[i]   <= 5'd0;
                tag_r[i]       <= 128'd0;
            end
        end else begin
            cycle_counter <= cycle_counter + 64'd1;

            // ---- Write channel -----------------------------------
            s_axi_awready <= s_axi_awvalid && s_axi_wvalid && !s_axi_awready && !s_axi_bvalid;
            s_axi_wready  <= s_axi_awvalid && s_axi_wvalid && !s_axi_awready && !s_axi_bvalid;

            if (wr_en) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            // ---- Read channel (two-stage) ------------------------
            s_axi_arready <= s_axi_arvalid && !s_axi_arready && !rd_busy;
            rd_stage      <= 1'b0;

            if (rd_en) begin
                rd_busy   <= 1'b1;
                rd_stage  <= 1'b1;
                rd_page_q <= s_axi_araddr[11:8];
                rd_off_q  <= s_axi_araddr[7:0];
            end
            if (rd_stage) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
                rd_busy      <= 1'b0;
            end

            // ---- Core handshakes ---------------------------------
            start_pulse <= {K{1'b0}};
            for (i = 0; i < K; i = i + 1) begin
                if (ad_valid_reg[i] && core_ad_ready[i]) ad_valid_reg[i] <= 1'b0;
                if (pt_valid_reg[i] && core_pt_ready[i]) pt_valid_reg[i] <= 1'b0;

                if (core_out_valid[i]) begin
                    out_data_r[i]  <= core_out_data[128*i +: 128];
                    out_last_r[i]  <= core_out_last[i];
                    out_len_r[i]   <= core_out_len[5*i +: 5];
                    out_valid_r[i] <= 1'b1;
                end

                // Core keeps tag_valid high until it sees the next start;
                // do not latch while the start pulse is in flight.
                if (core_tag_valid[i] && busy[i] && !start_pulse[i]) begin
                    tag_r[i]       <= core_tag[128*i +: 128];
                    tag_valid_r[i] <= 1'b1;
                    busy[i]        <= 1'b0;
                end
            end

            // ---- Register writes ---------------------------------
            if (wr_en) begin
                if (wr_glob) begin
                    case (wr_off)
                        G_CONTROL: if (s_axi_wstrb[0] && s_axi_wdata[0]) begin
                            ad_valid_reg <= {K{1'b0}};
                            pt_valid_reg <= {K{1'b0}};
                            out_valid_r  <= {K{1'b0}};
                            tag_valid_r  <= {K{1'b0}};
                            busy         <= {K{1'b0}};
                        end
                        G_MODE: if (s_axi_wstrb[0]) begin
                            mode_reg   <= s_axi_wdata[0];
                            has_ad_reg <= s_axi_wdata[1];
                        end
                        G_KEY_127_96:   key_reg[127:96]   <= wmask(key_reg[127:96],   s_axi_wdata, s_axi_wstrb);
                        G_KEY_95_64:    key_reg[95:64]    <= wmask(key_reg[95:64],    s_axi_wdata, s_axi_wstrb);
                        G_KEY_63_32:    key_reg[63:32]    <= wmask(key_reg[63:32],    s_axi_wdata, s_axi_wstrb);
                        G_KEY_31_0:     key_reg[31:0]     <= wmask(key_reg[31:0],     s_axi_wdata, s_axi_wstrb);
                        G_NONCE_127_96: nonce_reg[127:96] <= wmask(nonce_reg[127:96], s_axi_wdata, s_axi_wstrb);
                        G_NONCE_95_64:  nonce_reg[95:64]  <= wmask(nonce_reg[95:64],  s_axi_wdata, s_axi_wstrb);
                        G_NONCE_63_32:  nonce_reg[63:32]  <= wmask(nonce_reg[63:32],  s_axi_wdata, s_axi_wstrb);
                        G_NONCE_31_0:   nonce_reg[31:0]   <= wmask(nonce_reg[31:0],   s_axi_wdata, s_axi_wstrb);
                        default: begin end
                    endcase
                end else begin
                    for (i = 0; i < K; i = i + 1) begin
                        if (wr_page == i + 1) begin
                            case (wr_off)
                                C_CONTROL: if (s_axi_wstrb[0] && s_axi_wdata[1]) begin
                                    start_pulse[i] <= 1'b1;
                                    out_valid_r[i] <= 1'b0;
                                    tag_valid_r[i] <= 1'b0;
                                    busy[i]        <= 1'b1;
                                end
                                C_AD_127_96: ad_data_reg[i][127:96] <= wmask(ad_data_reg[i][127:96], s_axi_wdata, s_axi_wstrb);
                                C_AD_95_64:  ad_data_reg[i][95:64]  <= wmask(ad_data_reg[i][95:64],  s_axi_wdata, s_axi_wstrb);
                                C_AD_63_32:  ad_data_reg[i][63:32]  <= wmask(ad_data_reg[i][63:32],  s_axi_wdata, s_axi_wstrb);
                                C_AD_31_0:   ad_data_reg[i][31:0]   <= wmask(ad_data_reg[i][31:0],   s_axi_wdata, s_axi_wstrb);
                                C_AD_CTRL: begin
                                    if (s_axi_wstrb[0]) begin
                                        ad_last_reg[i] <= s_axi_wdata[1];
                                        if (s_axi_wdata[0]) ad_valid_reg[i] <= 1'b1;
                                    end
                                    if (s_axi_wstrb[1]) ad_len_reg[i] <= s_axi_wdata[12:8];
                                end
                                C_PT_127_96: pt_data_reg[i][127:96] <= wmask(pt_data_reg[i][127:96], s_axi_wdata, s_axi_wstrb);
                                C_PT_95_64:  pt_data_reg[i][95:64]  <= wmask(pt_data_reg[i][95:64],  s_axi_wdata, s_axi_wstrb);
                                C_PT_63_32:  pt_data_reg[i][63:32]  <= wmask(pt_data_reg[i][63:32],  s_axi_wdata, s_axi_wstrb);
                                C_PT_31_0:   pt_data_reg[i][31:0]   <= wmask(pt_data_reg[i][31:0],   s_axi_wdata, s_axi_wstrb);
                                C_PT_CTRL: begin
                                    if (s_axi_wstrb[0]) begin
                                        pt_last_reg[i] <= s_axi_wdata[1];
                                        if (s_axi_wdata[0]) begin
                                            pt_valid_reg[i] <= 1'b1;
                                            out_valid_r[i]  <= 1'b0;
                                        end
                                    end
                                    if (s_axi_wstrb[1]) pt_len_reg[i] <= s_axi_wdata[12:8];
                                end
                                default: begin end
                            endcase
                        end
                    end
                end
            end

            // ---- Register reads (second stage) -------------------
            if (rd_stage) begin
                s_axi_rdata <= 32'd0;
                if (rd_page_q == 4'd0) begin
                    case (rd_off_q)
                        G_MODE:         s_axi_rdata <= {30'd0, has_ad_reg, mode_reg};
                        G_STATUS:       s_axi_rdata <= {g_pend, g_out, g_tag, g_busy};
                        G_ID:           s_axi_rdata <= {16'hA5C0, 8'd0, K[7:0]};
                        G_KEY_127_96:   s_axi_rdata <= key_reg[127:96];
                        G_KEY_95_64:    s_axi_rdata <= key_reg[95:64];
                        G_KEY_63_32:    s_axi_rdata <= key_reg[63:32];
                        G_KEY_31_0:     s_axi_rdata <= key_reg[31:0];
                        G_NONCE_127_96: s_axi_rdata <= nonce_reg[127:96];
                        G_NONCE_95_64:  s_axi_rdata <= nonce_reg[95:64];
                        G_NONCE_63_32:  s_axi_rdata <= nonce_reg[63:32];
                        G_NONCE_31_0:   s_axi_rdata <= nonce_reg[31:0];
                        G_CYCLE_LO:     s_axi_rdata <= cycle_counter[31:0];
                        G_CYCLE_HI:     s_axi_rdata <= cycle_counter[63:32];
                        default:        s_axi_rdata <= 32'd0;
                    endcase
                end else begin
                    for (i = 0; i < K; i = i + 1) begin
                        if (rd_page_q == i + 1) begin
                            case (rd_off_q)
                                C_STATUS:     s_axi_rdata <= {25'd0, pt_valid_reg[i], ad_valid_reg[i], busy[i],
                                                              tag_valid_r[i], out_valid_r[i],
                                                              core_pt_ready[i], core_ad_ready[i]};
                                C_AD_127_96:  s_axi_rdata <= ad_data_reg[i][127:96];
                                C_AD_95_64:   s_axi_rdata <= ad_data_reg[i][95:64];
                                C_AD_63_32:   s_axi_rdata <= ad_data_reg[i][63:32];
                                C_AD_31_0:    s_axi_rdata <= ad_data_reg[i][31:0];
                                C_AD_CTRL:    s_axi_rdata <= {19'd0, ad_len_reg[i], 6'd0, ad_last_reg[i], ad_valid_reg[i]};
                                C_PT_127_96:  s_axi_rdata <= pt_data_reg[i][127:96];
                                C_PT_95_64:   s_axi_rdata <= pt_data_reg[i][95:64];
                                C_PT_63_32:   s_axi_rdata <= pt_data_reg[i][63:32];
                                C_PT_31_0:    s_axi_rdata <= pt_data_reg[i][31:0];
                                C_PT_CTRL:    s_axi_rdata <= {19'd0, pt_len_reg[i], 6'd0, pt_last_reg[i], pt_valid_reg[i]};
                                C_OUT_127_96: s_axi_rdata <= out_data_r[i][127:96];
                                C_OUT_95_64:  s_axi_rdata <= out_data_r[i][95:64];
                                C_OUT_63_32:  s_axi_rdata <= out_data_r[i][63:32];
                                C_OUT_31_0:   s_axi_rdata <= out_data_r[i][31:0];
                                C_OUT_CTRL:   s_axi_rdata <= {19'd0, out_len_r[i], 6'd0, out_last_r[i], out_valid_r[i]};
                                C_TAG_127_96: s_axi_rdata <= tag_r[i][127:96];
                                C_TAG_95_64:  s_axi_rdata <= tag_r[i][95:64];
                                C_TAG_63_32:  s_axi_rdata <= tag_r[i][63:32];
                                C_TAG_31_0:   s_axi_rdata <= tag_r[i][31:0];
                                default:      s_axi_rdata <= 32'd0;
                            endcase
                        end
                    end
                end
            end
        end
    end

endmodule
