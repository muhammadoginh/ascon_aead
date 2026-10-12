`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/12/2026 01:15:54 PM
// Design Name: 
// Module Name: ascon_round
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: ascon_round: single combinational Ascon permutation round
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module ascon_round(
        input  [3:0]   round_idx,
        input  [319:0] x_in,
        output [319:0] x_out
    );
    
    wire [63:0] x0, x1, x2, x3, x4;
    assign {x0, x1, x2, x3, x4} = x_in;

    // 1. Addition of Constants
    // c_i = ((0xf - i) << 4) | i = {~i, i}: 0xf0, 0xe1, ... 0x4b for i = 0..11.
    // Pure wiring from round_idx, so no decode logic in the round path.
    wire [7:0]  round_const = {~round_idx, round_idx};
    wire [63:0] x2_c = x2 ^ {56'd0, round_const};

    // 2. Substitution Layer
    wire [63:0] s0 = x0 ^ x4;
    wire [63:0] s1 = x1;
    wire [63:0] s2 = x2_c ^ x1;
    wire [63:0] s3 = x3;
    wire [63:0] s4 = x4 ^ x3;

    wire [63:0] t0 = (~s0) & s1;
    wire [63:0] t1 = (~s1) & s2;
    wire [63:0] t2 = (~s2) & s3;
    wire [63:0] t3 = (~s3) & s4;
    wire [63:0] t4 = (~s4) & s0;

    wire [63:0] u0 = s0 ^ t1;
    wire [63:0] u1 = s1 ^ t2;
    wire [63:0] u2 = s2 ^ t3;
    wire [63:0] u3 = s3 ^ t4;
    wire [63:0] u4 = s4 ^ t0;

    wire [63:0] v0 = u0 ^ u4;
    wire [63:0] v1 = u1 ^ u0;
    wire [63:0] v2 = ~u2;
    wire [63:0] v3 = u3 ^ u2;
    wire [63:0] v4 = u4;

    // 3. Linear Diffusion Layer
    wire [63:0] y0 = v0 ^ {v0[18:0], v0[63:19]} ^ {v0[27:0], v0[63:28]};
    wire [63:0] y1 = v1 ^ {v1[60:0], v1[63:61]} ^ {v1[38:0], v1[63:39]};
    wire [63:0] y2 = v2 ^ {v2[0:0],  v2[63:1]}  ^ {v2[5:0],  v2[63:6]};
    wire [63:0] y3 = v3 ^ {v3[9:0],  v3[63:10]} ^ {v3[16:0], v3[63:17]};
    wire [63:0] y4 = v4 ^ {v4[6:0],  v4[63:7]}  ^ {v4[40:0], v4[63:41]};

    assign x_out = {y0, y1, y2, y3, y4};
    
endmodule
