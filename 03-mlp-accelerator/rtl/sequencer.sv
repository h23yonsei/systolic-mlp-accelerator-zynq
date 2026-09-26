`timescale 1ns / 1ps

// Layer and tile controller of the MLP accelerator. For each of the four weight matrices it loads
// 16x16 tiles of the layer input (BRAM port A) and of the weights (port B), hands each tile pair to
// the skewer, and walks the k-tiles of one weight-tile row while the PE accumulators carry the
// partial sums. After the last k-tile it drains the accumulators through post_proc and writes the
// 16 requantized rows back to BRAM, where they form the next layer's input. o_PROC_DONE pulses
// once the last layer has been written.
module sequencer (
    input  wire                i_CLK,
    input  wire                i_RST_n,

    input  wire                i_PROC_START,
    output logic               o_PROC_DONE,

    // BRAM port A: read inputs, write results
    output logic [13:0]        o_PA_ADDR,
    output logic               o_PA_WR,
    output logic [127:0]       o_PA_WDATA,
    input  wire  [127:0]       i_PA_RDATA,
    input  wire                i_PA_BUSY,

    // BRAM port B: read weights
    output logic [13:0]        o_PB_ADDR,
    input  wire  [127:0]       i_PB_RDATA,

    // PE array; the enables are replicated to cut broadcast routing delay
    (* max_fanout = 256 *)
    output logic               o_PE_EN,         // tile computation (with the skewer) or drain
    output logic               o_PE_CLEAR,      // start new sums on the first k-tile
    (* max_fanout = 256 *)
    output logic               o_PE_DRAIN,      // shift the accumulators to the post-processor
    output logic signed [7:0]  o_LEFT [0:15],   // tile A rows into the array
    output logic signed [7:0]  o_TOP  [0:15],   // tile B columns into the array

    // post-processor
    output logic               o_PP_VALID,      // latch post-processor samples
    output logic [31:0]        o_PP_SCALER,     // per-layer quantization scale factor
    input  wire                i_PP_VALID,      // result ready, 3 cycles after o_PP_VALID
    input  wire signed [7:0]   i_PP_DATA [0:15] // requantized int8 values
);

    localparam int unsigned TOTAL_LAYERS  = 4;    // weight matrices, one GEMM each
    localparam int unsigned BATCH_SIZE    = 16;   // input samples, fixed to the tile size
    localparam int unsigned SYSTOLIC_SIZE = 16;   // the PE array is 16x16

    localparam int unsigned W_DIMS [TOTAL_LAYERS][2] = '{
        //  rows  cols
        '{128,  768},   // layer 0: 128x768 weights
        '{128,  128},   // layer 1: 128x128 weights
        '{128,  128},   // layer 2: 128x128 weights
        '{16,   128}    // layer 3: 16x128 weights (output layer)
    };

    // Input dimensions of a layer: the rows are the batch; the columns are layer 0's weight
    // columns, or the previous layer's weight rows.
    function automatic int unsigned calc_idim(int unsigned layer, dim);
        if (dim == 0)       return BATCH_SIZE;
        else begin
            if (layer == 0) return W_DIMS[0][1];
            else            return W_DIMS[layer-1][0];
        end
    endfunction

    localparam int unsigned I_DIMS [TOTAL_LAYERS+1][2] = '{
        //  rows            cols
        '{calc_idim(0,0), calc_idim(0,1)},
        '{calc_idim(1,0), calc_idim(1,1)},
        '{calc_idim(2,0), calc_idim(2,1)},
        '{calc_idim(3,0), calc_idim(3,1)},
        '{calc_idim(4,0), calc_idim(4,1)}   // extra entry: the output of layer 3
    };

    // BRAM base addresses of each layer's weights, input and output
    localparam int unsigned W_BADDR [TOTAL_LAYERS] =
        '{32'h0000_0000, 32'h0000_1800, 32'h0000_1C00, 32'h0000_2000};
    localparam int unsigned I_BADDR [TOTAL_LAYERS] =
        '{32'h0000_2400, 32'h0000_2700, 32'h0000_2780, 32'h0000_2800};
    localparam int unsigned O_BADDR [TOTAL_LAYERS] =
        '{I_BADDR[1], I_BADDR[2], I_BADDR[3], 32'h0000_2880};

    // per-layer requantization scale factors
    localparam int unsigned PP_SCALER [TOTAL_LAYERS] =
        '{32'h0017_B92F, 32'h005E_4B3A, 32'h0502_1F6A, 32'hFFFF_FFFF};

    logic signed [7:0] tile_A [0:15][0:15];   // input feature tile
    logic signed [7:0] tile_B [0:15][0:15];   // weight tile

    logic skew_run;          // start the skewer
    logic skew_first_tile;   // first k-tile: clear the accumulators
    logic skew_pe_en;        // PE enable from the skewer
    logic skew_pe_clear;     // PE clear from the skewer
    logic skew_busy;         // skewer running
    logic skew_done;         // skewer finished the tile pair

    skewer #(.SIZE(SYSTOLIC_SIZE)) u_skewer (
        .clk        (i_CLK),
        .resetn     (i_RST_n),
        .run        (skew_run),
        .first_tile (skew_first_tile),
        .tile_A     (tile_A),
        .tile_B     (tile_B),
        .left_out   (o_LEFT),
        .top_out    (o_TOP),
        .pe_en      (skew_pe_en),
        .pe_clear   (skew_pe_clear),
        .busy       (skew_busy),
        .done       (skew_done)
    );

    logic ctrl_drain_en;     // PE enable during the drain phase

    assign o_PE_EN    = skew_pe_en | ctrl_drain_en;
    assign o_PE_CLEAR = skew_pe_clear;

    localparam logic [3:0] S_IDLE   = 4'd0,
                           S_L_INIT = 4'd1,   // initialize the layer's parameters and addresses
                           S_W_INIT = 4'd2,   // initialize a weight-tile row
                           S_LOAD   = 4'd3,   // load a tile pair from BRAM (16 cycles)
                           S_SKEW   = 4'd4,   // the skewer feeds the tile pair to the PEs
                           S_FLUSH  = 4'd5,   // 2-cycle gap after the skew
                           S_DRAIN  = 4'd6,   // drain the accumulators row by row
                           S_W_NEXT = 4'd7,   // next weight-tile row of the same layer
                           S_L_NEXT = 4'd8,   // next layer
                           S_DONE   = 4'd9;   // all layers done

    logic [3:0] state, next_state;

    logic [1:0]  layer;        // current layer, 0-3
    logic [3:0]  w_tile;       // weight-tile row within the layer
    logic [5:0]  k_tile;       // k-tile within the weight-tile row
    logic [4:0]  cnt;          // load and flush counter

    logic [5:0]  n_k;          // k-tiles per weight-tile row (weight columns / 16)
    logic [3:0]  n_w;          // weight-tile rows (weight rows / 16)
    logic [13:0] b_w_stride;   // BRAM stride from one weight-tile row to the next

    // BRAM addresses
    logic [13:0] cur_a_base;
    logic [13:0] cur_a_addr;
    logic [13:0] cur_b_w_base;
    logic [13:0] cur_b_addr;
    logic [13:0] cur_o_addr;

    logic [4:0]  drain_cnt;    // drain and write-back cycles
    logic [4:0]  write_row;    // output row being written

    logic [127:0] pp_word;     // the 16 int8 post-processor outputs packed into one BRAM word

    always @(*) begin
        for (int c = 0; c < 16; c++)
            pp_word[c*8 +: 8] = i_PP_DATA[c];
    end

    // next state
    always @(*) begin
        next_state = state;

        case (state)
            S_IDLE: begin
                if (i_PROC_START)
                    next_state = S_L_INIT;
            end

            S_L_INIT: begin
                next_state = S_W_INIT;
            end

            S_W_INIT: begin
                next_state = S_LOAD;
            end

            S_LOAD: begin
                if (cnt == 5'd16)               // all 16 rows of the tile pair loaded
                    next_state = S_SKEW;
            end

            S_SKEW: begin
                if (skew_done)
                    next_state = S_FLUSH;       // gap so every PE finishes before a drain
            end

            S_FLUSH: begin
                if (cnt == 5'd1) begin          // after 2 cycles
                    if (k_tile == n_k - 6'd1)
                        next_state = S_DRAIN;   // last k-tile: drain to the post-processor
                    else
                        next_state = S_LOAD;    // load the next tile pair
                end
            end

            S_DRAIN: begin
                if (drain_cnt == 5'd18)         // 16 drain cycles + 2 for the BRAM writes
                    next_state = S_W_NEXT;
            end

            S_W_NEXT: begin
                if (w_tile == n_w - 4'd1)
                    next_state = S_L_NEXT;      // last weight-tile row: next layer
                else
                    next_state = S_W_INIT;      // next weight-tile row of this layer
            end

            S_L_NEXT: begin
                if (layer == 2'd3)
                    next_state = S_DONE;
                else
                    next_state = S_L_INIT;
            end

            S_DONE: begin
                next_state = S_IDLE;
            end

            default: begin
                next_state = S_IDLE;
            end
        endcase
    end

    always @(posedge i_CLK or negedge i_RST_n) begin
        if (!i_RST_n) begin
            state <= S_IDLE;
        end else begin
            state <= next_state;
        end
    end

    always @(posedge i_CLK or negedge i_RST_n) begin
        if (!i_RST_n) begin
            layer           <= '0;
            w_tile          <= '0;
            k_tile          <= '0;
            cnt             <= '0;
            drain_cnt       <= '0;
            write_row       <= '0;

            cur_a_base      <= '0;
            cur_a_addr      <= '0;
            cur_b_w_base    <= '0;
            cur_b_addr      <= '0;
            cur_o_addr      <= '0;

            o_PROC_DONE     <= 1'b0;
            o_PA_ADDR       <= '0;
            o_PA_WR         <= 1'b0;
            o_PA_WDATA      <= '0;
            o_PB_ADDR       <= '0;
            o_PE_DRAIN      <= 1'b0;
            o_PP_VALID      <= 1'b0;
            o_PP_SCALER     <= '0;

            ctrl_drain_en   <= 1'b0;
            skew_run        <= 1'b0;
            skew_first_tile <= 1'b0;

            n_k             <= '0;
            n_w             <= '0;
            b_w_stride      <= '0;

        end else begin
            // defaults; the states below override them
            o_PROC_DONE <= 1'b0;
            o_PA_WR     <= 1'b0;
            skew_run    <= 1'b0;

            case (state)

                S_IDLE: begin
                    o_PE_DRAIN    <= 1'b0;
                    o_PP_VALID    <= 1'b0;
                    ctrl_drain_en <= 1'b0;

                    if (i_PROC_START) begin
                        layer <= 2'd0;
                    end
                end

                S_L_INIT: begin
                    cur_a_base   <= 14'(I_BADDR[layer]);    // layer input
                    cur_a_addr   <= 14'(I_BADDR[layer]);
                    cur_b_w_base <= 14'(W_BADDR[layer]);    // layer weights
                    cur_b_addr   <= 14'(W_BADDR[layer]);
                    cur_o_addr   <= 14'(O_BADDR[layer]);    // layer output
                    o_PP_SCALER  <= PP_SCALER[layer];

                    w_tile       <= '0;
                    n_k          <= 6'(W_DIMS[layer][1] >> 4);
                    n_w          <= 4'(W_DIMS[layer][0] >> 4);
                    b_w_stride   <= 14'(W_DIMS[layer][1]);
                end

                S_W_INIT: begin
                    k_tile     <= '0;
                    cur_a_addr <= cur_a_base;
                    cur_b_addr <= cur_b_w_base;
                    cnt        <= '0;

                    // address the first tile pair, loaded in the next state
                    o_PA_ADDR  <= cur_a_base;
                    o_PB_ADDR  <= cur_b_w_base;
                end

                S_LOAD: begin
                    // prefetch: address the next word while this one is read
                    if (cnt < 5'd15) begin
                        o_PA_ADDR <= cur_a_addr + 14'(cnt + 1);
                        o_PB_ADDR <= cur_b_addr + 14'(cnt + 1);
                    end

                    // capture one cycle later, after the BRAM read latency
                    if (cnt >= 5'd1) begin
                        for (int k = 0; k < 16; k++) begin
                            tile_A[cnt-1][k] <= signed'(i_PA_RDATA[k*8 +: 8]);
                            tile_B[k][cnt-1] <= signed'(i_PB_RDATA[k*8 +: 8]);
                        end
                    end

                    cnt <= cnt + 1'b1;

                    // 16th row captured: start the skewer in the next cycle
                    if (cnt == 5'd16) begin
                        cnt             <= '0;
                        skew_run        <= 1'b1;
                        skew_first_tile <= (k_tile == '0);
                    end
                end

                S_SKEW: begin
                    if (skew_done) begin
                        cnt <= '0;
                    end
                end

                S_FLUSH: begin
                    cnt <= cnt + 1'b1;

                    if (cnt == 5'd1) begin
                        cnt <= '0;

                        if (k_tile == n_k - 1) begin
                            // last k-tile: start draining the accumulators
                            o_PE_DRAIN    <= 1'b1;
                            ctrl_drain_en <= 1'b1;
                            o_PP_VALID    <= 1'b1;
                            drain_cnt     <= '0;
                            write_row     <= 5'd15;

                        end else begin
                            // next k-tile: advance and address the next tile pair
                            k_tile     <= k_tile + 1'b1;
                            cur_a_addr <= cur_a_addr + 14'd16;
                            cur_b_addr <= cur_b_addr + 14'd16;

                            o_PA_ADDR  <= cur_a_addr + 14'd16;
                            o_PB_ADDR  <= cur_b_addr + 14'd16;
                        end
                    end
                end

                S_DRAIN: begin
                    drain_cnt <= drain_cnt + 1'b1;

                    if (drain_cnt < 5'd15) begin              // cycles 0-14: keep draining
                        o_PE_DRAIN    <= 1'b1;
                        ctrl_drain_en <= 1'b1;
                        o_PP_VALID    <= 1'b1;
                    end else if (drain_cnt == 5'd15) begin    // cycle 15: stop
                        o_PE_DRAIN    <= 1'b0;
                        ctrl_drain_en <= 1'b0;
                        o_PP_VALID    <= 1'b0;
                    end

                    // Write each post-processor result when port A is free. The array drains
                    // its bottom row (row 15) first, so the rows are written from 15 down to 0.
                    if (i_PP_VALID && !i_PA_BUSY) begin
                        o_PA_ADDR  <= cur_o_addr + 14'(write_row);
                        o_PA_WR    <= 1'b1;
                        o_PA_WDATA <= pp_word;

                        if (write_row != 5'd0)
                            write_row <= write_row - 1'b1;
                    end
                end

                S_W_NEXT: begin
                    if (w_tile != n_w - 1) begin
                        w_tile       <= w_tile + 1'b1;
                        cur_b_w_base <= cur_b_w_base + b_w_stride;   // next weight-tile row
                        cur_o_addr   <= cur_o_addr + 14'd16;         // its output rows
                    end
                end

                S_L_NEXT: begin
                    if (layer != 2'd3) begin
                        layer <= layer + 1'b1;
                    end
                end

                S_DONE: begin
                    o_PROC_DONE <= 1'b1;
                end

                default: begin
                end

            endcase
        end
    end

endmodule
