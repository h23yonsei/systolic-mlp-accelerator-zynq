`timescale 1ns / 1ps

// Testbench for the FP32 multiplier. Each line of vectors/fp32_vectors.hex holds two operands and
// their expected product in hex, written by reference/fp32_reference.py: the ten cases this
// testbench started with, the special cases (zeros, infinities, NaNs, subnormal operands, overflow,
// underflow, the rounding carry and ties to even) and random operands over the whole exponent
// range. Every result is compared bit for bit, except that any NaN matches any NaN. Prints
// ALL PASSED with the vector count, or the first mismatches and FAILED.
//
// The vector file is opened from the simulator's working directory; tools/run_sims.py copies it
// there. Override the path with -d VECTOR_FILE=... (xvlog) or -DVECTOR_FILE=... (iverilog).
`ifndef VECTOR_FILE
  `define VECTOR_FILE "fp32_vectors.hex"
`endif

module tb_fp32_multiplier;

    logic [31:0] a, b, expected;
    wire  [31:0] result;

    logic [31:0] file_a, file_b, file_expected;
    int fd;
    int count  = 0;
    int errors = 0;

    fp32_multiplier dut (
        .a(a),
        .b(b),
        .result(result)
    );

    function automatic bit is_nan(input logic [31:0] x);
        return (x[30:23] == 8'hFF) && (x[22:0] != 23'd0);
    endfunction

    initial begin
        fd = $fopen(`VECTOR_FILE, "r");
        if (fd == 0) begin
            $display("---- FAILED: cannot open %s ----", `VECTOR_FILE);
            $finish;
        end

        // one vector per line: a, b, expected product
        while ($fscanf(fd, "%h %h %h\n", file_a, file_b, file_expected) == 3) begin
            a        = file_a;
            b        = file_b;
            expected = file_expected;
            #1;
            if (!(result === expected || (is_nan(result) && is_nan(expected)))) begin
                errors++;
                if (errors <= 10)
                    $display("FAIL[%0d] %h * %h = %h, expected %h", count, a, b, result, expected);
            end
            count++;
        end
        $fclose(fd);

        if (count == 0)
            $display("---- FAILED: no vectors in %s ----", `VECTOR_FILE);
        else if (errors == 0)
            $display("---- ALL PASSED: %0d vectors ----", count);
        else
            $display("---- FAILED: %0d of %0d vectors ----", errors, count);
        $finish;
    end

endmodule
