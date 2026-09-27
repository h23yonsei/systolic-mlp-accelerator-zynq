`timescale 1ns / 1ps

// Weight-stationary processing element for the 8x8 systolic array. Data moves right and weights
// move down one PE per clock. The first time save_weight is high, the PE latches the weight
// passing through it; from then on it adds data_in x weight to the partial sum arriving from the
// PE above and passes the result down.
module pe (
    input  logic               clk,
    input  logic               resetn,
    input  logic               save_weight,

    input  logic signed [7:0]  data_in,
    input  logic signed [7:0]  weight_in,
    input  logic signed [17:0] acc_in,

    output logic signed [7:0]  data_out,
    output logic signed [7:0]  weight_out,
    output logic signed [17:0] acc_out
);

    logic              has_weight;
    logic signed [7:0] internal_weight;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            data_out        <= 8'd0;
            weight_out      <= 8'd0;
            acc_out         <= 18'd0;
            internal_weight <= 8'd0;
            has_weight      <= 1'd0;
        end else begin
            data_out   <= data_in;
            weight_out <= weight_in;

            // latch the weight passing through on the first save_weight
            if (save_weight && !has_weight) begin
                internal_weight <= weight_in;
                has_weight      <= 1'd1;
                acc_out         <= acc_in;
            end

            if (has_weight)
                acc_out <= acc_in + (data_in * internal_weight);   // multiply-accumulate
            else
                acc_out <= acc_in;                                 // pass the partial sum down
        end
    end

endmodule
