`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_dma.sv
//
// The Avalon-MM master. Moves whole blocks between the FIFO and system memory
// so the CPU never has to service the shifter.
//
// Present only when USE_DMA; with it off this module and the m0 port do not
// exist and the CSR DATA window is the FIFO's other client instead.
//
// -----------------------------------------------------------------------------
// WHAT THIS IS FOR, AND WHAT IT IS NOT FOR
// -----------------------------------------------------------------------------
// It is NOT for throughput. At 50 MHz SPI a 32-bit word leaves the card every
// 640 ns - 64 system clocks at 100 MHz - so even a non-bursting master with
// twenty cycles of latency has threefold margin, and the memory side is never
// what limits this core. What the DMA buys is the CPU's time back (10-20% of a
// 100 MHz Nios II/f during a transfer) and immunity to interrupt latency.
//
// Bursting is likewise a courtesy to the rest of the system rather than a
// necessity here: a 128-beat burst costs one SDRAM row activation instead of
// 128, so the controller steals far less bandwidth from everything else.
// M0_BURST_WIDTH = 1 - no bursting at all - is a supported configuration, and
// Platform Designer will insert a burst adapter anywhere m0 meets a slave that
// bursts less than it does.
//
// -----------------------------------------------------------------------------
// FOUR RULES FROM THE AVALON SPECIFICATION THAT SHAPE THIS CODE
// -----------------------------------------------------------------------------
// (Avalon Interface Specifications 18.1, section 3.5.5.)
//
// 1. "A bursting Avalon-MM interface that supports both reads and writes must
//    support both read and write bursts." This port does both directions -
//    reads from memory for card writes, writes to memory for card reads - so
//    there is no shortcut where only one direction bursts.
//
// 2. NEVER issue a read whose byteenables are all zero. The interconnect is
//    explicitly permitted to suppress such a read, and the slave then never
//    responds: a hang with no error reported anywhere. Intel additionally
//    recommends asserting all byteenables on any burst read. Both are satisfied
//    by driving byteenable to all ones unconditionally - this core only ever
//    moves whole 32-bit words.
//
// 3. waitrequest freezes the entire command. address, writedata, write,
//    burstcount and byteenable all hold constant while it is asserted. Every
//    register below is therefore only updated on an accepted beat.
//
// 4. READ DATA CANNOT BE BACKPRESSURED. readdatavalid has no ready signal: once
//    a read burst of N is issued, N words WILL arrive and the master must take
//    them. That is why `f_space` exists and why a read burst is never longer
//    than the room currently free in the FIFO. Gating f_wr on a "full" flag
//    instead would not stall the slave - it would silently discard beats, and
//    the corruption would appear as a block that is right at the start and
//    wrong at the end.
//
//    The write direction has no such constraint: Avalon explicitly permits a
//    master to deassert `write` mid-burst to delay it, so the memory-write path
//    simply stops offering beats while the FIFO is empty.
//
// A fifth, from the same section: constantBurstBehavior is false on this port,
// so address and burstcount are held for the first transaction of a burst only.
// =============================================================================

module avalon_mm_sdcard_controller_dma #(
    parameter int unsigned ADDR_WIDTH     = 32,
    parameter int unsigned M0_BURST_WIDTH = 8,
    parameter int unsigned LEN_WIDTH      = 16   // transfer length, in words
) (
    input  logic                        clk,
    input  logic                        reset_n,

    // ---- control -----------------------------------------------------------
    input  logic                        start,
    input  logic                        dir_host_to_card,  // 1 = read memory

    // Continue from the address the previous transfer stopped at, instead of
    // reloading `addr`. A multi-block command issues one DMA per block; this is
    // what makes those blocks land contiguously without the sequencer needing a
    // multiplier to compute a whole-transfer length.
    input  logic                        keep_addr,

    // Byte address. The low two bits are deliberately discarded rather than
    // honoured - see S_IDLE. Silently aligning is the right hardware behaviour
    // for a misaligned DMA_ADDR, since the alternative is writing across word
    // boundaries into memory the caller did not intend to touch.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [ADDR_WIDTH-1:0]       addr,
    /* verilator lint_on UNUSEDSIGNAL */

    input  logic [LEN_WIDTH-1:0]        len_words,
    input  logic                        abort_req,         // drop everything now

    output logic                        busy,
    output logic                        done,              // one-cycle pulse
    output logic                        err,               // m0 reported an error

    // ---- FIFO word side ----------------------------------------------------
    output logic                        f_rd,      // pop a word to write to memory
    input  logic [31:0]                 f_rdata,
    input  logic                        f_empty,
    output logic                        f_wr,      // push a word read from memory
    output logic [31:0]                 f_wdata,
    input  logic [LEN_WIDTH-1:0]        f_space,   // free words; bounds read bursts

    // ---- Avalon-MM master --------------------------------------------------
    output logic [ADDR_WIDTH-1:0]       m0_address,
    output logic                        m0_read,
    output logic                        m0_write,
    output logic [31:0]                 m0_writedata,
    output logic [3:0]                  m0_byteenable,
    output logic [M0_BURST_WIDTH-1:0]   m0_burstcount,
    input  logic                        m0_waitrequest,
    input  logic [31:0]                 m0_readdata,
    input  logic                        m0_readdatavalid,
    input  logic [1:0]                  m0_response
);

    localparam int unsigned MAX_BURST = (M0_BURST_WIDTH > 1)
                                      ? (1 << (M0_BURST_WIDTH - 1)) : 1;

    typedef enum logic [2:0] {
        S_IDLE,
        S_SETUP,      // size the next burst; wait here if the FIFO has no room
        S_WR_CMD,     // present address + burstcount, feed writedata
        S_RD_CMD,     // present address + burstcount, wait for acceptance
        S_RD_DATA,    // collect readdatavalid beats into the FIFO
        S_DONE
    } state_e;

    state_e state;

    // Set by abort_req, cleared when a new transfer starts.
    //
    // An abort cannot simply drop the port: Avalon forbids abandoning a burst
    // once beats have been accepted, and the interconnect will wait forever for
    // the ones it was promised. So `flushing` FINISHES the burst in flight -
    // offering write beats regardless of whether the FIFO has data, and
    // accepting read beats without storing them - and only then stops, without
    // starting another.
    //
    // The alternative, letting the DMA sit waiting for a FIFO that will never
    // fill, is what happens when a card answers a read with an error token
    // instead of a block: the transfer is over, the sequencer knows it, and the
    // DMA hangs the whole core waiting for data nobody is going to send.
    logic flushing;

    logic [ADDR_WIDTH-1:0]     cur_addr;
    logic [LEN_WIDTH-1:0]      remaining;      // words still to move
    logic [M0_BURST_WIDTH-1:0] beats_left;     // beats left in this burst
    logic [M0_BURST_WIDTH-1:0] burst_len;
    logic                      dir_q;

    // -------------------------------------------------------------------------
    // Burst sizing, done in one place (S_SETUP) rather than duplicated at every
    // burst boundary. Three bounds:
    //
    //   MAX_BURST   what the port can express in M0_BURST_WIDTH bits
    //   remaining   what is actually left to move
    //   f_space     how many words the FIFO can absorb - READ DIRECTION ONLY
    //
    // The FIFO bound does not apply to memory writes, where the FIFO is the
    // source and an empty FIFO merely stalls the burst.
    // -------------------------------------------------------------------------
    logic [LEN_WIDTH-1:0] cap;
    always_comb begin
        cap = remaining;
        if (cap > LEN_WIDTH'(MAX_BURST)) cap = LEN_WIDTH'(MAX_BURST);
        if (dir_q && (cap > f_space))    cap = f_space;
    end

    logic wr_accept, rd_accept;
    always_comb begin
        wr_accept = m0_write && !m0_waitrequest;
        rd_accept = m0_read  && !m0_waitrequest;
    end

    // Rule 2: all byteenables, always. This core moves whole words only.
    always_comb m0_byteenable = 4'hF;

    always_comb begin
        m0_address    = cur_addr;
        m0_burstcount = burst_len;
        m0_writedata  = f_rdata;
    end

    // Write data is sourced straight from the FIFO head, so a beat is offered
    // only when the FIFO actually has a word (rule 4, write side).
    always_comb begin
        m0_write = (state == S_WR_CMD) && (!f_empty || flushing);
        m0_read  = (state == S_RD_CMD) && !flushing;
        f_rd     = wr_accept && !flushing;
        f_wr     = (state == S_RD_DATA) && m0_readdatavalid && !flushing;
        f_wdata  = m0_readdata;
    end

    always_comb busy = (state != S_IDLE);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state      <= S_IDLE;
            cur_addr   <= '0;
            remaining  <= '0;
            beats_left <= '0;
            burst_len  <= '0;
            dir_q      <= 1'b0;
            done       <= 1'b0;
            err        <= 1'b0;
            flushing   <= 1'b0;
        end else begin
            done <= 1'b0;

            // A response other than OKAY is latched rather than acted on: the
            // burst in flight is allowed to complete so the interconnect never
            // sees a truncated one, and the sequencer reports the error at the
            // end of the transfer.
            if ((m0_readdatavalid || wr_accept) && (m0_response != 2'b00))
                err <= 1'b1;

            if (abort_req && busy) flushing <= 1'b1;

            begin
                unique case (state)

                    S_IDLE: begin
                        flushing <= 1'b0;
                        if (start) begin
                            // Word-align defensively. A misaligned DMA_ADDR is
                            // rejected by the driver, but silently moving the
                            // transfer rather than corrupting neighbouring
                            // memory is the better hardware behaviour.
                            if (!keep_addr)
                                cur_addr <= {addr[ADDR_WIDTH-1:2], 2'b00};
                            remaining <= len_words;
                            dir_q     <= dir_host_to_card;
                            err       <= 1'b0;
                            state     <= (len_words == '0) ? S_DONE : S_SETUP;
                        end
                    end

                    S_SETUP: begin
                        // cap == 0 means the FIFO has no room yet; hold here.
                        // This is the only place the DMA ever waits on the FIFO
                        // in the read direction, and it waits BEFORE committing
                        // to a burst rather than during one.
                        if (flushing) begin
                            state <= S_DONE;      // no further bursts
                        end else if (cap != '0) begin
                            burst_len  <= M0_BURST_WIDTH'(cap);
                            beats_left <= M0_BURST_WIDTH'(cap);
                            state      <= dir_q ? S_RD_CMD : S_WR_CMD;
                        end
                    end

                    // ---- memory write: card -> host ----
                    S_WR_CMD: begin
                        if (wr_accept) begin
                            cur_addr  <= cur_addr + ADDR_WIDTH'(4);
                            remaining <= remaining - 1'b1;
                            beats_left <= beats_left - 1'b1;

                            if (beats_left == M0_BURST_WIDTH'(1))
                                state <= (remaining == LEN_WIDTH'(1)) ? S_DONE : S_SETUP;
                        end
                    end

                    // ---- memory read: host -> card ----
                    S_RD_CMD: begin
                        // A read command not yet accepted commits nothing, so
                        // an abort here can leave without issuing it.
                        if (flushing)       state <= S_DONE;
                        else if (rd_accept) state <= S_RD_DATA;
                    end

                    S_RD_DATA: begin
                        if (m0_readdatavalid) begin
                            cur_addr   <= cur_addr + ADDR_WIDTH'(4);
                            remaining  <= remaining - 1'b1;
                            beats_left <= beats_left - 1'b1;

                            if (beats_left == M0_BURST_WIDTH'(1))
                                state <= (remaining == LEN_WIDTH'(1)) ? S_DONE : S_SETUP;
                        end
                    end

                    S_DONE: begin
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule : avalon_mm_sdcard_controller_dma
