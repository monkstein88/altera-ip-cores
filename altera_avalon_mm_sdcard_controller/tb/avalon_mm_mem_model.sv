`timescale 1ns/1ps

// =============================================================================
// avalon_mm_mem_model.sv
//
// An Avalon-MM slave for the DMA master to talk to. Sparse, bursting, with
// programmable wait states.
//
// The wait states are the point. A memory that always accepts immediately
// exercises none of the paths that matter: `waitrequest` must freeze address,
// writedata, burstcount and byteenable together (Avalon 18.1 §3.5.5), and a
// read burst's data must be accepted whenever the slave chooses to return it.
// A zero-latency model would let a DUT that mishandles either of those pass.
// =============================================================================

module avalon_mm_mem_model #(
    parameter int unsigned ADDR_WIDTH     = 32,
    parameter int unsigned BURST_WIDTH    = 8,
    parameter int unsigned MAX_WAIT       = 0,   // wait states per command
    parameter int unsigned READ_LATENCY   = 2    // cycles before readdatavalid
) (
    input  logic                      clk,
    input  logic                      reset_n,

    input  logic [ADDR_WIDTH-1:0]     address,
    input  logic                      read,
    input  logic                      write,
    input  logic [31:0]               writedata,
    input  logic [3:0]                byteenable,
    input  logic [BURST_WIDTH-1:0]    burstcount,
    output logic                      waitrequest,
    output logic [31:0]               readdata,
    output logic                      readdatavalid,
    output logic [1:0]                response,

    output int unsigned               wr_beats,
    output int unsigned               rd_beats,
    output logic                      saw_zero_byteenable_read
);

    logic [31:0] mem [int unsigned];

    int unsigned wait_cnt;
    int unsigned rd_left;
    logic [ADDR_WIDTH-1:0] rd_addr;
    logic [ADDR_WIDTH-1:0] wr_addr;
    int unsigned wr_left;

    // Fixed-length delay line for read returns, so READ_LATENCY is honoured.
    //
    // A queue drained on `size >= READ_LATENCY` looks equivalent and silently
    // swallows the final beats of every burst - the queue never gets back up to
    // depth once the address phase stops. Avalon read data cannot be dropped:
    // a master that issued a burst of N is entitled to N beats and will wait
    // forever for the last one. A shift register cannot express that bug.
    localparam int unsigned DL = (READ_LATENCY < 1) ? 1 :
                                 (READ_LATENCY > 8) ? 8 : READ_LATENCY;
    logic [31:0] dl_data [0:7];
    logic        dl_valid [0:7];

    always_comb waitrequest = (wait_cnt != 0);
    always_comb response    = 2'b00;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wait_cnt      <= 0;
            rd_left       <= 0;
            wr_left       <= 0;
            rd_addr       <= '0;
            wr_addr       <= '0;
            readdatavalid <= 1'b0;
            readdata      <= '0;
            wr_beats      <= 0;
            rd_beats      <= 0;
            saw_zero_byteenable_read <= 1'b0;
            for (int k = 0; k < 8; k++) begin
                dl_data[k]  <= '0;
                dl_valid[k] <= 1'b0;
            end
        end else begin
            readdatavalid <= 1'b0;

            // ---- command acceptance ----
            if (wait_cnt != 0) begin
                wait_cnt <= wait_cnt - 1;
            end else begin

                if (write) begin
                    if (wr_left == 0) begin
                        wr_addr <= address + ADDR_WIDTH'(4);
                        wr_left <= int'(burstcount) - 1;
                        if (byteenable[0]) mem[address >> 2] = writedata;
                    end else begin
                        wr_addr <= wr_addr + ADDR_WIDTH'(4);
                        wr_left <= wr_left - 1;
                        if (byteenable[0]) mem[wr_addr >> 2] = writedata;
                    end
                    wr_beats <= wr_beats + 1;
                    if (MAX_WAIT != 0) wait_cnt <= MAX_WAIT;
                end

                else if (read) begin
                    // Avalon 18.1 §3.5.5: a read with all byteenables clear may
                    // legitimately be SUPPRESSED by the interconnect, so a
                    // master must never issue one. Flagged rather than served,
                    // because serving it would hide the DUT's mistake.
                    if (byteenable == 4'h0) saw_zero_byteenable_read <= 1'b1;

                    rd_addr <= address;
                    rd_left <= int'(burstcount);
                    if (MAX_WAIT != 0) wait_cnt <= MAX_WAIT;
                end
            end

            // ---- read data return ----
            for (int k = 7; k > 0; k--) begin
                dl_data[k]  <= dl_data[k-1];
                dl_valid[k] <= dl_valid[k-1];
            end

            if (rd_left != 0) begin
                dl_data[0]  <= mem.exists(rd_addr >> 2) ? mem[rd_addr >> 2]
                                                        : 32'hDEADBEEF;
                dl_valid[0] <= 1'b1;
                rd_addr     <= rd_addr + ADDR_WIDTH'(4);
                rd_left     <= rd_left - 1;
            end else begin
                dl_valid[0] <= 1'b0;
            end

            if (dl_valid[DL-1]) begin
                readdata      <= dl_data[DL-1];
                readdatavalid <= 1'b1;
                rd_beats      <= rd_beats + 1;
            end
        end
    end

    // ---- test hooks ---------------------------------------------------------
    function automatic void poke(input int unsigned word_addr, input logic [31:0] d);
        mem[word_addr] = d;
    endfunction

    function automatic logic [31:0] peek(input int unsigned word_addr);
        return mem.exists(word_addr) ? mem[word_addr] : 32'hDEADBEEF;
    endfunction

endmodule : avalon_mm_mem_model
