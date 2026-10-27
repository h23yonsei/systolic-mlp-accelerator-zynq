`timescale 1ns / 1ps

// 16x16 mesh of output-stationary PEs. Tile A rows enter at the left edge and tile B columns at
// the top edge; the bottom row's accumulators are the outputs, reached by draining.
module pe_array (
    input  wire               clk,
    input  wire               resetn,

    input  wire               en,       // enable all PEs
    input  wire               drain,    // shift the accumulators toward the post-processor
    input  wire               clear,    // start new sums

    input  wire signed [7:0]  left_array [0:15],       // tile A rows, left edge
    input  wire signed [7:0]  top_array  [0:15],       // tile B columns, top edge

    output logic signed [31:0] acc_out_array [0:15]    // bottom-row accumulators
);

    wire signed [7:0]  left_wire [0:15][0:15];   // horizontal data path
    wire signed [7:0]  top_wire  [0:15][0:15];   // vertical data path
    wire signed [31:0] acc_wire  [0:15][0:15];   // accumulator drain path

    genvar r, c;

    generate
        for (r = 0; r < 16; r = r + 1) begin : g_row
            for (c = 0; c < 16; c = c + 1) begin : g_col
                // edge PEs take the external inputs, inner PEs their neighbors' outputs; the top
                // row drains in zeros
                wire signed [7:0]  pe_left_in = (c == 0) ? left_array[r] : left_wire[r][c-1];
                wire signed [7:0]  pe_top_in  = (r == 0) ? top_array[c]  : top_wire[r-1][c];
                wire signed [31:0] pe_acc_in  = (r == 0) ? 32'sd0        : acc_wire[r-1][c];

                pe u_pe (
                    .clk        (clk),
                    .resetn     (resetn),
                    .en         (en),
                    .drain      (drain),
                    .clear      (clear),
                    .left_in    (pe_left_in),
                    .top_in     (pe_top_in),
                    .acc_in     (pe_acc_in),
                    .right_out  (left_wire[r][c]),
                    .bottom_out (top_wire[r][c]),
                    .acc_out    (acc_wire[r][c])
                );

                if (r == 15) begin : g_out
                    assign acc_out_array[c] = acc_wire[15][c];
                end
            end
        end
    endgenerate

endmodule
