`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_spi_phy.sv
//
// The SPI shifter. Full-duplex, MSB first, SPI mode 0, and - the whole point -
// with no idle clock between one byte and the next.
//
// -----------------------------------------------------------------------------
// WHY THIS MODULE IS WHERE THE THROUGHPUT LIVES
// -----------------------------------------------------------------------------
// SPI mode gives about 3.1 MB/s at 25 MHz and there is nothing to be done about
// that ceiling. What IS in this module's gift is how much of the ceiling is
// actually reached. The usual byte-at-a-time state machine - load a byte, shift
// eight bits, raise a flag, wait for someone to hand it the next byte - inserts
// one or two idle SPI clocks at every byte boundary. At one idle clock per byte
// that is 1/9 of the bus thrown away; at two it is 1/5. Over a 512-byte block
// it is the difference between 99% and 80% of line rate, and it is invisible in
// any functional test because every byte still arrives correctly.
//
// So this shifter never stops between bytes. It carries a one-deep prefetch
// register, and at the byte boundary it takes whatever is in the prefetch with
// zero dead cycles. If the prefetch is empty it shifts 0xFF instead of
// stalling, which is not a fallback but the normal case: 0xFF on MOSI is
// exactly what the host sends to clock data out of the card. The sequencer
// therefore does not have to keep up during a receive phase at all - it lets
// the shifter free-run and collects bytes as they land.
//
// -----------------------------------------------------------------------------
// SPI MODE 0 AT THE PIN
// -----------------------------------------------------------------------------
// CPOL=0, CPHA=0: clock idles low, both sides change data on the falling edge
// and capture on the rising edge. Two consequences shape the code below.
//
// FIRST BIT. Because CPHA=0 captures on the FIRST edge, MOSI must already be
// valid before the first rising edge - there is no preceding falling edge to
// drive it. So `mosi` is loaded when a byte is loaded, not on a falling edge.
// Every subsequent bit then changes on `fall_stb`.
//
// SAMPLING, AND WHY THERE IS NO SYNCHRONISER. MISO is not asynchronous: the
// card drives it from the clock this core generates, so it is source
// synchronous. A two-flop synchroniser on it would be the reflexive thing to
// add and would be actively wrong here - it costs two system clocks, which at
// CLKDIV=1 is a whole SPI bit period, and it would destroy the interface rather
// than protect it. MISO is sampled directly, and the interface is closed with
// timing constraints (set_input_delay in the example's .sdc), which is how
// every source-synchronous interface is handled.
//
// What that leaves is the round trip: our sd_clk edge out to the card, the
// card's output delay, MISO back. All of it must fit inside half an SPI period,
// which at CLKDIV=1 is 10 ns. On a socket that is comfortable. On flying leads
// to a breakout it may well not be, and section 7.5 of the Simplified
// Specification - SPI Bus Timing Diagrams - is blank, so there is no published
// number to design against. Hence `sample_dly`: it moves the capture point up
// to seven system clocks later than nominal, trading setup margin for hold
// margin, tunable against real hardware rather than guessed at.
// =============================================================================

module avalon_mm_sdcard_controller_spi_phy
    import avalon_mm_sdcard_controller_pkg::*;
#(
    parameter int unsigned CLKDIV_WIDTH = 8
) (
    input  logic                    clk,
    input  logic                    reset_n,

    // ---- configuration -----------------------------------------------------
    input  logic [CLKDIV_WIDTH-1:0] clkdiv,
    input  logic [2:0]              sample_dly,  // extra system clocks before capture

    // ---- run control -------------------------------------------------------
    // `run` means "keep shifting bytes". Deasserting it does not chop a byte in
    // half: the current byte always completes, then the shifter idles with
    // sd_clk parked low.
    input  logic                    run,

    // `tx_idle` says what to do when `run` is asserted and the prefetch is
    // empty. High: shift 0xFF, which is how the host clocks data out of the
    // card during any receive phase. Low: wait, shifting nothing until a byte
    // is queued.
    //
    // Without this distinction the shifter emits a byte nobody asked for. From
    // rest the prefetch is necessarily empty for one cycle - the sequencer
    // cannot queue a byte before deciding to start - so an unconditional load
    // sends a spurious leading 0xFF ahead of every command frame. Harmless on
    // the wire, since 0xFF is the idle level, but it means the byte stream
    // leaving this module is not the byte stream the sequencer asked for, and
    // that is not a property worth giving up to save one signal.
    input  logic                    tx_idle,

    output logic                    idle,        // no byte in flight, clock low

    // ---- transmit ----------------------------------------------------------
    // One-deep prefetch. Present a byte with tx_we while tx_ready is high and
    // it will be shifted with no gap after the byte currently in flight. Leave
    // it empty and 0xFF is shifted instead.
    input  logic [7:0]              tx_data,
    input  logic                    tx_we,
    output logic                    tx_ready,

    // ---- receive -----------------------------------------------------------
    output logic [7:0]              rx_data,
    output logic                    rx_valid,    // one-cycle pulse

    // ---- pins --------------------------------------------------------------
    output logic                    sd_clk,
    output logic                    sd_mosi,
    input  logic                    sd_miso
);

    // -------------------------------------------------------------------------
    // Clock generation
    //
    // The divider is gated on `byte_active`, NOT on `run`. That distinction is
    // load-bearing at CLKDIV=1 and invisible everywhere else.
    //
    // `run` can be asserted a cycle before the first byte reaches the prefetch,
    // because the sequencer cannot queue a byte before it has decided to start.
    // Gating the clock on `run` therefore lets it advance one edge while the
    // shifter is still empty. At CLKDIV=125 that edge is lost in the noise; at
    // CLKDIV=1, where the divider ticks every system clock, it consumes a whole
    // SPI clock and shifts the bit alignment of the entire transfer by one -
    // every byte off by a bit, for the rest of the transaction.
    //
    // Gating on `byte_active` means the clock cannot start until a byte is
    // genuinely loaded and MOSI holds its MSB. That is also precisely what
    // CPHA=0 requires: data valid before the first rising edge. The clkgen's
    // own `active` term keeps it running past a deassertion until it lands low,
    // so the trailing edge of the last byte still completes.
    // -------------------------------------------------------------------------
    logic rise_stb, fall_stb, clk_idle;
    logic byte_active;

    avalon_mm_sdcard_controller_clkgen #(
        .CLKDIV_WIDTH (CLKDIV_WIDTH)
    ) u_clkgen (
        .clk      (clk),
        .reset_n  (reset_n),
        .clkdiv   (clkdiv),
        .run      (byte_active),
        .sd_clk   (sd_clk),
        .rise_stb (rise_stb),
        .fall_stb (fall_stb),
        .idle     (clk_idle)
    );

    // -------------------------------------------------------------------------
    // Delayed capture strobe
    //
    // rise_stb marks the cycle in which sd_clk is registered high, so the edge
    // reaches the pin one system clock later. Tap 0 of this pipeline is
    // therefore already one clock past the strobe, which is the nominal capture
    // point; sample_dly adds up to seven more.
    //
    // The pipeline is eight deep and the tap is selected combinationally, so
    // sample_dly can be changed between transfers without a reset. Changing it
    // mid-byte would misalign the bit count, which is why the CSR write is
    // ignored while the shifter is busy (see avalon_mm_sdcard_controller_regs.sv).
    // -------------------------------------------------------------------------
    // Exactly eight taps, matching the three bits of sample_dly. Sized to the
    // index rather than a bit wider: a ninth stage would be unreachable, and an
    // unreachable pipeline stage is the kind of thing that survives review and
    // then confuses whoever next tries to widen the delay range.
    logic [7:0] rise_pipe;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) rise_pipe <= '0;
        else          rise_pipe <= {rise_pipe[6:0], rise_stb};
    end

    logic smpl_stb;
    always_comb smpl_stb = rise_pipe[sample_dly];

    // -------------------------------------------------------------------------
    // Transmit path
    // -------------------------------------------------------------------------
    logic [7:0] shreg;      // byte in flight, MSB leaving first
    logic [7:0] hold;       // prefetch
    logic       hold_v;
    logic [2:0] tx_cnt;     // bits driven out of the current byte
    logic       mosi_q;

    always_comb tx_ready = !hold_v;

    // The byte boundary on the transmit side is the eighth falling edge: at
    // that point the last bit of the current byte has been driven and the next
    // byte's MSB must appear immediately.
    logic tx_last_bit;
    always_comb tx_last_bit = fall_stb && (tx_cnt == 3'd7);

    // What to load next. An empty prefetch yields 0xFF, which is the correct
    // thing to drive while receiving, not a degraded fallback.
    logic [7:0] next_byte;
    always_comb next_byte = hold_v ? hold : MOSI_IDLE;

    // A byte is loaded either from rest or at the byte boundary - the two
    // points where MOSI must present a new MSB with no gap.
    //
    // `have_byte` is what keeps the shifter from inventing traffic: with
    // tx_idle low it will only load a byte the sequencer actually queued, so an
    // empty prefetch stalls the clock rather than emitting 0xFF. During a
    // receive phase tx_idle is high and the empty prefetch is the normal
    // steady state.
    logic have_byte, load_now;
    always_comb have_byte = hold_v || tx_idle;
    always_comb load_now  = run && have_byte && (!byte_active || tx_last_bit);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            shreg       <= MOSI_IDLE;
            hold        <= MOSI_IDLE;
            hold_v      <= 1'b0;
            tx_cnt      <= '0;
            mosi_q      <= 1'b1;
            byte_active <= 1'b0;
        end else begin

            // ---- prefetch bookkeeping ----
            // Producing and consuming are mutually exclusive by construction:
            // accepting a write requires hold_v == 0 and consuming requires
            // hold_v == 1. Written as if/else rather than as two independent
            // ifs so that it stays that way - two separate ifs would let a byte
            // written on the same cycle it is consumed be silently dropped,
            // which is a data-corruption bug that no functional test involving
            // a slow sequencer would ever provoke.
            if (tx_we && !hold_v) begin
                hold   <= tx_data;
                hold_v <= 1'b1;
            end else if (load_now && hold_v) begin
                hold_v <= 1'b0;
            end

            // ---- the shift itself ----
            if (load_now) begin
                // CPHA=0 captures on the FIRST rising edge, so the MSB is
                // presented at load time rather than waiting for a falling
                // edge that has not happened yet.
                shreg       <= {next_byte[6:0], 1'b1};
                mosi_q      <= next_byte[7];
                tx_cnt      <= '0;
                byte_active <= 1'b1;

            end else if (tx_last_bit) begin
                // Boundary reached with `run` low: stop cleanly, on a byte.
                byte_active <= 1'b0;
                mosi_q      <= 1'b1;

            end else if (fall_stb && byte_active) begin
                shreg  <= {shreg[6:0], 1'b1};
                mosi_q <= shreg[7];
                tx_cnt <= tx_cnt + 3'd1;

            end else if (!byte_active) begin
                mosi_q <= 1'b1;             // MOSI idles high
            end
        end
    end

    always_comb sd_mosi = mosi_q;

    // -------------------------------------------------------------------------
    // Receive path
    //
    // Counted independently of the transmit side. The two are offset by half a
    // bit by construction - data is driven on the falling edge and captured on
    // the rising one - and coupling them through a shared counter would only
    // create a false dependency between the drive point and the (adjustable)
    // capture point.
    // -------------------------------------------------------------------------
    // Seven bits, not eight: the eighth arrives on sd_miso at the moment the
    // byte completes and is concatenated straight into rx_data, so it is never
    // stored. An eight-bit register here would leave its top bit written and
    // never read.
    logic [6:0] rxreg;
    logic [2:0] rx_cnt;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rxreg    <= '0;
            rx_cnt   <= '0;
            rx_data  <= '0;
            rx_valid <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            if (smpl_stb) begin
                rxreg  <= {rxreg[5:0], sd_miso};
                rx_cnt <= rx_cnt + 3'd1;

                if (rx_cnt == 3'd7) begin
                    rx_data  <= {rxreg, sd_miso};
                    rx_valid <= 1'b1;
                end
            end

            // Re-align the bit counter whenever the shifter is at rest, so a
            // stopped and restarted transfer always begins on a byte boundary.
            //
            // The rise_pipe guard matters: because capture is delayed by up to
            // sample_dly + 1 system clocks, the final bits of the last byte are
            // still in flight when byte_active drops. Realigning on
            // byte_active alone would truncate the last byte of every transfer
            // - and only when sample_dly is non-zero, which is exactly the
            // configuration least likely to be simulated first.
            if (!byte_active && !run && (rise_pipe == '0)) rx_cnt <= '0;
        end
    end

    // "Nothing left to do" must include the PREFETCH, not just the byte being
    // shifted. Between one byte finishing and the next being loaded there is a
    // cycle where byte_active is low while `hold` still carries a queued byte;
    // reporting idle there tells the sequencer a transfer has drained while its
    // last byte has not yet been put on the wire at all.
    always_comb idle = !byte_active && !hold_v && clk_idle;

endmodule : avalon_mm_sdcard_controller_spi_phy
