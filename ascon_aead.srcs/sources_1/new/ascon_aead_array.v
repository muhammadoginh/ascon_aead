`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 10/12/2026 06:00:00 PM
// Design Name:
// Module Name: ascon_aead_array
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
// ascon_aead_array: K independent ascon_aead cores (pure architecture, no
// bus interface), one per concurrent UAV link. Used to report the
// architecture's area / Fmax scaling with K after place and route.
// Port i of every vector belongs to core i (e.g. key[128*i +: 128]).
//
// Dependencies: ascon_aead
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module ascon_aead_array #(
        parameter integer K = 4
    )(
        input  wire             clk,
        input  wire             rst,

        input  wire [128*K-1:0] key,
        input  wire [128*K-1:0] nonce,
        input  wire [K-1:0]     mode,
        input  wire [K-1:0]     start,
        input  wire [K-1:0]     has_ad,

        input  wire [K-1:0]     ad_valid,
        input  wire [128*K-1:0] ad_data,
        input  wire [K-1:0]     ad_last,
        input  wire [5*K-1:0]   ad_len,
        output wire [K-1:0]     ad_ready,

        input  wire [K-1:0]     pt_valid,
        input  wire [128*K-1:0] pt_data,
        input  wire [K-1:0]     pt_last,
        input  wire [5*K-1:0]   pt_len,
        output wire [K-1:0]     pt_ready,

        output wire [K-1:0]     out_valid,
        output wire [128*K-1:0] out_data,
        output wire [K-1:0]     out_last,
        output wire [5*K-1:0]   out_len,
        input  wire [K-1:0]     out_ready,

        output wire [K-1:0]     tag_valid,
        output wire [128*K-1:0] tag,
        output wire [K-1:0]     tag_fail
    );

    genvar i;
    generate
        for (i = 0; i < K; i = i + 1) begin : g_core
            ascon_aead u_ascon_aead (
                .clk      (clk),
                .rst      (rst),
                .key      (key[128*i +: 128]),
                .nonce    (nonce[128*i +: 128]),
                .mode     (mode[i]),
                .start    (start[i]),
                .has_ad   (has_ad[i]),
                .ad_valid (ad_valid[i]),
                .ad_data  (ad_data[128*i +: 128]),
                .ad_last  (ad_last[i]),
                .ad_len   (ad_len[5*i +: 5]),
                .ad_ready (ad_ready[i]),
                .pt_valid (pt_valid[i]),
                .pt_data  (pt_data[128*i +: 128]),
                .pt_last  (pt_last[i]),
                .pt_len   (pt_len[5*i +: 5]),
                .pt_ready (pt_ready[i]),
                .out_valid(out_valid[i]),
                .out_data (out_data[128*i +: 128]),
                .out_last (out_last[i]),
                .out_len  (out_len[5*i +: 5]),
                .out_ready(out_ready[i]),
                .tag_valid(tag_valid[i]),
                .tag      (tag[128*i +: 128]),
                .tag_fail (tag_fail[i])
            );
        end
    endgenerate

endmodule
