`timescale 1ns / 1ps

// Combinational IEEE 754 single-precision multiplier. The sign is the XOR of the input signs, the
// exponents are added and rebiased, and the two 24-bit mantissas (with their implicit leading 1)
// are multiplied into 48 bits, normalized by at most one position and rounded to nearest, ties to
// even.
//
// Special values follow IEEE 754: a NaN operand, or infinity times zero, gives a quiet NaN;
// infinity times any other value gives infinity; a product too large for the format overflows to
// infinity. Subnormals are not implemented: a subnormal operand is read as zero, and a product
// whose exponent after rounding is below the normal range is flushed to zero. Zeros and flushed
// results keep the product's sign.
module fp32_multiplier (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [31:0] result
);

    // sign, exponent, mantissa
    wire        sign_a = a[31],    sign_b = b[31];
    wire [7:0]  exp_a  = a[30:23], exp_b  = b[30:23];
    wire [22:0] mant_a = a[22:0],  mant_b = b[22:0];

    wire sign_out = sign_a ^ sign_b;

    // operand classes; exponent 0 is zero or a subnormal, both read as zero
    wire zero_a = (exp_a == 8'd0);
    wire zero_b = (exp_b == 8'd0);
    wire inf_a  = (exp_a == 8'hFF) && (mant_a == 23'd0);
    wire inf_b  = (exp_b == 8'hFF) && (mant_b == 23'd0);
    wire nan_a  = (exp_a == 8'hFF) && (mant_a != 23'd0);
    wire nan_b  = (exp_b == 8'hFF) && (mant_b != 23'd0);

    // mantissa product
    wire [23:0] num_a = {1'b1, mant_a};
    wire [23:0] num_b = {1'b1, mant_b};
    wire [47:0] prod  = num_a * num_b;

    // normalize: a product in [2, 4) is shifted right once and its exponent incremented
    wire        shift  = prod[47];
    wire [23:0] kept   = shift ? prod[47:24] : prod[46:23];    // leading 1 and 23 mantissa bits
    wire        guard  = shift ? prod[23]    : prod[22];       // first dropped bit
    wire        sticky = shift ? |prod[22:0] : |prod[21:0];    // any later dropped bit

    // round to nearest, ties to even. Rounding 1.11...1 up carries into a new leading bit: the
    // mantissa becomes 1.0 and the exponent is incremented once more.
    wire        round_up = guard && (sticky || kept[0]);
    wire [24:0] rounded  = {1'b0, kept} + {24'd0, round_up};
    wire        carry    = rounded[24];

    // exponent sum still carrying both biases (2..510); the result exponent is exp_sum - 127
    wire [9:0] exp_sum = {2'b0, exp_a} + {2'b0, exp_b} + {9'd0, shift} + {9'd0, carry};
    wire [9:0] exp_out = exp_sum - 10'd127;

    reg [7:0]  final_exp;
    reg [22:0] final_mant;

    always @(*) begin
        if (nan_a || nan_b || (inf_a && zero_b) || (zero_a && inf_b)) begin
            // NaN, returned as the canonical quiet NaN
            final_exp  = 8'hFF;
            final_mant = 23'h400000;
        end else if (inf_a || inf_b) begin
            // infinity times a nonzero value
            final_exp  = 8'hFF;
            final_mant = 23'd0;
        end else if (zero_a || zero_b) begin
            // zero times a finite value
            final_exp  = 8'd0;
            final_mant = 23'd0;
        end else if (exp_sum >= 10'd382) begin
            // result exponent 255 or more: overflow to infinity
            final_exp  = 8'hFF;
            final_mant = 23'd0;
        end else if (exp_sum <= 10'd127) begin
            // result exponent 0 or less: below the normal range, flushed to zero
            final_exp  = 8'd0;
            final_mant = 23'd0;
        end else begin
            final_exp  = exp_out[7:0];
            final_mant = rounded[22:0];                    // zero after a rounding carry
        end
    end

    assign result = {sign_out, final_exp, final_mant};

endmodule
