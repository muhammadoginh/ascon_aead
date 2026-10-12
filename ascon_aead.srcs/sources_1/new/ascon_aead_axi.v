`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/12/2026 02:42:55 PM
// Design Name: 
// Module Name: ascon_aead_axi
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


module ascon_aead_axi #(
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
    
    localparam [11:0] ADDR_CONTROL       = 12'h000;
    localparam [11:0] ADDR_MODE          = 12'h004;
    localparam [11:0] ADDR_STATUS        = 12'h008;

    localparam [11:0] ADDR_KEY_127_96    = 12'h010;
    localparam [11:0] ADDR_KEY_95_64     = 12'h014;
    localparam [11:0] ADDR_KEY_63_32     = 12'h018;
    localparam [11:0] ADDR_KEY_31_0      = 12'h01c;

    localparam [11:0] ADDR_NONCE_127_96  = 12'h020;
    localparam [11:0] ADDR_NONCE_95_64   = 12'h024;
    localparam [11:0] ADDR_NONCE_63_32   = 12'h028;
    localparam [11:0] ADDR_NONCE_31_0    = 12'h02c;

    localparam [11:0] ADDR_AD_127_96     = 12'h040;
    localparam [11:0] ADDR_AD_95_64      = 12'h044;
    localparam [11:0] ADDR_AD_63_32      = 12'h048;
    localparam [11:0] ADDR_AD_31_0       = 12'h04c;
    localparam [11:0] ADDR_AD_CTRL       = 12'h050;

    localparam [11:0] ADDR_PT_127_96     = 12'h060;
    localparam [11:0] ADDR_PT_95_64      = 12'h064;
    localparam [11:0] ADDR_PT_63_32      = 12'h068;
    localparam [11:0] ADDR_PT_31_0       = 12'h06c;
    localparam [11:0] ADDR_PT_CTRL       = 12'h070;

    localparam [11:0] ADDR_OUT_127_96    = 12'h080;
    localparam [11:0] ADDR_OUT_95_64     = 12'h084;
    localparam [11:0] ADDR_OUT_63_32     = 12'h088;
    localparam [11:0] ADDR_OUT_31_0      = 12'h08c;
    localparam [11:0] ADDR_OUT_CTRL      = 12'h090;

    localparam [11:0] ADDR_TAG_127_96    = 12'h0a0;
    localparam [11:0] ADDR_TAG_95_64     = 12'h0a4;
    localparam [11:0] ADDR_TAG_63_32     = 12'h0a8;
    localparam [11:0] ADDR_TAG_31_0      = 12'h0ac;

    localparam [11:0] ADDR_HASH_IN_63_32 = 12'h0c0;
    localparam [11:0] ADDR_HASH_IN_31_0  = 12'h0c4;
    localparam [11:0] ADDR_HASH_CTRL     = 12'h0c8;
    localparam [11:0] ADDR_HASH_OUT_63_32 = 12'h0d0;
    localparam [11:0] ADDR_HASH_OUT_31_0 = 12'h0d4;

    localparam [11:0] ADDR_CYCLE_LO      = 12'h0e0;
    localparam [11:0] ADDR_CYCLE_HI      = 12'h0e4;

    wire write_fire = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    wire read_fire  = s_axi_arvalid && !s_axi_rvalid;
    wire [11:0] wr_addr = s_axi_awaddr[11:0];
    wire [11:0] rd_addr = s_axi_araddr[11:0];

    reg [127:0] key_reg;
    reg [127:0] nonce_reg;
    reg         mode_reg;
    reg         has_ad_reg;

    reg [127:0] ad_data_reg;
    reg         ad_last_reg;
    reg [4:0]   ad_len_reg;
    reg         ad_valid_pulse;

    reg [127:0] pt_data_reg;
    reg         pt_last_reg;
    reg [4:0]   pt_len_reg;
    reg         pt_valid_pulse;

    reg         aead_start_pulse;
    reg         aead_reset_pulse;

    reg [127:0] out_data_latched;
    reg         out_valid_latched;
    reg         out_last_latched;
    reg [4:0]   out_len_latched;

    reg [127:0] tag_latched;
    reg         tag_valid_latched;

    reg         aead_busy;
    reg [63:0]  cycle_counter;

    wire        aead_ad_ready;
    wire        aead_pt_ready;
    wire        aead_out_valid;
    wire [127:0] aead_out_data;
    wire        aead_out_last;
    wire [4:0]  aead_out_len;
    wire        aead_tag_valid;
    wire [127:0] aead_tag;
    wire        aead_tag_fail;


    wire        aead_rst = !s_axi_aresetn || aead_reset_pulse;

    wire [31:0] status_word = {
        24'd0,
        aead_busy,
        tag_valid_latched,
        out_valid_latched,
        aead_pt_ready,
        aead_ad_ready
    };

    ascon_aead u_ascon_aead (
        .clk(s_axi_aclk),
        .rst(aead_rst),
        .key(key_reg),
        .nonce(nonce_reg),
        .mode(mode_reg),
        .start(aead_start_pulse),
        .has_ad(has_ad_reg),
        .ad_valid(ad_valid_pulse),
        .ad_data(ad_data_reg),
        .ad_last(ad_last_reg),
        .ad_len(ad_len_reg),
        .ad_ready(aead_ad_ready),
        .pt_valid(pt_valid_pulse),
        .pt_data(pt_data_reg),
        .pt_last(pt_last_reg),
        .pt_len(pt_len_reg),
        .pt_ready(aead_pt_ready),
        .out_valid(aead_out_valid),
        .out_data(aead_out_data),
        .out_last(aead_out_last),
        .out_len(aead_out_len),
        .out_ready(1'b1),
        .tag_valid(aead_tag_valid),
        .tag(aead_tag),
        .tag_fail(aead_tag_fail)
    );

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

            key_reg <= 128'd0;
            nonce_reg <= 128'd0;
            mode_reg <= 1'b0;
            has_ad_reg <= 1'b0;
            ad_data_reg <= 128'd0;
            ad_last_reg <= 1'b0;
            ad_len_reg <= 5'd0;
            pt_data_reg <= 128'd0;
            pt_last_reg <= 1'b0;
            pt_len_reg <= 5'd0;

            ad_valid_pulse <= 1'b0;
            pt_valid_pulse <= 1'b0;
            aead_start_pulse <= 1'b0;
            aead_reset_pulse <= 1'b0;

            out_data_latched <= 128'd0;
            out_valid_latched <= 1'b0;
            out_last_latched <= 1'b0;
            out_len_latched <= 5'd0;
            tag_latched <= 128'd0;
            tag_valid_latched <= 1'b0;
            aead_busy <= 1'b0;
            cycle_counter <= 64'd0;
        end else begin
            cycle_counter <= cycle_counter + 64'd1;

            s_axi_awready <= write_fire;
            s_axi_wready  <= write_fire;
            s_axi_arready <= read_fire;

            ad_valid_pulse <= 1'b0;
            pt_valid_pulse <= 1'b0;

            aead_start_pulse <= 1'b0;
            aead_reset_pulse <= 1'b0;


            if (write_fire) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp <= 2'b00;
                case (wr_addr)
                    ADDR_CONTROL: begin
                        aead_reset_pulse <= s_axi_wdata[0];
                        aead_start_pulse <= s_axi_wdata[1];
                        if (s_axi_wdata[0]) begin
                            out_valid_latched <= 1'b0;
                            tag_valid_latched <= 1'b0;
                            aead_busy <= 1'b0;
                        end
                        if (s_axi_wdata[1]) begin
                            out_valid_latched <= 1'b0;
                            tag_valid_latched <= 1'b0;
                            aead_busy <= 1'b1;
                        end
                    end

                    ADDR_MODE: begin
                        mode_reg <= s_axi_wdata[0];
                        has_ad_reg <= s_axi_wdata[1];
                    end

                    ADDR_KEY_127_96: key_reg[127:96] <= s_axi_wdata;
                    ADDR_KEY_95_64:  key_reg[95:64]  <= s_axi_wdata;
                    ADDR_KEY_63_32:  key_reg[63:32]  <= s_axi_wdata;
                    ADDR_KEY_31_0:   key_reg[31:0]   <= s_axi_wdata;

                    ADDR_NONCE_127_96: nonce_reg[127:96] <= s_axi_wdata;
                    ADDR_NONCE_95_64:  nonce_reg[95:64]  <= s_axi_wdata;
                    ADDR_NONCE_63_32:  nonce_reg[63:32]  <= s_axi_wdata;
                    ADDR_NONCE_31_0:   nonce_reg[31:0]   <= s_axi_wdata;

                    ADDR_AD_127_96: ad_data_reg[127:96] <= s_axi_wdata;
                    ADDR_AD_95_64:  ad_data_reg[95:64]  <= s_axi_wdata;
                    ADDR_AD_63_32:  ad_data_reg[63:32]  <= s_axi_wdata;
                    ADDR_AD_31_0:   ad_data_reg[31:0]   <= s_axi_wdata;
                    ADDR_AD_CTRL: begin
                        ad_valid_pulse <= s_axi_wdata[0];
                        ad_last_reg <= s_axi_wdata[1];
                        ad_len_reg <= s_axi_wdata[12:8];
                    end

                    ADDR_PT_127_96: pt_data_reg[127:96] <= s_axi_wdata;
                    ADDR_PT_95_64:  pt_data_reg[95:64]  <= s_axi_wdata;
                    ADDR_PT_63_32:  pt_data_reg[63:32]  <= s_axi_wdata;
                    ADDR_PT_31_0:   pt_data_reg[31:0]   <= s_axi_wdata;
                    ADDR_PT_CTRL: begin
                        pt_valid_pulse <= s_axi_wdata[0];
                        pt_last_reg <= s_axi_wdata[1];
                        pt_len_reg <= s_axi_wdata[12:8];
                        if (s_axi_wdata[0]) begin
                            out_valid_latched <= 1'b0;
                        end
                    end

                    default: begin
                    end
                endcase
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            if (read_fire) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp <= 2'b00;
                case (rd_addr)
                    ADDR_CONTROL: s_axi_rdata <= 32'd0;
                    ADDR_MODE: s_axi_rdata <= {30'd0, has_ad_reg, mode_reg};
                    ADDR_STATUS: s_axi_rdata <= status_word;

                    ADDR_KEY_127_96: s_axi_rdata <= key_reg[127:96];
                    ADDR_KEY_95_64:  s_axi_rdata <= key_reg[95:64];
                    ADDR_KEY_63_32:  s_axi_rdata <= key_reg[63:32];
                    ADDR_KEY_31_0:   s_axi_rdata <= key_reg[31:0];

                    ADDR_NONCE_127_96: s_axi_rdata <= nonce_reg[127:96];
                    ADDR_NONCE_95_64:  s_axi_rdata <= nonce_reg[95:64];
                    ADDR_NONCE_63_32:  s_axi_rdata <= nonce_reg[63:32];
                    ADDR_NONCE_31_0:   s_axi_rdata <= nonce_reg[31:0];

                    ADDR_AD_127_96: s_axi_rdata <= ad_data_reg[127:96];
                    ADDR_AD_95_64:  s_axi_rdata <= ad_data_reg[95:64];
                    ADDR_AD_63_32:  s_axi_rdata <= ad_data_reg[63:32];
                    ADDR_AD_31_0:   s_axi_rdata <= ad_data_reg[31:0];
                    ADDR_AD_CTRL:   s_axi_rdata <= {19'd0, ad_len_reg, 6'd0, ad_last_reg, 1'b0};

                    ADDR_PT_127_96: s_axi_rdata <= pt_data_reg[127:96];
                    ADDR_PT_95_64:  s_axi_rdata <= pt_data_reg[95:64];
                    ADDR_PT_63_32:  s_axi_rdata <= pt_data_reg[63:32];
                    ADDR_PT_31_0:   s_axi_rdata <= pt_data_reg[31:0];
                    ADDR_PT_CTRL:   s_axi_rdata <= {19'd0, pt_len_reg, 6'd0, pt_last_reg, 1'b0};

                    ADDR_OUT_127_96: s_axi_rdata <= out_data_latched[127:96];
                    ADDR_OUT_95_64:  s_axi_rdata <= out_data_latched[95:64];
                    ADDR_OUT_63_32:  s_axi_rdata <= out_data_latched[63:32];
                    ADDR_OUT_31_0:   s_axi_rdata <= out_data_latched[31:0];
                    ADDR_OUT_CTRL:   s_axi_rdata <= {19'd0, out_len_latched, 6'd0, out_last_latched, out_valid_latched};

                    ADDR_TAG_127_96: s_axi_rdata <= tag_latched[127:96];
                    ADDR_TAG_95_64:  s_axi_rdata <= tag_latched[95:64];
                    ADDR_TAG_63_32:  s_axi_rdata <= tag_latched[63:32];
                    ADDR_TAG_31_0:   s_axi_rdata <= tag_latched[31:0];

                    ADDR_CYCLE_LO: s_axi_rdata <= cycle_counter[31:0];
                    ADDR_CYCLE_HI: s_axi_rdata <= cycle_counter[63:32];
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end

            if (aead_out_valid) begin
                out_data_latched <= aead_out_data;
                out_last_latched <= aead_out_last;
                out_len_latched <= aead_out_len;
                out_valid_latched <= 1'b1;
            end

            if (aead_tag_valid) begin
                tag_latched <= aead_tag;
                tag_valid_latched <= 1'b1;
                aead_busy <= 1'b0;
            end
        end
    end
    
endmodule
