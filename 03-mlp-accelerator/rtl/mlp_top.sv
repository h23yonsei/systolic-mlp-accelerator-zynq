`timescale 1ns / 1ps

// Top level of the MLP accelerator: the shared block RAM with its AXI4-Lite access (bram_tdp),
// the sequencer, and the systolic core (PE array and post-processor). The port list and the
// bram_tdp module come from the course skeleton; the port names are the interface that
// mlp_axi_wrapper and the block design connect to.
module mlp_top (
    input   wire                    i_CLK,
    input   wire                    i_RST_n,

    input   wire                    i_PROC_START,
    output  logic                   o_PROC_DONE,

    input   wire                    S_AXI_ARESETN,
    input   wire    [31:0]          S_AXI_AWADDR,
    input   wire                    S_AXI_AWVALID,
    output  logic                   S_AXI_AWREADY,
    input   wire    [31:0]          S_AXI_WDATA,
    input   wire    [3:0]           S_AXI_WSTRB,
    input   wire                    S_AXI_WVALID,
    output  logic                   S_AXI_WREADY,
    output  wire    [1:0]           S_AXI_BRESP,
    output  logic                   S_AXI_BVALID,
    input   wire                    S_AXI_BREADY,
    input   wire    [31:0]          S_AXI_ARADDR,
    input   wire                    S_AXI_ARVALID,
    output  logic                   S_AXI_ARREADY,
    output  logic   [31:0]          S_AXI_RDATA,
    output  wire    [1:0]           S_AXI_RRESP,
    output  logic                   S_AXI_RVALID,
    input   wire                    S_AXI_RREADY
);

    // BRAM port A (sequencer reads inputs, writes results) and port B (weights)
    logic [13:0]        pa_addr;
    logic               pa_wr;
    logic [127:0]       pa_wdata;
    logic [127:0]       pa_rdata;
    logic               pa_busy;

    logic [13:0]        pb_addr;
    logic [127:0]       pb_rdata;

    // PE array control and edge inputs
    logic               pe_en;
    logic               pe_clear;
    logic               pe_drain;

    logic signed [7:0]  left_bus [0:15];
    logic signed [7:0]  top_bus  [0:15];

    // post-processor
    logic               pp_valid_in;
    logic [31:0]        pp_scaler;
    logic               pp_valid_out;
    logic signed [7:0]  pp_data [0:15];

    wire signed [31:0]  acc_out_bus [0:15];

    bram_tdp #(
        .INIT_FILE          ("bram_init.hex"            )
    ) u_bram (
        // port A: inputs and results, shared with AXI
        .i_PA_ADDR          (pa_addr                    ),
        .i_PA_WR            (pa_wr                      ),
        .i_PA_WDATA         (pa_wdata                   ),
        .o_PA_RDATA         (pa_rdata                   ),
        .o_PA_BUSY          (pa_busy                    ),

        // port B: weights, read only
        .i_PB_ADDR          (pb_addr                    ),
        .i_PB_WR            (1'b0                       ),
        .i_PB_WDATA         (128'd0                     ),
        .o_PB_RDATA         (pb_rdata                   ),

        // AXI4-Lite pass-through
        .i_CLK              (i_CLK                      ),
        .i_RST_n            (S_AXI_ARESETN              ),

        .S_AXI_AWADDR       (S_AXI_AWADDR               ),
        .S_AXI_AWVALID      (S_AXI_AWVALID              ),
        .S_AXI_AWREADY      (S_AXI_AWREADY              ),
        .S_AXI_WDATA        (S_AXI_WDATA                ),
        .S_AXI_WSTRB        (S_AXI_WSTRB                ),
        .S_AXI_WVALID       (S_AXI_WVALID               ),
        .S_AXI_WREADY       (S_AXI_WREADY               ),
        .S_AXI_BRESP        (S_AXI_BRESP                ),
        .S_AXI_BVALID       (S_AXI_BVALID               ),
        .S_AXI_BREADY       (S_AXI_BREADY               ),
        .S_AXI_ARADDR       (S_AXI_ARADDR               ),
        .S_AXI_ARVALID      (S_AXI_ARVALID              ),
        .S_AXI_ARREADY      (S_AXI_ARREADY              ),
        .S_AXI_RDATA        (S_AXI_RDATA                ),
        .S_AXI_RRESP        (S_AXI_RRESP                ),
        .S_AXI_RVALID       (S_AXI_RVALID               ),
        .S_AXI_RREADY       (S_AXI_RREADY               )
    );

    systolic_core u_systolic (
        .clk                (i_CLK                      ),
        .resetn             (i_RST_n                    ),
        .pe_en              (pe_en                      ),
        .pe_clear           (pe_clear                   ),
        .pe_drain           (pe_drain                   ),
        .left_in            (left_bus                   ),
        .top_in             (top_bus                    ),
        .pp_valid_in        (pp_valid_in                ),
        .pp_scaler          (pp_scaler                  ),
        .acc_out            (acc_out_bus                ),
        .pp_valid_out       (pp_valid_out               ),
        .pp_data            (pp_data                    )
    );

    sequencer u_sequencer (
        .i_CLK              (i_CLK                      ),
        .i_RST_n            (i_RST_n                    ),

        .i_PROC_START       (i_PROC_START               ),
        .o_PROC_DONE        (o_PROC_DONE                ),

        .o_PA_ADDR          (pa_addr                    ),
        .o_PA_WR            (pa_wr                      ),
        .o_PA_WDATA         (pa_wdata                   ),
        .i_PA_RDATA         (pa_rdata                   ),
        .i_PA_BUSY          (pa_busy                    ),

        .o_PB_ADDR          (pb_addr                    ),
        .i_PB_RDATA         (pb_rdata                   ),

        .o_PE_EN            (pe_en                      ),
        .o_PE_CLEAR         (pe_clear                   ),
        .o_PE_DRAIN         (pe_drain                   ),
        .o_LEFT             (left_bus                   ),
        .o_TOP              (top_bus                    ),

        .o_PP_VALID         (pp_valid_in                ),
        .o_PP_SCALER        (pp_scaler                  ),
        .i_PP_VALID         (pp_valid_out               ),
        .i_PP_DATA          (pp_data                    )
    );

endmodule


// True dual-port block RAM of 16,384 128-bit words, provided with the course skeleton. Port A is
// shared between the RTL and an AXI4-Lite slave that reads and writes 32-bit lanes of a word; AXI
// has priority, and o_PA_BUSY tells the RTL when AXI owns the port. Port B belongs to the RTL.
module bram_tdp #(
    parameter INIT_FILE = "bram_init.hex"
)(
    input   wire                i_CLK,
    input   wire                i_RST_n,

    // port A: RTL read / write
    input   wire    [13:0]      i_PA_ADDR,
    input   wire                i_PA_WR,
    input   wire    [127:0]     i_PA_WDATA,
    output  logic   [127:0]     o_PA_RDATA,
    output  wire                o_PA_BUSY,      // AXI owns port A this cycle

    // port B: RTL read / write
    input   wire    [13:0]      i_PB_ADDR,
    input   wire                i_PB_WR,
    input   wire    [127:0]     i_PB_WDATA,
    output  logic   [127:0]     o_PB_RDATA,

    // AXI4-Lite slave, 32-bit data
    input   wire    [31:0]      S_AXI_AWADDR,
    input   wire                S_AXI_AWVALID,
    output  logic               S_AXI_AWREADY,
    input   wire    [31:0]      S_AXI_WDATA,
    input   wire    [3:0]       S_AXI_WSTRB,
    input   wire                S_AXI_WVALID,
    output  logic               S_AXI_WREADY,
    output  wire    [1:0]       S_AXI_BRESP,
    output  logic               S_AXI_BVALID,
    input   wire                S_AXI_BREADY,
    input   wire    [31:0]      S_AXI_ARADDR,
    input   wire                S_AXI_ARVALID,
    output  logic               S_AXI_ARREADY,
    output  logic   [31:0]      S_AXI_RDATA,
    output  wire    [1:0]       S_AXI_RRESP,
    output  logic               S_AXI_RVALID,
    input   wire                S_AXI_RREADY
);

    assign S_AXI_BRESP = 2'b00;   // OKAY
    assign S_AXI_RRESP = 2'b00;

    // ---------------------------------------------------------------------------------------------
    // Memory array (Vivado byte-write-enable inference pattern)
    // ---------------------------------------------------------------------------------------------

    (* ram_style = "block" *)
    logic [127:0] mem [0:(1<<14)-1];

    initial $readmemh(INIT_FILE, mem);

    // ---------------------------------------------------------------------------------------------
    // AXI4-Lite write channel
    // ---------------------------------------------------------------------------------------------

    logic         aw_fire, w_fire;
    logic [13:0]  axi_waddr;
    logic [1:0]   axi_wlane;
    logic         axi_wr_pending;   // write data captured, to be written through port A
    logic [15:0]  axi_wbe;          // byte write enables (16 bytes)
    logic [127:0] axi_wdata_128;    // write data placed in its lane of the 128-bit word

    assign aw_fire = S_AXI_AWVALID & S_AXI_AWREADY;
    assign w_fire  = S_AXI_WVALID  & S_AXI_WREADY;

    always_ff @(posedge i_CLK) begin
        if (!i_RST_n) begin
            S_AXI_AWREADY  <= 1'b1;
            S_AXI_WREADY   <= 1'b1;
            S_AXI_BVALID   <= 1'b0;
            axi_wr_pending <= 1'b0;
        end
        else begin
            // accept AW
            if (aw_fire) begin
                axi_waddr     <= S_AXI_AWADDR[17:4];
                axi_wlane     <= S_AXI_AWADDR[3:2];
                S_AXI_AWREADY <= 1'b0;
            end

            // accept W
            if (w_fire) begin
                S_AXI_WREADY <= 1'b0;
            end

            // AW and W both received: issue the write in the next cycle. WDATA and WSTRB are
            // sampled here rather than when W is accepted, so a W beat that arrives before its AW
            // is not stored correctly: this slave relies on the master sending AW no later than W.
            // The PS application (sw/main.c) only reads over AXI, so the design never depends on it.
            if ((!S_AXI_AWREADY || aw_fire) && (!S_AXI_WREADY || w_fire)
                && !axi_wr_pending && !S_AXI_BVALID) begin

                logic [1:0] lane;
                lane = aw_fire ? S_AXI_AWADDR[3:2] : axi_wlane;

                // byte enables and data for the addressed lane
                axi_wbe       <= '0;
                axi_wdata_128 <= '0;
                for (int i = 0; i < 4; i++) begin
                    axi_wbe      [lane*4 + i] <= S_AXI_WSTRB[i];
                    axi_wdata_128[(lane*4 + i)*8 +: 8] <= S_AXI_WDATA[i*8 +: 8];
                end
                axi_wr_pending <= 1'b1;
            end

            // write issued to the BRAM: respond
            if (axi_wr_pending) begin
                axi_wr_pending <= 1'b0;
                S_AXI_BVALID   <= 1'b1;
            end

            // B handshake complete
            if (S_AXI_BVALID && S_AXI_BREADY) begin
                S_AXI_BVALID  <= 1'b0;
                S_AXI_AWREADY <= 1'b1;
                S_AXI_WREADY  <= 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // AXI4-Lite read channel
    // ---------------------------------------------------------------------------------------------

    logic        axi_rd_pending;
    logic        axi_rd_wait;      // extra stage: hold the address for the registered BRAM output
    logic [13:0] axi_raddr;
    logic [1:0]  axi_rlane;

    always_ff @(posedge i_CLK) begin
        if (!i_RST_n) begin
            S_AXI_ARREADY  <= 1'b1;
            S_AXI_RVALID   <= 1'b0;
            axi_rd_pending <= 1'b0;
            axi_rd_wait    <= 1'b0;
        end
        else begin
            // accept AR
            if (S_AXI_ARVALID && S_AXI_ARREADY) begin
                axi_raddr      <= S_AXI_ARADDR[17:4];
                axi_rlane      <= S_AXI_ARADDR[3:2];
                S_AXI_ARREADY  <= 1'b0;
                axi_rd_pending <= 1'b1;
            end

            // Stage 1: axi_raddr now drives the port A address. The registered BRAM output shows
            // this address only after the next rising edge, so o_PA_RDATA still holds the
            // previous address's data and must not be captured yet.
            if (axi_rd_pending) begin
                axi_rd_pending <= 1'b0;
                axi_rd_wait    <= 1'b1;
            end

            // Stage 2: o_PA_RDATA holds the data for axi_raddr; capture its lane and raise RVALID.
            if (axi_rd_wait) begin
                axi_rd_wait  <= 1'b0;
                S_AXI_RVALID <= 1'b1;
                case (axi_rlane)
                    2'd0: S_AXI_RDATA <= o_PA_RDATA[ 31:  0];
                    2'd1: S_AXI_RDATA <= o_PA_RDATA[ 63: 32];
                    2'd2: S_AXI_RDATA <= o_PA_RDATA[ 95: 64];
                    2'd3: S_AXI_RDATA <= o_PA_RDATA[127: 96];
                endcase
            end

            // R handshake complete
            if (S_AXI_RVALID && S_AXI_RREADY) begin
                S_AXI_RVALID  <= 1'b0;
                S_AXI_ARREADY <= 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------------------------------------
    // Port A address mux: AXI has priority over the RTL
    // ---------------------------------------------------------------------------------------------

    wire        pa_axi_active = axi_wr_pending | axi_rd_pending | axi_rd_wait;
    assign      o_PA_BUSY     = pa_axi_active;

    wire [13:0] pa_addr = pa_axi_active ? (axi_wr_pending ? axi_waddr : axi_raddr)
                                        : i_PA_ADDR;

    // ---------------------------------------------------------------------------------------------
    // Port A: read and byte write (Vivado inference pattern)
    // ---------------------------------------------------------------------------------------------

    always_ff @(posedge i_CLK) begin
        if (axi_wr_pending) begin
            // byte write from AXI, which has priority
            for (int i = 0; i < 16; i++) begin
                if (axi_wbe[i])
                    mem[pa_addr][i*8 +: 8] <= axi_wdata_128[i*8 +: 8];
            end
        end
        else if (i_PA_WR && !pa_axi_active) begin
            // full-word write from the RTL, only while AXI is idle
            mem[pa_addr] <= i_PA_WDATA;
        end
        // synchronous read-first read
        o_PA_RDATA <= mem[pa_addr];
    end

    // ---------------------------------------------------------------------------------------------
    // Port B: read and write (RTL only)
    // ---------------------------------------------------------------------------------------------

    always_ff @(posedge i_CLK) begin
        if (i_PB_WR) begin
            mem[i_PB_ADDR] <= i_PB_WDATA;
        end
        o_PB_RDATA <= mem[i_PB_ADDR];
    end

endmodule
