`timescale 1ns / 1ps

// Feeds one tile pair into the PE array along its diagonals. Row i of tile A enters PE row i at
// the left edge and column i of tile B enters PE column i at the top edge, starting i clocks after
// row and column 0, so the operands that must meet in a PE arrive in the same cycle; outside its
// window an edge input is driven with 0. A run lasts 3 * SIZE clocks and ends with a done pulse;
// pe_clear is raised at the start of a run on the first k-tile.
module skewer #(
    parameter int SIZE = 16
)(
    input  wire               clk,
    input  wire               resetn,

    input  wire               run,           // start a run
    input  wire               first_tile,    // first k-tile: raise pe_clear

    input  wire signed [7:0]  tile_A [0:SIZE-1][0:SIZE-1],   // input feature tile
    input  wire signed [7:0]  tile_B [0:SIZE-1][0:SIZE-1],   // weight tile

    output logic signed [7:0] left_out [0:SIZE-1],           // staggered tile A rows
    output logic signed [7:0] top_out  [0:SIZE-1],           // staggered tile B columns
    output logic              pe_en,                         // enable PE computation
    (* max_fanout = 256 *)
    output logic              pe_clear,     // replicated to cut broadcast routing delay

    output logic              busy,         // run in progress
    output logic              done          // run complete
);

    localparam int TOTAL = 3 * SIZE;            // run length: 48 clocks
    localparam int TBITS = $clog2(TOTAL + 1);   // counts 0-48

    logic [TBITS-1:0] t;          // position in the run
    logic [TBITS-1:0] t_next;

    assign t_next = t + 1'b1;

    // Edge input i carries element (t_next - i) of its row or column while
    // i <= t_next < i + SIZE, and 0 otherwise, which staggers the rows and columns.
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            t        <= '0;
            busy     <= 1'b0;
            pe_en    <= 1'b0;
            pe_clear <= 1'b0;
            done     <= 1'b0;

            for (int i = 0; i < SIZE; i++) begin
                left_out[i] <= 8'sd0;
                top_out[i]  <= 8'sd0;
            end
        end else begin
            done     <= 1'b0;
            pe_clear <= 1'b0;

            if (run && !busy) begin
                // start: only row and column 0 get their first element
                t        <= '0;
                busy     <= 1'b1;
                pe_en    <= 1'b1;
                pe_clear <= first_tile;

                for (int i = 0; i < SIZE; i++) begin
                    if (i == 0) begin
                        left_out[i] <= tile_A[i][0];
                        top_out[i]  <= tile_B[0][i];
                    end else begin
                        left_out[i] <= 8'sd0;
                        top_out[i]  <= 8'sd0;
                    end
                end

            end else if (busy) begin
                if (t == TBITS'(TOTAL - 1)) begin
                    // the last diagonal has been sent: finish the run
                    t     <= '0;
                    busy  <= 1'b0;
                    pe_en <= 1'b0;
                    done  <= 1'b1;

                    for (int i = 0; i < SIZE; i++) begin
                        left_out[i] <= 8'sd0;
                        top_out[i]  <= 8'sd0;
                    end

                end else begin
                    t <= t + 1'b1;

                    for (int i = 0; i < SIZE; i++) begin
                        if ((t_next >= TBITS'(i)) &&
                            (t_next < TBITS'(i + SIZE))) begin
                            left_out[i] <= tile_A[i][t_next - TBITS'(i)];   // row i, col t_next-i
                            top_out[i]  <= tile_B[t_next - TBITS'(i)][i];   // row t_next-i, col i
                        end else begin
                            left_out[i] <= 8'sd0;
                            top_out[i]  <= 8'sd0;
                        end
                    end
                end

            end else begin
                pe_en <= 1'b0;

                for (int i = 0; i < SIZE; i++) begin
                    left_out[i] <= 8'sd0;
                    top_out[i]  <= 8'sd0;
                end
            end
        end
    end

endmodule
