`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 10/12/2026 01:19:12 PM
// Design Name:
// Module Name: ascon_aead_datapath
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
// ascon_aead_datapath: 320-bit state register (s0..s4), saved key/mode,
// a single iterative ascon_round and the absorb / key / padding XORs
// for ASCON-AEAD128. Driven by ascon_aead_control.
//
// Each cycle the state register takes exactly one of:
//   round_en  : s <= round(s)                    (one Ascon round)
//   load_init : s <= {IV, key, nonce}
//   otherwise : s <= s ^ (enabled xor_* terms)    (hold when none enabled)
// The round output only passes through a 2:1 mux before the register,
// keeping the round -> state loop short for high Fmax.
//
// Dependencies: ascon_round
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module ascon_aead_datapath(
        input  wire         clk,
        input  wire         rst,

        // Data inputs
        input  wire [127:0] key,
        input  wire [127:0] nonce,
        input  wire         mode,    // 0: Encrypt, 1: Decrypt
        input  wire [127:0] ad_data,
        input  wire [4:0]   ad_len,
        input  wire [127:0] pt_data,
        input  wire         pt_last,
        input  wire [4:0]   pt_len,

        // Data outputs
        output wire [127:0] out_data,
        output wire         out_last,
        output wire [4:0]   out_len,
        output wire [127:0] tag,

        // Control (from ascon_aead_control)
        input  wire         load_cfg,   // latch key / mode
        input  wire         load_init,  // s <= {IV, key, nonce}
        input  wire         round_en,   // s <= round(s)
        input  wire [3:0]   round_idx,  // round constant index (0..11)
        input  wire         xor_ad,     // s0,s1 ^= padded AD
        input  wire         xor_pt,     // s0,s1 ^= padded PT (or CT-derived PT)
        input  wire         xor_key23,  // s2,s3 ^= key   (before finalization)
        input  wire         xor_key34,  // s3,s4 ^= key   (after init / finalization)
        input  wire         xor_dsep,   // s4    ^= 1 << 63 (domain separation)
        input  wire         xor_pad0,   // s0    ^= 1 << 63 (padding of a full last block)
        input  wire         out_en,     // drive out_data / out_last / out_len
        input  wire         tag_en,     // drive tag

        // Status (to ascon_aead_control)
        output wire         ad_full,    // ad_len == 16
        output wire         pt_full     // pt_len == 16
    );

    localparam [63:0] IV   = 64'h01008c0080100000;
    localparam [63:0] DSEP = 64'h8000_0000_0000_0000;

    // ----------------------------------------------------------
    // State / data registers
    // ----------------------------------------------------------
    reg [63:0]  s0, s1, s2, s3, s4;
    reg [127:0] saved_key;
    reg         saved_mode;

    // ----------------------------------------------------------
    // Single round instance
    // ----------------------------------------------------------
    wire [319:0] r_out;

    ascon_round round_inst (
        .round_idx(round_idx),
        .x_in     ({s0, s1, s2, s3, s4}),
        .x_out    (r_out)
    );

    // ----------------------------------------------------------
    // Byte masks for padding / truncation
    // Byte b (b = 0 is the first byte, bits [127-8b -: 8]) is kept when
    // b < len and carries the 0x80 padding byte when b == len. Each mask bit
    // is a 5-input compare (one LUT), instead of len*8 shift arithmetic,
    // so the len -> state path stays short when len comes from a register.
    // ----------------------------------------------------------
    wire [127:0] ad_keep, ad_pad, pt_keep, pt_pad;

    genvar gb;
    generate
        for (gb = 0; gb < 16; gb = gb + 1) begin : g_byte
            assign ad_keep[127-8*gb -: 8] = {8{ad_len >  gb}};
            assign pt_keep[127-8*gb -: 8] = {8{pt_len >  gb}};
            assign ad_pad [127-8*gb -: 8] = {(ad_len == gb), 7'd0};
            assign pt_pad [127-8*gb -: 8] = {(pt_len == gb), 7'd0};
        end
    endgenerate

    // Combinatorial AD/PT helper wires (only valid when inputs asserted)
    wire [127:0] padded_ad = (ad_data & ad_keep) | ad_pad;
    wire [127:0] pt_xored  = {s0 ^ pt_data[127:64], s1 ^ pt_data[63:0]};
    wire [127:0] actual_pt = (saved_mode == 0) ? pt_data : pt_xored;
    wire [127:0] padded_pt = (actual_pt & pt_keep) | pt_pad;

    // ----------------------------------------------------------
    // XOR terms (non-round cycles)
    // ----------------------------------------------------------
    wire [63:0] x0 = ({64{xor_ad}}    & padded_ad[127:64])
                   ^ ({64{xor_pt}}    & padded_pt[127:64])
                   ^ ({64{xor_pad0}}  & DSEP);
    wire [63:0] x1 = ({64{xor_ad}}    & padded_ad[63:0])
                   ^ ({64{xor_pt}}    & padded_pt[63:0]);
    wire [63:0] x2 = ({64{xor_key23}} & saved_key[127:64]);
    wire [63:0] x3 = ({64{xor_key23}} & saved_key[63:0])
                   ^ ({64{xor_key34}} & saved_key[127:64]);
    wire [63:0] x4 = ({64{xor_key34}} & saved_key[63:0])
                   ^ ({64{xor_dsep}}  & DSEP);

    // ----------------------------------------------------------
    // Non-round next state (load or XOR terms)
    // KEEP stops synthesis from merging this into the round path, so
    // the round loop maps to 2 LUT levels: S-box LUT6, then one LUT5 for
    // the 3-input linear-layer XOR + round_en mux.
    // ----------------------------------------------------------
    (* keep = "true" *) wire [319:0] s_alt;

    assign s_alt = load_init ? {IV, key, nonce}
                             : {s0 ^ x0, s1 ^ x1, s2 ^ x2, s3 ^ x3, s4 ^ x4};

    // ----------------------------------------------------------
    // Sequential: data registers
    // ----------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s0 <= 0; s1 <= 0; s2 <= 0; s3 <= 0; s4 <= 0;
            saved_key  <= 0;
            saved_mode <= 0;
        end else begin
            if (round_en)
                {s0, s1, s2, s3, s4} <= r_out;
            else
                {s0, s1, s2, s3, s4} <= s_alt;

            if (load_cfg) begin
                saved_key  <= key;
                saved_mode <= mode;
            end
        end
    end

    // ----------------------------------------------------------
    // Outputs / status
    // ----------------------------------------------------------
    assign out_data = out_en ? (pt_xored & pt_keep) : 128'd0;
    assign out_last = out_en ? pt_last : 1'b0;
    assign out_len  = out_en ? pt_len  : 5'd0;
    assign tag      = tag_en ? {s3, s4} : 128'd0;

    assign ad_full  = (ad_len == 5'd16);
    assign pt_full  = (pt_len == 5'd16);

endmodule
