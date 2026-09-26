`timescale 1ns / 1ps

// Integration test for the MLP accelerator: the full four-layer inference on the 16 clips in
// rtl/bram_init.hex, with the AXI bus idle. When o_PROC_DONE rises, all 256 bytes of the final
// output are compared with the NumPy reference (reference/mlp_reference.py), and the argmax of each
// clip's nine valid logits with the reference prediction. A watchdog fails the run if the
// sequencer never finishes.
module tb_mlp_top;

    logic clk, resetn, proc_start, proc_done;

    // clock: 10 ns period
    initial clk = 0;
    always #5 clk = ~clk;

    mlp_top dut (
        .i_CLK          (clk),
        .i_RST_n        (resetn),

        .i_PROC_START   (proc_start),
        .o_PROC_DONE    (proc_done),

        // AXI bus idle
        .S_AXI_ARESETN  (resetn),
        .S_AXI_AWADDR   (32'd0),
        .S_AXI_AWVALID  (1'b0),
        .S_AXI_AWREADY  (),
        .S_AXI_WDATA    (32'd0),
        .S_AXI_WSTRB    (4'd0),
        .S_AXI_WVALID   (1'b0),
        .S_AXI_WREADY   (),
        .S_AXI_BRESP    (),
        .S_AXI_BVALID   (),
        .S_AXI_BREADY   (1'b1),
        .S_AXI_ARADDR   (32'd0),
        .S_AXI_ARVALID  (1'b0),
        .S_AXI_ARREADY  (),
        .S_AXI_RDATA    (),
        .S_AXI_RRESP    (),
        .S_AXI_RVALID   (),
        .S_AXI_RREADY   (1'b1)
    );

    // Expected final output from reference/mlp_reference.py (X5_int8): 16 clips x 16 columns, of
    // which only columns 0-8 are valid logits.
    localparam int OUT_BASE = 14'h2880;

    localparam logic signed [7:0] GOLDEN [0:15][0:15] = '{
        '{ 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        '{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        '{ 5, 0, 5, 5,15, 2, 6, 5,12, 0, 0, 0, 0, 0, 0, 0},
        '{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        '{ 7, 1, 0, 0, 7, 0, 5, 0,14, 0, 0, 0, 0, 0, 0, 0},
        '{ 0, 0,10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        '{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        '{ 6, 0, 6, 6,18, 1, 3, 6,13, 0, 0, 0, 0, 0, 0, 0},
        '{ 0,12,21, 0,10, 6, 6,15,12, 0, 0, 0, 0, 0, 0, 0},
        '{ 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        '{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        '{ 0, 5, 9, 0, 1, 4, 0,11, 4, 0, 0, 0, 0, 0, 0, 0},
        '{ 0, 0, 4, 2,18, 9,11, 4, 5, 0, 0, 0, 0, 0, 0, 0},
        '{ 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        '{14, 0, 0, 2, 6, 0, 0, 0,14, 0, 0, 0, 0, 0, 0, 0},
        '{ 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
    };

    // reference argmax over the valid logits (columns 0-8); an all-zero row resolves to class 0
    localparam int EXP_PRED [0:15] =
        '{5, 0, 4, 0, 8, 2, 0, 4, 2, 3, 0, 7, 4, 1, 0, 2};

    string CLASS_NAME [0:8] =
        '{"one", "two", "three", "four", "five", "six", "seven", "eight", "nine"};

    // hardware output for one clip (BRAM row) and column (byte lane)
    function automatic logic signed [7:0] hw_out(input int row, input int col);
        logic [127:0] w;
        w = dut.u_bram.mem[OUT_BASE + row];
        return signed'(w[col*8 +: 8]);
    endfunction

    // argmax over the valid logits (columns 0-8); a tie takes the lowest index, as NumPy does
    function automatic int argmax9(input int row);
        int best_idx;
        logic signed [7:0] best_val;
        best_idx = 0;
        best_val = hw_out(row, 0);
        for (int c = 1; c < 9; c++)
            if (hw_out(row, c) > best_val) begin
                best_val = hw_out(row, c);
                best_idx = c;
            end
        return best_idx;
    endfunction

    // print a 16x16 BRAM region
    task automatic dump_region(input [13:0] base, input string label);
        logic [127:0] w;
        $display("--- %s  (base 0x%04h) ---", label, base);
        for (int row = 0; row < 16; row++) begin
            w = dut.u_bram.mem[base + row];
            $write("  row %2d:", row);
            for (int c = 0; c < 16; c++)
                $write(" %4d", $signed(w[c*8 +: 8]));
            $write("\n");
        end
    endtask

    // every layer writes its own output region, so all of them survive to the end of the run
    task automatic dump_output;
        dump_region(14'h2700, "Layer 0 output");
        dump_region(14'h2780, "Layer 1 output");
        dump_region(14'h2800, "Layer 2 output");
        dump_region(14'h2880, "Layer 3 output (final)");
    endtask

    // byte-for-byte check against the reference, then the prediction check
    task automatic check_output;
        int byte_errs = 0;
        int pred_errs = 0;
        $display("--- Full-output byte check vs numpy golden ---");
        for (int row = 0; row < 16; row++)
            for (int c = 0; c < 16; c++)
                if (hw_out(row, c) !== GOLDEN[row][c]) begin
                    $display("  BYTE MISMATCH clip %0d col %0d: hw=%0d golden=%0d",
                             row+1, c, hw_out(row, c), GOLDEN[row][c]);
                    byte_errs++;
                end
        if (byte_errs == 0) $display("  byte check: PASS (all 256 bytes match)");
        else                $display("  byte check: FAIL (%0d mismatches)", byte_errs);

        $display("--- Prediction check (argmax over cols 0..8) ---");
        for (int row = 0; row < 16; row++) begin
            automatic int p = argmax9(row);
            if (p !== EXP_PRED[row]) begin
                $display("  PRED MISMATCH clip %0d: hw=%0d(%s) exp=%0d(%s)",
                         row+1, p, CLASS_NAME[p], EXP_PRED[row], CLASS_NAME[EXP_PRED[row]]);
                pred_errs++;
            end else begin
                $display("  clip %2d: %-6s (class %0d) OK", row+1, CLASS_NAME[p], p);
            end
        end

        $display("========================================");
        if (byte_errs == 0 && pred_errs == 0)
            $display(" INTEGRATION TEST: PASS");
        else
            $display(" INTEGRATION TEST: FAIL (%0d byte, %0d pred errors)",
                     byte_errs, pred_errs);
        $display("========================================");
    endtask

    // Instrumentation: cycles with the PE array enabled, BRAM write-backs (about 400), and the
    // first writes and post-processor samples, to show real values reached requantization.
    int pe_en_cycles = 0;
    int wr_count     = 0;
    int pp_seen      = 0;

    always @(posedge clk) begin
        if (resetn) begin
            if (dut.pe_en) pe_en_cycles++;

            if (dut.pa_wr) begin
                wr_count++;
                if (wr_count <= 20)
                    $display("[WR %3d] addr=0x%04h data[0..3]= %0d %0d %0d %0d",
                             wr_count, dut.pa_addr,
                             $signed(dut.pa_wdata[7:0]), $signed(dut.pa_wdata[15:8]),
                             $signed(dut.pa_wdata[23:16]), $signed(dut.pa_wdata[31:24]));
            end

            if (dut.pp_valid_out && pp_seen < 4) begin
                pp_seen++;
                $display("[PP %0d] acc_out[0..3]= %0d %0d %0d %0d   pp_data[0..3]= %0d %0d %0d %0d",
                         pp_seen,
                         dut.acc_out_bus[0], dut.acc_out_bus[1],
                         dut.acc_out_bus[2], dut.acc_out_bus[3],
                         dut.pp_data[0], dut.pp_data[1],
                         dut.pp_data[2], dut.pp_data[3]);
            end
        end
    end

    // watchdog: a full run is about 35k cycles; fail instead of hanging if done never rises
    initial begin
        #2_000_000;   // 2 ms = 200k cycles
        $display("TIMEOUT: o_PROC_DONE never asserted -- sequencer stalled");
        $finish;
    end

    initial begin
        resetn     = 1'b0;
        proc_start = 1'b0;

        repeat (32) @(posedge clk);
        resetn = 1'b1;

        @(posedge clk);
        proc_start = 1'b1;
        @(posedge clk);
        proc_start = 1'b0;

        wait (proc_done);
        $display("========================================");
        $display(" o_PROC_DONE asserted -- run complete");
        $display("========================================");
        repeat (16) @(posedge clk);

        $display("--- Instrumentation summary ---");
        $display("  pe_en cycles : %0d (expect thousands)", pe_en_cycles);
        $display("  RTL writes   : %0d (expect ~400)", wr_count);

        dump_output;
        check_output;

        $finish;
    end

endmodule
