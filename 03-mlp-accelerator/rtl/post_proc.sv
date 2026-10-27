`timescale 1ns / 1ps

// Requantization of the accumulators drained from the PE array's bottom row, in three registered
// stages: ReLU; multiply by the per-layer scale factor (M * 2^32); keep the upper 32 bits rounded
// to nearest and saturate to [0, 127]. valid_out follows valid_in by three cycles.
module post_proc #(
    parameter int SIZE = 16
)(
    input  wire                clk,
    input  wire                resetn,

    input  wire                valid_in,
    input  wire signed [31:0]  acc_in [0:SIZE-1],     // bottom-row accumulators
    input  wire [31:0]         scaler,                // per-layer scale factor, M * 2^32

    output logic               valid_out,             // result valid, 3 cycles after valid_in
    output logic signed [7:0]  data_out [0:SIZE-1]    // requantized int8 values
);

    logic        s1_valid;                // stage 1: ReLU
    logic [31:0] s1_relu [0:SIZE-1];

    logic        s2_valid;                // stage 2: scale
    logic [63:0] s2_prod [0:SIZE-1];      // 32 x 32 product

    logic [31:0] scaler_lane [0:SIZE-1];  // scale factor registered per lane

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            s1_valid  <= 1'b0;
            s2_valid  <= 1'b0;
            valid_out <= 1'b0;

            for (int i = 0; i < SIZE; i++) begin
                scaler_lane[i] <= 32'd0;
                s1_relu[i]     <= 32'd0;
                s2_prod[i]     <= 64'd0;
                data_out[i]    <= 8'sd0;
            end
        end else begin
            // reload the per-lane scale factors when the layer changes
            if (scaler_lane[0] != scaler) begin
                for (int i = 0; i < SIZE; i++) begin
                    scaler_lane[i] <= scaler;
                end
            end

            // stage 1: ReLU (negative sums become 0)
            s1_valid <= valid_in;
            if (valid_in) begin
                for (int i = 0; i < SIZE; i++) begin
                    s1_relu[i] <= acc_in[i][31] ? 32'd0 : acc_in[i];
                end
            end

            // stage 2: scale
            s2_valid <= s1_valid;
            if (s1_valid) begin
                for (int i = 0; i < SIZE; i++) begin
                    s2_prod[i] <= s1_relu[i] * scaler_lane[i];
                end
            end

            // stage 3: upper 32 bits rounded by bit 31, saturated to int8
            valid_out <= s2_valid;
            if (s2_valid) begin
                for (int i = 0; i < SIZE; i++) begin
                    logic [32:0] rounded;
                    rounded = {1'b0, s2_prod[i][63:32]} + s2_prod[i][31];
                    if (|rounded[32:7])
                        data_out[i] <= 8'sd127;
                    else
                        data_out[i] <= signed'({1'b0, rounded[6:0]});
                end
            end
        end
    end

endmodule
