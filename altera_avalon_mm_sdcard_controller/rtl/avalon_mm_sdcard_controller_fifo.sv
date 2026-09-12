`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_fifo.sv
//
// The block buffer that decouples the shifter from memory. Bytes on the
// sequencer side, 32-bit words on the DMA (or PIO) side, one clock domain.
//
// -----------------------------------------------------------------------------
// WHY A WORD-WIDE MEMORY WITH A BYTE PACKER, NOT A BYTE-WIDE MEMORY
// -----------------------------------------------------------------------------
// The obvious structure - a byte-addressed array that the word side reads four
// entries of at once - needs either four RAM lanes with address arithmetic per
// lane, or a 4:1 wide mux across the whole array. Both are more logic than this
// core deserves.
//
// The rates make a much simpler structure possible. The byte side moves one
// byte per eight SPI clocks, which even at CLKDIV=1 is one byte per sixteen
// system clocks. So the byte side can afford a 32-bit staging register and only
// touch the memory once every four bytes. What is left is an ordinary word-wide
// circular FIFO with a serialiser on one port - one RAM, one address, no lanes.
//
// -----------------------------------------------------------------------------
// BYTE ORDER
// -----------------------------------------------------------------------------
// Byte 0 of a block occupies bits [7:0] of the first word, byte 1 bits [15:8],
// and so on: little-endian, matching Nios II. A `char*` walked over the DMA
// buffer therefore sees the card's bytes in card order, which is what every
// filesystem layer above this expects.
//
// This is invisible until it is wrong, and when it is wrong every 32-bit field
// a filesystem reads is byte-swapped while every string still looks correct -
// so it is stated here, checked in the testbench, and re-derived by
// doc/tools/check_facts.py.
//
// -----------------------------------------------------------------------------
// PARTIAL WORDS
// -----------------------------------------------------------------------------
// Block lengths are not required to be multiples of four - a 512-byte data
// block is, but a 16-byte CSD/CID read is, and a partial-block read on a
// standard-capacity card need not be. `flush` pushes a partially filled staging
// register into the FIFO at the end of a block so the tail bytes are not
// stranded. The unused lanes are zero.
// =============================================================================

module avalon_mm_sdcard_controller_fifo #(
    parameter int unsigned DEPTH_BYTES = 1024,

    // Address width of the word store, needed in the PORT list below and so
    // declared as a parameter rather than the localparam it would otherwise be.
    // Never overridden - the default is the only correct value.
    parameter int unsigned AW_PUB = $clog2(DEPTH_BYTES / 4)
) (
    input  logic        clk,
    input  logic        reset_n,
    input  logic        clear,          // drop everything, reset both pointers

    // ---- direction ---------------------------------------------------------
    // Selects which port fills and which drains. DIR_CARD_TO_HOST: the byte
    // side writes and the word side reads. DIR_HOST_TO_CARD: the reverse.
    // Changing direction with data in flight is a software error; `clear`
    // between transfers is what makes it safe.
    input  logic        dir_host_to_card,

    // ---- byte side (sequencer) ---------------------------------------------
    input  logic        b_wr,           // push one byte (card -> host)
    input  logic [7:0]  b_wdata,
    input  logic        b_rd,           // pop one byte  (host -> card)
    output logic [7:0]  b_rdata,
    output logic        b_empty,        // nothing to pop on the byte side
    output logic        b_full,         // no room to push on the byte side
    input  logic        flush,          // commit a partial staging word

    // ---- word side (DMA, or the CSR DATA window) ---------------------------
    input  logic        w_wr,
    input  logic [31:0] w_wdata,
    input  logic        w_rd,
    output logic [31:0] w_rdata,
    output logic        w_empty,
    output logic        w_full,

    // ---- occupancy ---------------------------------------------------------
    output logic [15:0] level_bytes,

    // Room left in the store, in WORDS, for the word-side producer.
    //
    // Exposed separately from level_bytes rather than derived from it, because
    // the DMA bounds its read bursts on this and the derivation was on the
    // critical path: words to bytes here, then bytes back to words in the top
    // level, then three comparisons in the burst sizing - all to recover a
    // number the pointers already hold. Straight from the pointers it is one
    // subtract of AW+1 bits instead of a 16-bit round trip.
    //
    // The staging registers are deliberately not counted. This is space in the
    // STORE, which is what a word-side push consumes, and for that it is exact.
    output logic [AW_PUB:0] w_space_words
);

    localparam int unsigned DEPTH_WORDS = DEPTH_BYTES / 4;
    localparam int unsigned AW          = $clog2(DEPTH_WORDS);

    // -------------------------------------------------------------------------
    // Word-wide circular store.
    //
    // Pointers carry one extra bit above the address so that full and empty are
    // distinguishable without wasting an entry: equal pointers mean empty,
    // pointers differing only in the top bit mean full.
    // -------------------------------------------------------------------------
    logic [31:0]   mem [0:DEPTH_WORDS-1];
    logic [AW:0]   wptr, rptr;
    logic [AW-1:0] waddr, raddr;

    // The pop, zero-extended to pointer width once, so the read address and the
    // pointer advance by the same thing and neither needs a width cast at the
    // point of use.
    logic [AW:0]   pop_inc;

    always_comb waddr = wptr[AW-1:0];

    // The read address LOOKS AHEAD past a pop happening this cycle.
    //
    // The store is read synchronously so that it maps to a memory block, which
    // means ram_q lags the address by a cycle. Addressing it with rptr alone
    // would present the word that was just popped. Adding the pop makes the
    // fetch land on the NEXT head, so the consumer still sees show-ahead
    // behaviour - a valid head on the output with no read-enable handshake -
    // with one register instead of a combinational read of the whole array.
    always_comb raddr = rptr[AW-1:0] + pop_inc[AW-1:0];

    // The fetched head, and whether it is valid. ram_q is the memory block's
    // output register; head_v says it currently holds mem[rptr].
    logic [31:0] ram_q;
    logic        head_v;

    // No mem_empty any more. "The store holds nothing" stopped being the useful
    // question once the read became synchronous - what a consumer needs to know
    // is whether the head has been FETCHED, which is head_v above. The bound
    // assertion that used to check mem_empty checks head_v instead, and it is
    // the stronger of the two.
    logic mem_full;
    always_comb mem_full = (wptr[AW-1:0] == rptr[AW-1:0]) &&
                           (wptr[AW] != rptr[AW]);

    logic [AW:0] mem_level;
    always_comb mem_level = wptr - rptr;

    // -------------------------------------------------------------------------
    // Byte staging
    //
    // pack_*   assembles four incoming bytes into a word before one memory
    //          write (card -> host).
    // unpack_* holds one word popped from memory and serves it out a byte at a
    //          time (host -> card).
    // -------------------------------------------------------------------------
    logic [31:0] pack_data;
    logic [1:0]  pack_cnt;

    logic [31:0] unpack_data;
    logic [1:0]  unpack_cnt;
    logic        unpack_valid;

    // A byte write commits a word when it fills the fourth lane; `flush`
    // commits early.
    logic pack_commit;
    always_comb pack_commit = (b_wr && (pack_cnt == 2'd3)) ||
                              (flush && (pack_cnt != 2'd0));

    // A byte read needs a word loaded; load one whenever the holding register
    // is empty and the memory has something.
    // The head has to be IN ram_q, not merely written into the store: a word
    // written last cycle is not readable until the fetch that follows it lands.
    logic unpack_load;
    always_comb unpack_load = dir_host_to_card && !unpack_valid && head_v;

    // -------------------------------------------------------------------------
    // Pointer and memory update
    // -------------------------------------------------------------------------
    logic mem_push, mem_pop;
    always_comb begin
        mem_push = dir_host_to_card ? w_wr        : pack_commit;
        mem_pop  = dir_host_to_card ? unpack_load : w_rd;
    end

    // A pop only happens if there is a fetched head to pop. Everything that
    // advances rptr keys off this, so the pointer and the look-ahead address
    // cannot disagree about whether a word left the queue.
    logic mem_pop_eff;
    always_comb mem_pop_eff = mem_pop && head_v;
    always_comb pop_inc     = {{AW{1'b0}}, mem_pop_eff};

    logic [31:0] mem_wdata;
    always_comb begin
        if (dir_host_to_card) mem_wdata = w_wdata;
        else if (b_wr)        mem_wdata = pack_data | (32'(b_wdata) << (8 * pack_cnt));
        else                  mem_wdata = pack_data;   // flush of a partial word
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wptr <= '0;
            rptr <= '0;
        end else if (clear) begin
            wptr <= '0;
            rptr <= '0;
        end else begin
            if (mem_push && !mem_full) wptr <= wptr + 1'b1;
            if (mem_pop_eff)           rptr <= rptr + 1'b1;
        end
    end

    // One write port and one SYNCHRONOUS read port, in a single clocked block
    // with no reset on either - which is what lets this infer a memory block
    // rather than a register file.
    //
    // WHAT THIS COST BEFORE. The read used to be combinational, for one
    // consistent semantic across both ports, on the reasoning that a store this
    // small "costs an MLAB rather than a block RAM". MAX 10 has no MLABs - they
    // are a Stratix and Arria feature - so on the actual target the array became
    // 8279 registers and a mux, 10118 logic cells, 87% of the entire core, for
    // 1024 bytes that fit in one M9K with room spare. Nothing in simulation can
    // see that; verification/check_synthesis.sh is what does.
    always_ff @(posedge clk) begin
        if (mem_push && !mem_full) mem[waddr] <= mem_wdata;
        ram_q <= mem[raddr];
    end

    // Does ram_q hold the word at rptr?
    //
    // Compared against the CURRENT wptr, deliberately, because a word written
    // this cycle is not readable this cycle - the fetch already issued with the
    // old contents. Using the post-push pointer would mark the head valid one
    // cycle early and hand the consumer whatever the location held before.
    //
    // This also supplies the fill latency for free: from empty, a push leaves
    // wptr == rptr for this cycle, so head_v stays low and only rises once the
    // following fetch has landed.
    logic [AW:0] rptr_next;
    always_comb rptr_next = rptr + pop_inc;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)     head_v <= 1'b0;
        else if (clear)   head_v <= 1'b0;
        else              head_v <= (wptr != rptr_next);
    end

    // Show-ahead is preserved: w_rdata always presents the head of the queue,
    // valid whenever w_empty is low, and w_rd pops it. Both clients rely on
    // that - the DMA drives m0_writedata straight from it and decides to write
    // in the same cycle, and the CSR DATA window returns it on a read - so it
    // is the contract, not an implementation detail.
    //
    // What changed is only how the head gets there. It used to be a
    // combinational read of the array; it is now the memory block's output
    // register, fetched one cycle ahead using the look-ahead address above. The
    // two latencies onto one array that the old comment here warned about are
    // avoided the same way: there is now exactly one read path, and the byte
    // side takes its word from the same register.
    always_comb w_rdata = ram_q;

    // -------------------------------------------------------------------------
    // Byte side bookkeeping
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pack_data    <= '0;
            pack_cnt     <= '0;
            unpack_data  <= '0;
            unpack_cnt   <= '0;
            unpack_valid <= 1'b0;
        end else if (clear) begin
            pack_data    <= '0;
            pack_cnt     <= '0;
            unpack_data  <= '0;
            unpack_cnt   <= '0;
            unpack_valid <= 1'b0;
        end else begin

            // ---- pack (card -> host) ----
            if (pack_commit) begin
                pack_data <= '0;
                pack_cnt  <= '0;
            end else if (b_wr) begin
                pack_data <= pack_data | (32'(b_wdata) << (8 * pack_cnt));
                pack_cnt  <= pack_cnt + 2'd1;
            end

            // ---- unpack (host -> card) ----
            if (unpack_load) begin
                unpack_data  <= ram_q;
                unpack_valid <= 1'b1;
                unpack_cnt   <= '0;
            end else if (b_rd && unpack_valid) begin
                if (unpack_cnt == 2'd3) begin
                    unpack_valid <= 1'b0;      // word exhausted, fetch another
                end
                unpack_cnt <= unpack_cnt + 2'd1;
            end
        end
    end

    always_comb b_rdata = unpack_data[8*unpack_cnt +: 8];

    // -------------------------------------------------------------------------
    // Flags
    //
    // The byte side's view accounts for the staging registers as well as the
    // memory, so a sequencer that checks b_empty before popping is never told
    // there is a byte available when only a partial word is in flight.
    // -------------------------------------------------------------------------
    // Each direction has one producing port and one consuming port; the flags
    // belonging to the idle role are driven to the value that means "you cannot
    // do this", so a client that ignores direction stalls rather than
    // corrupting the queue.
    //
    //   dir = card -> host :  byte side produces, word side consumes
    //   dir = host -> card :  word side produces, byte side consumes
    always_comb begin
        if (dir_host_to_card) begin
            // `!unpack_valid` alone, NOT `!unpack_valid && mem_empty`. A word
            // sitting in memory is not a byte the consumer can have: it must be
            // loaded into the staging register first, which takes a cycle. The
            // stricter form would report a byte available while b_rdata still
            // held the previous word, handing out four stale bytes every time
            // the staging register turned over.
            b_empty = !unpack_valid;                // byte side consumes
            b_full  = 1'b1;                         // ... and never produces
            w_empty = 1'b1;                         // word side never consumes
            w_full  = mem_full;                     // ... it produces
        end else begin
            b_empty = 1'b1;                         // byte side never consumes
            b_full  = mem_full && (pack_cnt == 2'd3);
            // `!head_v`, not `mem_empty`. A word in the store that has not yet
            // been fetched into ram_q is not a word the consumer can have, and
            // saying otherwise would present whatever ram_q happened to hold -
            // the same class of mistake the byte side's own flag avoids just
            // below.
            w_empty = !head_v;                      // word side consumes
            w_full  = 1'b1;                         // ... and never produces
        end
    end

    // Occupancy in bytes, for STATUS. Includes the staging registers so the
    // number software reads matches the number of bytes actually held.
    // One subtract, AW+1 bits wide, and nothing else.
    always_comb w_space_words = (AW+1)'(DEPTH_WORDS) - mem_level;

    always_comb begin
        level_bytes = 16'(mem_level) * 16'd4
                    + 16'(pack_cnt)
                    + (unpack_valid ? (16'd4 - 16'(unpack_cnt)) : 16'd0);
    end

endmodule : avalon_mm_sdcard_controller_fifo
