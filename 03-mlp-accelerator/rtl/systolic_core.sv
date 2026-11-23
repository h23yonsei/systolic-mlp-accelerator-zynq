`timescale 1ns / 1ps

// Systolic core: the 16x16 PE array and the post-processor that requantizes its drained bottom
// row to int8.
module systolic_core (
    input  wire                clk,
    input  wire                resetn,

    input  wire                pe_en,              // enable PE computation
    input  wire                pe_clear,           // start new sums
    input  wire                pe_drain,           // shift the accumulators to the post-processor

    input  wire signed [7:0]   left_in [0:15],     // tile A rows
    input  wire signed [7:0]   top_in  [0:15],     // tile B columns

    input  wire                pp_valid_in,        // latch the bottom-row accumulators
    input  wire [31:0]         pp_scaler,          // quantization scale factor

    output logic signed [31:0] acc_out [0:15],     // raw accumulators (debug)
    output logic               pp_valid_out,       // requantized result ready, 3 cycles later
    output logic signed [7:0]  pp_data [0:15]      // requantized int8 values
);

    // 16x16 PE array: tile A x tile B, accumulated across k-tiles
    pe_array u_pe_arr (
        .clk           (clk),
        .resetn        (resetn),
        .en            (pe_en),
        .drain         (pe_drain),
        .clear         (pe_clear),
        .left_array    (left_in),
        .top_array     (top_in),
        .acc_out_array (acc_out)
    );

    // three-stage pipeline: ReLU, scale, round and saturate to int8
    post_proc u_post_proc (
        .clk       (clk),
        .resetn    (resetn),
        .valid_in  (pp_valid_in),
        .acc_in    (acc_out),
        .scaler    (pp_scaler),
        .valid_out (pp_valid_out),
        .data_out  (pp_data)
    );

endmodule
