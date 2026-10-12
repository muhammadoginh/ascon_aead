`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 10/12/2026 01:19:24 PM
// Design Name:
// Module Name: ascon_aead_control
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
// ascon_aead_control: FSM for ASCON-AEAD128 with a single iterative round.
// Sequences ascon_aead_datapath and drives the handshake signals.
//
// The FSM is hand-coded one-hot: each state is its own flip-flop, so
// ad_ready / pt_ready / ... come straight from state bits and every next-
// state bit is a small sum of products. All datapath controls that depend
// only on the state (round_en, round_idx, xor_key34, xor_dsep, xor_pad0)
// are registered. Controls that depend on an input handshake (load_init,
// xor_ad, xor_pt, xor_key23) are one AND with a state bit.
// p12 runs round_idx 0..11, p8 runs 4..11.
//
// Cycle counts (clock edges, back-to-back inputs):
//   start -> ready         : 14  (load + 12 rounds + key XOR)
//   AD/PT block -> ready   :  9  (absorb + 8 rounds)
//   last AD block -> ready : 10  (absorb + 8 rounds + domain sep)
//   last PT block -> tag   : 14  (absorb + 12 rounds + key XOR)
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module ascon_aead_control(
        input  wire         clk,
        input  wire         rst,

        // Handshake / command inputs
        input  wire         start,
        input  wire         has_ad,
        input  wire         ad_valid,
        input  wire         ad_last,
        input  wire         pt_valid,
        input  wire         pt_last,

        // Handshake outputs
        output wire         ad_ready,
        output wire         pt_ready,
        output wire         out_valid,
        output wire         tag_valid,
        output wire         tag_fail,

        // Status (from ascon_aead_datapath)
        input  wire         ad_full,
        input  wire         pt_full,

        // Control (to ascon_aead_datapath)
        output wire         load_cfg,
        output wire         load_init,
        output reg          round_en,
        output reg  [3:0]   round_idx,
        output wire         xor_ad,
        output wire         xor_pt,
        output wire         xor_key23,
        output reg          xor_key34,
        output reg          xor_dsep,
        output reg          xor_pad0,
        output wire         out_en,
        output wire         tag_en
    );

    // ----------------------------------------------------------
    // FSM states (one-hot, one flip-flop each)
    // ----------------------------------------------------------
    //   st_wait      : idle / done, waiting for start (tag_valid when done_r)
    //   st_init_p12  : 12 rounds after load
    //   st_init_key  : s3,s4 ^= key (+ domain sep if no AD)
    //   st_ad        : waiting for ad_valid
    //   st_ad_p8     : 8 rounds after an AD block
    //   st_ad_pad    : s0 ^= pad (full last AD block), then p8 again
    //   st_ad_dsep   : s4 ^= domain sep
    //   st_pt        : waiting for pt_valid
    //   st_pt_p8     : 8 rounds after a PT block
    //   st_pt_padkey : s0 ^= pad, s2,s3 ^= key (full last PT block)
    //   st_fin_p12   : 12 rounds of finalization
    //   st_fin_key   : s3,s4 ^= key -> tag
    localparam [3:0] P12_FIRST = 4'd0;
    localparam [3:0] P8_FIRST  = 4'd4;
    localparam [3:0] LAST_RND  = 4'd11;

    (* max_fanout = 32 *) reg st_wait;
    reg                       st_init_p12;
    reg                       st_init_key;
    (* max_fanout = 32 *) reg st_ad;
    reg                       st_ad_p8;
    reg                       st_ad_pad;
    reg                       st_ad_dsep;
    (* max_fanout = 32 *) reg st_pt;
    reg                       st_pt_p8;
    (* max_fanout = 32 *) reg st_pt_padkey;
    reg                       st_fin_p12;
    reg                       st_fin_key;

    reg       done_r;        // tag is valid (set after finalization, cleared on start)
    reg       saved_has_ad;
    reg       ad_last_r;     // block in AD_P8 was the last AD block
    reg       ad_pad_r;      // last AD block was full: padding block still to do
    reg       pt_last_r;     // block in PT_P8 was a full last PT block

    // Registered: high during the last round (round_idx == 11). Rounds always
    // run back to back, so round_idx == 10 means the next cycle is the last.
    reg       last_round;

    // ----------------------------------------------------------
    // Handshake-dependent controls
    // ----------------------------------------------------------
    wire start_acc   = st_wait && start;
    wire ad_acc      = st_ad   && ad_valid;
    wire pt_acc      = st_pt   && pt_valid;
    wire pt_acc_part = pt_acc  && pt_last && !pt_full;   // partial last PT block

    assign load_cfg  = start_acc;
    assign load_init = start_acc;
    assign xor_ad    = ad_acc;
    assign xor_pt    = pt_acc;
    // Partial last PT block: key into s2/s3 together with the absorb
    assign xor_key23 = st_pt_padkey || pt_acc_part;

    assign ad_ready  = st_ad;
    assign pt_ready  = st_pt;
    assign out_valid = pt_acc;
    assign tag_valid = done_r;
    assign out_en    = out_valid;
    assign tag_en    = tag_valid;
    assign tag_fail  = 1'b0;

    // ----------------------------------------------------------
    // Next state (one-hot)
    // ----------------------------------------------------------
    wire ad_end     = st_ad_p8 && last_round && ad_last_r;

    wire n_wait      = (st_wait && !start) || st_fin_key;
    wire n_init_p12  = start_acc || (st_init_p12 && !last_round);
    wire n_init_key  = st_init_p12 && last_round;
    wire n_ad        = (st_init_key && saved_has_ad) || (st_ad && !ad_valid) ||
                       (st_ad_p8 && last_round && !ad_last_r);
    wire n_ad_p8     = ad_acc || (st_ad_p8 && !last_round) || st_ad_pad;
    wire n_ad_pad    = ad_end && ad_pad_r;
    wire n_ad_dsep   = ad_end && !ad_pad_r;
    wire n_pt        = (st_init_key && !saved_has_ad) || st_ad_dsep || (st_pt && !pt_valid) ||
                       (st_pt_p8 && last_round && !pt_last_r);
    wire n_pt_p8     = (pt_acc && !pt_acc_part) || (st_pt_p8 && !last_round);
    wire n_pt_padkey = st_pt_p8 && last_round && pt_last_r;
    wire n_fin_p12   = pt_acc_part || st_pt_padkey || (st_fin_p12 && !last_round);
    wire n_fin_key   = st_fin_p12 && last_round;

    // ----------------------------------------------------------
    // Sequential
    // ----------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st_wait      <= 1;
            st_init_p12  <= 0;
            st_init_key  <= 0;
            st_ad        <= 0;
            st_ad_p8     <= 0;
            st_ad_pad    <= 0;
            st_ad_dsep   <= 0;
            st_pt        <= 0;
            st_pt_p8     <= 0;
            st_pt_padkey <= 0;
            st_fin_p12   <= 0;
            st_fin_key   <= 0;
            done_r       <= 0;
            saved_has_ad <= 0;
            ad_last_r    <= 0;
            ad_pad_r     <= 0;
            pt_last_r    <= 0;
            round_en     <= 0;
            round_idx    <= 0;
            last_round   <= 0;
            xor_key34    <= 0;
            xor_dsep     <= 0;
            xor_pad0     <= 0;
        end else begin
            st_wait      <= n_wait;
            st_init_p12  <= n_init_p12;
            st_init_key  <= n_init_key;
            st_ad        <= n_ad;
            st_ad_p8     <= n_ad_p8;
            st_ad_pad    <= n_ad_pad;
            st_ad_dsep   <= n_ad_dsep;
            st_pt        <= n_pt;
            st_pt_p8     <= n_pt_p8;
            st_pt_padkey <= n_pt_padkey;
            st_fin_p12   <= n_fin_p12;
            st_fin_key   <= n_fin_key;

            done_r <= st_fin_key || (done_r && !start_acc);

            if (start_acc)
                saved_has_ad <= has_ad;
            if (ad_acc) begin
                ad_last_r <= ad_last;
                ad_pad_r  <= ad_last && ad_full;
            end else if (st_ad_pad) begin
                ad_pad_r  <= 1'b0;
            end
            if (pt_acc)
                pt_last_r <= pt_last && pt_full;
            else if (st_pt_padkey)
                pt_last_r <= 1'b0;

            // Registered round control.
            // A permutation starts after every load / absorb / padding cycle
            // and runs until its last round.
            round_en   <= (round_en && !last_round) || start_acc || ad_acc || pt_acc || xor_pad0;
            last_round <= round_en && (round_idx == LAST_RND - 4'd1);
            // round_idx counts during rounds; otherwise it holds the first index of
            // the permutation that may start next (only used while round_en = 1).
            if (round_en)
                round_idx <= round_idx + 4'd1;
            else if (st_wait || st_pt_padkey || (st_pt && pt_last && !pt_full))
                round_idx <= P12_FIRST;
            else
                round_idx <= P8_FIRST;

            // Registered state-only datapath controls (valid in the matching state)
            xor_key34 <= n_init_key || n_fin_key;
            xor_pad0  <= n_ad_pad   || n_pt_padkey;
            xor_dsep  <= n_ad_dsep  || (n_init_key && !saved_has_ad);
        end
    end
    
endmodule
