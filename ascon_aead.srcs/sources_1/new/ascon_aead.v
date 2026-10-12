`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/12/2026 01:18:41 PM
// Design Name: 
// Module Name: ascon_aead
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// ascon_aead: ASCON-AEAD128 encrypt/decrypt
// Iterative version: a single ascon_round instance, 1 round per cycle.
// p12 = 12 cycles, p8 = 8 cycles; 9 cycles per 128-bit AD/PT block.
// 
// Dependencies: ascon_aead_control, ascon_aead_datapath, ascon_round
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module ascon_aead(
        input  wire         clk,
        input  wire         rst,
    
        input  wire [127:0] key,
        input  wire [127:0] nonce,
        input  wire         mode,    // 0: Encrypt, 1: Decrypt
        input  wire         start,
        input  wire         has_ad,
    
        input  wire         ad_valid,
        input  wire [127:0] ad_data,
        input  wire         ad_last,
        input  wire [4:0]   ad_len,
        output wire         ad_ready,
    
        input  wire         pt_valid,
        input  wire [127:0] pt_data,
        input  wire         pt_last,
        input  wire [4:0]   pt_len,
        output wire         pt_ready,
    
        output wire         out_valid,
        output wire [127:0] out_data,
        output wire         out_last,
        output wire [4:0]   out_len,
        input  wire         out_ready,
    
        output wire         tag_valid,
        output wire [127:0] tag,
        output wire         tag_fail
    );
    
    // ----------------------------------------------------------
    // Control <-> datapath interconnect
    // ----------------------------------------------------------
    wire        load_cfg;
    wire        load_init;
    wire        round_en;
    wire [3:0]  round_idx;
    wire        xor_ad;
    wire        xor_pt;
    wire        xor_key23;
    wire        xor_key34;
    wire        xor_dsep;
    wire        xor_pad0;
    wire        out_en;
    wire        tag_en;
    
    wire        ad_full;
    wire        pt_full;
    
    ascon_aead_datapath u_aead_datapath(
        .clk(clk),
        .rst(rst),
        
        .key(key),
        .nonce(nonce),
        .mode(mode),
        .ad_data(ad_data),
        .ad_len(ad_len),
        .pt_data(pt_data),
        .pt_last(pt_last),
        .pt_len(pt_len),
        
        .out_data(out_data),
        .out_last(out_last),
        .out_len(out_len),
        .tag(tag),
        
        .load_cfg(load_cfg),
        .load_init(load_init),
        .round_en(round_en),
        .round_idx(round_idx),
        .xor_ad(xor_ad),
        .xor_pt(xor_pt),
        .xor_key23(xor_key23),
        .xor_key34(xor_key34),
        .xor_dsep(xor_dsep),
        .xor_pad0(xor_pad0),
        .out_en(out_en),
        .tag_en(tag_en),
        
        .ad_full(ad_full),
        .pt_full(pt_full)
    );
    
    ascon_aead_control u_aead_control(
        .clk(clk),
        .rst(rst),
        
        .start(start),
        .has_ad(has_ad),
        .ad_valid(ad_valid),
        .ad_last(ad_last),
        .pt_valid(pt_valid),
        .pt_last(pt_last),
        
        .ad_ready(ad_ready),
        .pt_ready(pt_ready),
        .out_valid(out_valid),
        .tag_valid(tag_valid),
        .tag_fail(tag_fail),
        
        .ad_full(ad_full),
        .pt_full(pt_full),
        
        .load_cfg(load_cfg),
        .load_init(load_init),
        .round_en(round_en),
        .round_idx(round_idx),
        .xor_ad(xor_ad),
        .xor_pt(xor_pt),
        .xor_key23(xor_key23),
        .xor_key34(xor_key34),
        .xor_dsep(xor_dsep),
        .xor_pad0(xor_pad0),
        .out_en(out_en),
        .tag_en(tag_en)
    );
    
endmodule
