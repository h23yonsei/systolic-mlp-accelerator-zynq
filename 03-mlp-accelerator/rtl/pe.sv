`timescale 1ns / 1ps

// Output-stationary processing element. The left and top operands are registered and passed on to
// the right and bottom neighbors, their product is registered (mul_reg), and the product is added
// to this PE's own accumulator, which keeps its partial sum across k-tiles; clear starts a new
// sum. In drain mode the accumulators instead shift down one PE per clock toward post_proc.
module pe (
    input  wire               clk,
    input  wire               resetn,

    input  wire               en,           // enable computation
    input  wire               drain,        // shift the accumulator down instead of accumulating
    input  wire               clear,        // start a new sum (first k-tile)

    input  wire signed [7:0]  left_in,      // from the left neighbor
    input  wire signed [7:0]  top_in,       // from the top neighbor
    input  wire signed [31:0] acc_in,       // from the PE above (drain path)

    output wire signed [7:0]  right_out,    // to the right neighbor
    output wire signed [7:0]  bottom_out,   // to the bottom neighbor
    output wire signed [31:0] acc_out       // to the PE below, or the post-processor
);

    logic signed [7:0]  left_reg;    // registered left operand
    logic signed [7:0]  top_reg;     // registered top operand
    logic signed [15:0] mul_reg;     // registered product: separates multiply and accumulate
    logic signed [31:0] acc;         // partial sum

    wire signed [15:0] mul;          // 8 x 8 product
    wire signed [31:0] signed_mul;   // product sign-extended to 32 bits

    assign mul        = left_reg * top_reg;
    assign signed_mul = {{16{mul_reg[15]}}, mul_reg};

    assign right_out  = left_reg;
    assign bottom_out = top_reg;
    assign acc_out    = acc;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            left_reg <= 8'sd0;
            top_reg  <= 8'sd0;
            mul_reg  <= 16'sd0;
            acc      <= 32'sd0;
        end else if (en) begin
            if (drain) begin
                acc <= acc_in;                  // drain: take the partial sum from above
            end else begin
                left_reg <= left_in;            // compute: multiply-accumulate
                top_reg  <= top_in;
                mul_reg  <= mul;
                if (clear)
                    acc <= signed_mul;          // first k-tile: start the sum
                else
                    acc <= acc + signed_mul;    // later k-tiles: accumulate
            end
        end
    end

endmodule
