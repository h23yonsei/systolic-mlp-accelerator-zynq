`timescale 1ns / 1ps

// Testbench for the 8x8 systolic array. The weight matrix (tb_weight.hex) is shifted in from the
// top, one array row per clock with the last row first, and save_weight is raised together with
// the final row, so every PE latches the weight arriving at it: PE (i, j) keeps weight[j][i]. The
// input matrix (tb_input.hex) is then fed from the left with row i delayed by i clocks, and
// column j of the array outputs sum over i of input[i][c] * weight[j][i] for c = 0..7 on
// consecutive clocks. The testbench computes the same products from the two files and checks all
// 64 outputs on the clock each one leaves the array.
//
// Inputs change 1 ns after the rising edge, so the array samples them at the next edge in every
// simulator. The matrices are read from the simulator's working directory; tools/run_sims.py copies
// them there.
module tb_systolic_array_8x8;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic               resetn;
    logic               save_weight;
    logic signed [7:0]  din_in  [0:7];
    logic signed [7:0]  win_in  [0:7];
    wire  signed [17:0] acc_out [0:7];

    logic signed [7:0]  input_mem  [0:7][0:7];
    logic signed [7:0]  weight_mem [0:7][0:7];
    int                 expected   [0:7][0:7];     // [column j][input column c]

    int col_idx;
    int c;
    int checked = 0;
    int errors  = 0;

    systolic_array_8x8 dut (
        .clk(clk),
        .resetn(resetn),
        .save_weight(save_weight),
        .din_in(din_in),
        .win_in(win_in),
        .acc_out(acc_out)
    );

    initial begin
        $readmemh("tb_input.hex", input_mem);
        $readmemh("tb_weight.hex", weight_mem);

        for (int j = 0; j < 8; j++)
            for (int cc = 0; cc < 8; cc++) begin
                expected[j][cc] = 0;
                for (int i = 0; i < 8; i++)
                    expected[j][cc] += int'(input_mem[i][cc]) * int'(weight_mem[j][i]);
            end

        resetn      = 1'd1;
        save_weight = 1'd0;
        for (int k = 0; k < 8; k++) begin
            din_in[k] = 8'sd0;
            win_in[k] = 8'sd0;
        end
        @(posedge clk) #1;

        // reset
        resetn = 1'd0;
        @(posedge clk) #1;
        resetn = 1'd1;
        @(posedge clk) #1;

        // shift the weights in, one array row per clock, and latch them with the last row
        for (int r = 7; r >= 0; r--) begin
            for (int j = 0; j < 8; j++)
                win_in[j] = weight_mem[j][r];
            save_weight = (r == 0);
            @(posedge clk) #1;
        end
        save_weight = 1'd0;
        for (int j = 0; j < 8; j++)
            win_in[j] = 8'sd0;

        // Feed the inputs, row i delayed by i clocks. The input sampled on feed clock n reaches the
        // bottom of column 0 seven clocks later, and column j another j clocks after that, so the
        // result for input column c leaves column j on feed clock c + j + 8.
        for (int cycle = 0; cycle < 24; cycle++) begin
            for (int i = 0; i < 8; i++) begin
                col_idx = cycle - i;
                if (col_idx >= 0 && col_idx < 8)
                    din_in[i] = input_mem[i][col_idx];
                else
                    din_in[i] = 8'sd0;
            end
            @(posedge clk) #1;

            // that was feed clock cycle + 1
            for (int j = 0; j < 8; j++) begin
                c = cycle + 1 - 8 - j;
                if (c >= 0 && c < 8) begin
                    checked++;
                    if (acc_out[j] !== expected[j][c]) begin
                        errors++;
                        $display("MISMATCH column %0d, input column %0d: got %0d, expected %0d",
                                 j, c, acc_out[j], expected[j][c]);
                    end
                end
            end
        end

        if (checked == 64 && errors == 0)
            $display("PASS: all 64 outputs match the matrix product");
        else
            $display("FAIL: %0d of %0d outputs checked differ from the matrix product", errors, checked);
        $finish;
    end

endmodule
