`timescale 1ns / 1ps

// 8x8 weight-stationary systolic array: 64 PEs in a mesh. Row i takes its data from din_in[i] at
// the left edge, column j its weights from win_in[j] at the top edge, and the partial sums flow
// down the columns, so acc_out[j] is the accumulated result leaving the bottom of column j.
module systolic_array_8x8 (
    input  logic               clk,
    input  logic               resetn,
    input  logic               save_weight,

    input  logic signed [7:0]  din_in  [0:7],
    input  logic signed [7:0]  win_in  [0:7],

    output logic signed [17:0] acc_out [0:7]
);

    wire signed [7:0]  data_flow   [0:7][0:8];   // [i][j]: data entering PE (i, j)
    wire signed [7:0]  weight_flow [0:8][0:7];   // [i][j]: weight entering PE (i, j)
    wire signed [17:0] acc_flow    [0:8][0:7];   // [i][j]: partial sum entering PE (i, j)

    genvar i, j;

    generate
        for (i = 0; i < 8; i = i + 1) begin : g_row
            for (j = 0; j < 8; j = j + 1) begin : g_col
                pe u_pe (
                    .clk(clk),
                    .resetn(resetn),
                    .save_weight(save_weight),
                    .data_in(data_flow[i][j]),
                    .weight_in(weight_flow[i][j]),
                    .acc_in(acc_flow[i][j]),
                    .data_out(data_flow[i][j+1]),
                    .weight_out(weight_flow[i+1][j]),
                    .acc_out(acc_flow[i+1][j])
                );
            end
        end
    endgenerate

    // array edges: inputs on the left and top, zero partial sums at the top, results at the bottom
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_edge
            assign data_flow[i][0]   = din_in[i];
            assign weight_flow[0][i] = win_in[i];
            assign acc_flow[0][i]    = 18'sd0;
            assign acc_out[i]        = acc_flow[8][i];
        end
    endgenerate

endmodule
