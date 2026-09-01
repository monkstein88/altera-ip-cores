`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_seq.sv
//
// The protocol sequencer: command framing, response capture, the data phases,
// the multi-block loop and busy handling. Everything between "software wrote
// CMD" and "the transfer finished".
//
// -----------------------------------------------------------------------------
// ONE BYTE PER rx_valid
// -----------------------------------------------------------------------------
// SPI is full duplex, so every byte shifted out produces exactly one byte
// shifted in. This machine therefore advances on `rx_valid` and nothing else -
// even in states where the received byte is discarded. That gives one tick per
// byte for both directions and removes any need to reason separately about
// transmit and receive progress.
//
// While a state is sending, it queues the next byte whenever `tx_ready` is
// high; the shifter's one-deep prefetch then rolls straight into it at the byte
// boundary with no idle clock. While a state is receiving it raises `tx_idle`,
// which makes the shifter send 0xFF - exactly what the host must drive to clock
// data out of a card.
//
// -----------------------------------------------------------------------------
// FOUR THINGS THE SPECIFICATION REQUIRES THAT ARE EASY TO MISS
// -----------------------------------------------------------------------------
// 1. TRUNCATED MULTI-BYTE RESPONSES (§7.3.2). If R1 comes back with Illegal
//    Command or Command CRC Error set, the card sends ONLY that byte - the
//    32-bit trailer of an R3 or R7 never arrives. Shifting four more bytes
//    anyway desynchronises the bus for every subsequent command. This is not an
//    exotic path: it is exactly what a v1.x card does to CMD8, which is how the
//    driver detects card version in the first place. See S_RESP.
//
// 2. THE STUFF BYTE AFTER CMD12 (§7.2.3). One byte must be discarded before
//    CMD12's R1 response is read. S_RESP_WAIT handles it by construction -
//    it skips every 0xFF until a byte with bit 7 clear - but only because the
//    stuff byte is not a valid response; it is called out here because a
//    fixed-length response reader would break on it.
//
// 3. THE WRITE ENDS ONE BYTE LATE (§7.2.4). The card's internal programming
//    begins a byte AFTER the data response token, so eight clocks must be
//    issued before `busy` means anything at all. Checking MISO immediately
//    after the token reads the bus before the card has taken it.
//
// 4. TWO DIFFERENT TERMINATIONS FOR A MULTI-BLOCK WRITE (§7.3.3.1). A clean
//    stream ends with the Stop Tran token 0xFD. One that failed must be stopped
//    with CMD12 instead. Using the token to end a failed transfer leaves the
//    card in a state the driver cannot interrogate.
//
// -----------------------------------------------------------------------------
// PRE-EMPTIVE BUSY CHECKING
// -----------------------------------------------------------------------------
// The naive write loop sends a block and then waits for the card to release
// busy. The card is idle during that wait while the host does nothing useful.
// This sequencer instead waits for busy to clear IMMEDIATELY BEFORE the next
// command or data packet, and not at all after the previous one - so the card's
// programming time overlaps with the host's preparation and with the DMA
// refilling the FIFO.
//
// On a multi-block write, where the card programs after every block, this is
// most of the difference between the card's rate and the bus's rate.
// =============================================================================

module avalon_mm_sdcard_controller_seq
    import avalon_mm_sdcard_controller_pkg::*;
    import avalon_mm_sdcard_controller_crc_pkg::crc16_byte;
#(
    parameter int unsigned MAX_BLOCK_BYTES = 512,
    parameter int unsigned TIMEOUT_WIDTH   = 26,
    parameter int unsigned BLKCNT_WIDTH    = 16
) (
    input  logic                        clk,
    input  logic                        reset_n,
    input  logic                        srst,          // soft reset, data path

    // ---- command interface (from regs) -------------------------------------
    input  logic                        cmd_start,     // one-cycle pulse
    input  logic [5:0]                  cmd_index,
    input  logic [31:0]                 cmd_arg,
    input  resp_e                       cmd_resp_type,
    input  logic                        cmd_data_en,
    input  logic                        cmd_data_dir,  // 1 = host -> card
    input  logic                        cmd_multi,
    input  logic                        cmd_auto_stop,

    input  logic [$clog2(MAX_BLOCK_BYTES+1)-1:0] blk_size,
    input  logic [BLKCNT_WIDTH-1:0]     blk_count,
    input  logic [TIMEOUT_WIDTH-1:0]    timeout,
    input  logic                        crc_en,

    // ---- status ------------------------------------------------------------
    output logic                        busy,
    output logic                        dat_busy,
    output logic                        card_busy,
    output logic                        cmd_done,      // pulse: command complete
    output logic                        data_done,     // pulse: whole transfer complete
    output logic [31:0]                 resp0,
    output logic [31:0]                 resp1,
    output logic [7:0]                  err_flags,     // see IRQ_ERR_* ordering below
    output logic [7:0]                  last_r1,
    output logic [7:0]                  last_datresp,
    output logic [7:0]                  last_daterr,
    output phase_e                      err_phase,

    // ---- shifter -----------------------------------------------------------
    output logic                        phy_run,
    output logic                        phy_tx_idle,
    output logic [7:0]                  phy_tx_data,
    output logic                        phy_tx_we,
    input  logic                        phy_tx_ready,
    input  logic [7:0]                  phy_rx_data,
    input  logic                        phy_rx_valid,

    // The shifter is byte-atomic: when a transaction ends it keeps clocking
    // until the byte in flight completes. That trailing byte is wanted - §7.2.4
    // notes the card releases MISO synchronously to the clock, so a byte after
    // CS deasserts is what actually frees the line. What must NOT happen is the
    // next transaction starting during it.
    input  logic                        phy_idle,

    output logic                        sd_cs_n,

    // ---- FIFO byte side ----------------------------------------------------
    output logic                        fifo_clear,
    output logic                        fifo_dir_h2c,
    output logic                        fifo_b_wr,
    output logic [7:0]                  fifo_b_wdata,
    input  logic                        fifo_b_full,
    output logic                        fifo_b_rd,
    input  logic [7:0]                  fifo_b_rdata,
    input  logic                        fifo_b_empty,
    output logic                        fifo_flush,

    // ---- DMA ---------------------------------------------------------------
    output logic                        dma_start,
    output logic                        dma_dir_h2c,
    output logic                        dma_keep_addr,  // continue, do not reload
    output logic                        dma_abort,      // finish the burst, then stop
    output logic [BLKCNT_WIDTH-1:0]     dma_len_words,
    input  logic                        dma_busy,
    input  logic                        dma_err
);

    localparam int unsigned BCW = $clog2(MAX_BLOCK_BYTES + 1);

    // err_flags bit order, matching IRQ_ERR_* in the package offset by 8.
    localparam int E_CMD_TMO   = 0;
    localparam int E_CMD_CRC   = 1;
    localparam int E_CMD_ILL   = 2;
    localparam int E_DAT_TMO   = 3;
    localparam int E_DAT_CRC   = 4;
    localparam int E_DAT_TOKEN = 5;
    localparam int E_WRITE     = 6;
    localparam int E_DMA       = 7;

    typedef enum logic [4:0] {
        S_IDLE,
        S_PRE_BUSY,     // pre-emptive: wait for MISO, then send the command
        S_PRE_BUSY_W,   // pre-emptive: wait for MISO, then send the next block
        S_CMD,          // shift the six command bytes
        S_RESP_WAIT,    // shift 0xFF until a byte with bit 7 clear
        S_RESP_TRAIL,   // R2 / R3 / R7 trailer
        S_R1B_BUSY,     // R1b: wait for busy to lift
        S_DAT_START,
        S_RD_TOKEN,     // wait for 0xFE, or a data error token
        S_RD_DATA,
        S_RD_CRC,
        S_WR_TOKEN,
        S_WR_DATA,
        S_WR_CRC,
        S_WR_RESP,      // data response token
        S_WR_TAIL,      // the eight clocks before busy means anything
        S_BLOCK_END,
        S_STOP_TRAN,    // 0xFD, clean end of a multi-block write
        S_DONE,
        S_ABORT
    } state_e;

    state_e state;

    // Bytes handed to the shifter in the current state. Reset on every state
    // change, incremented on acceptance - the transmit side's own counter,
    // independent of how far the receive side has got.
    logic [BCW-1:0]             q_cnt;
    state_e                     state_prev;

    logic [2:0]                 trail_cnt;
    logic [BCW-1:0]             byte_cnt;
    logic [1:0]                 crc_cnt;
    logic [BLKCNT_WIDTH-1:0]    blocks_left;
    logic [TIMEOUT_WIDTH-1:0]   tmo;
    logic [3:0]                 ncr_cnt;
    logic                       stopping;      // this command is the auto CMD12
    logic                       cmd_pending;   // request held until the shifter drains
    logic                       multi_q, dir_q, autostop_q, data_q;
    logic [5:0]                 index_q;
    logic [31:0]                arg_q;
    resp_e                      resp_q;

    // ---- CRC engines --------------------------------------------------------
    logic       crc7_clear, crc7_en;
    logic [6:0] crc7_val;
    logic        crc16_tx_clear, crc16_tx_en;
    logic [15:0] crc16_tx_val;
    logic        crc16_rx_clear, crc16_rx_en;
    logic [15:0] crc16_rx_val;

    // A byte has completed on the wire (receive side).
    logic tick;
    always_comb tick = phy_rx_valid;

    // A byte has been ACCEPTED into the shifter's prefetch (transmit side).
    // The two are not the same event and must not be conflated: the transmit
    // side necessarily runs one byte ahead of the receive side, so a counter
    // driven by `tick` cannot be used to select what to send next - it would
    // offer the same byte twice while waiting for the previous one to land.
    logic tx_accept;
    always_comb tx_accept = phy_tx_we;

    avalon_mm_sdcard_controller_crc7 u_crc7 (
        .clk (clk), .reset_n (reset_n),
        .clear (crc7_clear), .en (crc7_en), .byte_in (cmd_byte_val),
        .crc (crc7_val)
    );

    avalon_mm_sdcard_controller_crc16 u_crc16_tx (
        .clk (clk), .reset_n (reset_n),
        .clear (crc16_tx_clear), .en (crc16_tx_en), .byte_in (fifo_b_rdata),
        .crc (crc16_tx_val)
    );

    avalon_mm_sdcard_controller_crc16 u_crc16_rx (
        .clk (clk), .reset_n (reset_n),
        .clear (crc16_rx_clear), .en (crc16_rx_en), .byte_in (phy_rx_data),
        .crc (crc16_rx_val)
    );

    // CRC7 covers the five framed bytes, not the CRC byte itself. Accumulated
    // as each is handed to the shifter, so the result is ready by the time the
    // sixth byte - the CRC - is selected.
    always_comb crc7_en = tx_accept && (state == S_CMD) && (q_cnt < BCW'(5));

    // CRC16 on transmit covers the block payload only: not the start token and
    // not the two CRC bytes. Fed at pop time, so it sees exactly the bytes that
    // went to the card.
    always_comb crc16_tx_en = tx_accept && (state == S_WR_DATA);

    // On receive the accumulation deliberately CONTINUES through the two
    // incoming CRC bytes, because a CRC16 seeded with zero returns to zero when
    // its own remainder is fed back in - so S_RD_CRC checks for zero rather
    // than latching an expected value and comparing.
    always_comb crc16_rx_en = tick && ((state == S_RD_DATA) || (state == S_RD_CRC));

    // Received-byte classifiers.
    logic rx_is_resp, rx_is_idle_ff, rx_is_start_tok, rx_is_daterr_tok;
    always_comb begin
        rx_is_resp       = !phy_rx_data[7];               // R1: MSB always 0
        rx_is_idle_ff    = (phy_rx_data == 8'hFF);
        rx_is_start_tok  = (phy_rx_data == TOKEN_START_BLOCK);
        rx_is_daterr_tok = ((phy_rx_data & DATERR_MASK) == 8'h00);
    end

    // The card signals busy by holding MISO low; any non-zero byte means ready.
    // Registered from the last byte sampled in a busy-waiting state, so STATUS
    // reports what the card is actually doing rather than a transient.
    logic card_busy_q;
    always_comb card_busy = card_busy_q;

    // ---- command byte multiplexer -------------------------------------------
    // Indexed by the QUEUE counter, not the completion counter.
    logic [7:0] cmd_byte_val;
    always_comb begin
        unique case (q_cnt[2:0])
            3'd0:    cmd_byte_val = {CMD_FRAME_START, index_q};
            3'd1:    cmd_byte_val = arg_q[31:24];
            3'd2:    cmd_byte_val = arg_q[23:16];
            3'd3:    cmd_byte_val = arg_q[15:8];
            3'd4:    cmd_byte_val = arg_q[7:0];
            default: cmd_byte_val = {crc7_val, 1'b1};   // stop bit fills bit 0
        endcase
    end

    // ---- outgoing byte selection --------------------------------------------
    //
    // Every sending state is bounded by q_cnt, the count of bytes already
    // handed to the shifter in this state. Without that bound a state keeps
    // re-offering its current byte for as long as it is active - and since the
    // state only advances when the RECEIVE side ticks, one byte behind, the
    // same byte is accepted twice and the whole frame shifts.
    logic [7:0] tx_byte;
    logic       tx_want;
    always_comb begin
        tx_want = 1'b0;
        tx_byte = MOSI_IDLE;
        unique case (state)
            S_CMD: begin
                tx_want = (q_cnt < BCW'(6));
                tx_byte = cmd_byte_val;
            end
            S_WR_TOKEN: begin
                tx_want = (q_cnt < BCW'(1));
                tx_byte = multi_q ? TOKEN_START_MULTI_W : TOKEN_START_BLOCK;
            end
            S_WR_DATA: begin
                tx_want = (q_cnt < BCW'(blk_size)) && !fifo_b_empty;
                tx_byte = fifo_b_rdata;
            end
            S_WR_CRC: begin
                // crc16_tx_val is frozen the moment S_WR_DATA ends, because its
                // enable is gated on that state - so it can be read directly
                // with no holding register.
                tx_want = (q_cnt < BCW'(2));
                tx_byte = (q_cnt == BCW'(0)) ? crc16_tx_val[15:8]
                                             : crc16_tx_val[7:0];
            end
            S_STOP_TRAN: begin
                tx_want = (q_cnt < BCW'(1));
                tx_byte = TOKEN_STOP_TRAN;
            end
            default: ;
        endcase
    end

    // Receive states clock 0xFF out to pull data from the card; sending states
    // must never do that.
    //
    // Deriving tx_idle from `!tx_want` looks equivalent and is not. A sending
    // state stops wanting bytes as soon as it has queued its last one, but it
    // does not leave until the RECEIVE side ticks - one byte later. In that
    // window `!tx_want` is true, and the shifter would helpfully emit a 0xFF
    // that nobody asked for, landing an extra byte inside the data block. The
    // card then computes a different CRC16 and rejects the write, which reads
    // as a CRC fault rather than as a framing one.
    logic rx_state;
    always_comb begin
        unique case (state)
            // S_DONE belongs with the SENDING states even though it sends
            // nothing of its own: it must not raise tx_idle, or the shifter
            // would clock 0xFF forever while the sequencer waits for it to go
            // quiet.
            S_CMD, S_WR_TOKEN, S_WR_DATA, S_WR_CRC, S_STOP_TRAN, S_DONE:
                     rx_state = 1'b0;
            default: rx_state = 1'b1;
        endcase
    end

    always_comb begin
        phy_tx_data = tx_byte;
        phy_tx_we   = tx_want && phy_tx_ready && (state != S_IDLE);
        phy_tx_idle = rx_state;

        // `run` stays asserted through S_DONE so a byte still sitting in the
        // shifter's prefetch is actually transmitted. Dropping it at the end of
        // the last sending state strands that byte: the shifter will not load
        // from the prefetch without `run`.
        phy_run     = (state != S_IDLE);
    end

    // Pop the FIFO exactly when a write-data byte is accepted by the shifter.
    always_comb fifo_b_rd = (state == S_WR_DATA) && tx_accept;

    // Queue counter. Held in its own always_ff so every sending state gets the
    // same reset-on-entry behaviour without repeating it in each branch.
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            q_cnt      <= '0;
            state_prev <= S_IDLE;
        end else begin
            state_prev <= state;
            // The reset and the increment can coincide: the shifter's prefetch
            // is empty on entry to a sending state, so the very first byte is
            // often accepted on the same cycle the state changes. Resetting to
            // zero there loses that acceptance, the second byte is offered as
            // the first, and the frame goes out with its opening byte
            // duplicated and its last byte missing - which a card reports as a
            // CRC error, pointing at entirely the wrong thing.
            if (state != state_prev) q_cnt <= tx_accept ? BCW'(1) : BCW'(0);
            else if (tx_accept)      q_cnt <= q_cnt + BCW'(1);
        end
    end

    always_comb begin
        fifo_b_wr    = (state == S_RD_DATA) && tick && !fifo_b_full;
        fifo_b_wdata = phy_rx_data;
    end

    always_comb begin
        // `cmd_pending` counts as busy. A command that has been accepted but is
        // still waiting for the shifter to drain has not finished, and software
        // polling STATUS.CMD_BUSY must not see it as idle - otherwise the very
        // first poll after writing CMD returns "done" for a command that has
        // not yet put a single bit on the wire.
        busy     = (state != S_IDLE) || cmd_pending;
        dat_busy = data_q && (state != S_IDLE);
        sd_cs_n  = (state == S_IDLE);   // asserted low for the whole transaction
    end

    // One DMA transfer per BLOCK, not per multi-block command.
    //
    // The alternative - one transfer of blk_size/4 * blk_count words - needs a
    // 16x8 multiply for a number that is only ever consumed by an adder, which
    // is real DSP or LUT cost on a MAX 10 for no benefit. Pulsing the DMA once
    // per block and having it CONTINUE its address (dma_keep_addr) gives the
    // same contiguous transfer with an increment instead of a multiply.
    always_comb begin
        dma_dir_h2c   = dir_q;
        fifo_dir_h2c  = dir_q;
        dma_len_words = (BLKCNT_WIDTH'(blk_size) + BLKCNT_WIDTH'(3)) >> 2;
    end

    // -------------------------------------------------------------------------
    // Main sequencer
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state        <= S_IDLE;
            trail_cnt    <= '0;
            byte_cnt     <= '0;
            crc_cnt      <= '0;
            blocks_left  <= '0;
            tmo          <= '0;
            ncr_cnt      <= '0;
            stopping     <= 1'b0;
            cmd_pending  <= 1'b0;
            multi_q      <= 1'b0;
            dir_q        <= 1'b0;
            autostop_q   <= 1'b0;
            data_q       <= 1'b0;
            index_q      <= '0;
            arg_q        <= '0;
            resp_q       <= RESP_R1;
            resp0        <= '0;
            resp1        <= '0;
            err_flags    <= '0;
            last_r1      <= '0;
            last_datresp <= '0;
            last_daterr  <= '0;
            err_phase    <= PHASE_IDLE;
            cmd_done      <= 1'b0;
            data_done     <= 1'b0;
            dma_start     <= 1'b0;
            dma_keep_addr <= 1'b0;
            card_busy_q   <= 1'b0;
            fifo_clear    <= 1'b0;
            fifo_flush   <= 1'b0;
            crc7_clear   <= 1'b1;
            crc16_tx_clear <= 1'b1;
            crc16_rx_clear <= 1'b1;
        end else begin
            cmd_done       <= 1'b0;
            data_done      <= 1'b0;
            dma_start      <= 1'b0;
            fifo_clear     <= 1'b0;
            fifo_flush     <= 1'b0;
            crc7_clear     <= 1'b0;
            crc16_tx_clear <= 1'b0;
            crc16_rx_clear <= 1'b0;

            if (srst) begin
                state <= S_IDLE;
            end else begin

                // Every waiting state is bounded. A card that stops answering
                // must not wedge the core; `timeout` is the outer bound and the
                // phase is recorded so the driver can tell "never answered"
                // from "answered and then stopped".
                if (state != S_IDLE) tmo <= tmo + 1'b1;

                unique case (state)

                    // -----------------------------------------------------
                    S_IDLE: begin
                        tmo <= '0;

                        // Latch the request. cmd_start is a one-cycle pulse and
                        // the shifter may still be draining, so holding it is
                        // the difference between a deferred command and a lost
                        // one.
                        if (cmd_start) cmd_pending <= 1'b1;

                        // Starting while the shifter is still clocking makes
                        // CS fall in the middle of a clock period. The card
                        // then takes its bit boundary from the wrong edge and
                        // every byte of the transaction arrives shifted by one
                        // bit - a failure that looks like a CRC or wiring fault
                        // and is neither.
                        if ((cmd_start || cmd_pending) && phy_idle) begin
                            cmd_pending <= 1'b0;
                            index_q    <= cmd_index;
                            arg_q      <= cmd_arg;
                            resp_q     <= cmd_resp_type;
                            data_q     <= cmd_data_en;
                            dir_q      <= cmd_data_dir;
                            multi_q    <= cmd_multi;
                            autostop_q <= cmd_auto_stop;
                            blocks_left<= cmd_multi ? blk_count : BLKCNT_WIDTH'(1);
                            stopping   <= 1'b0;
                            err_flags  <= '0;
                            err_phase  <= PHASE_IDLE;
                            byte_cnt   <= '0;
                            ncr_cnt    <= '0;
                            crc7_clear <= 1'b1;
                            fifo_clear <= 1'b1;
                            state      <= S_PRE_BUSY;

                            // Start the DMA for a host->card transfer NOW, while
                            // the command is still being framed. Six command
                            // bytes plus the response is at least a dozen
                            // byte-times - 400+ system clocks at CLKDIV=2 -
                            // which is comfortably longer than a 128-word burst
                            // needs. Waiting until the data phase would leave
                            // only the single start-token byte-time, and the
                            // shifter would stall on an empty FIFO.
                            if (cmd_data_en && cmd_data_dir) begin
                                dma_start     <= 1'b1;
                                dma_keep_addr <= 1'b0;   // first block: load addr
                            end
                        end
                    end

                    // -----------------------------------------------------
                    // Pre-emptive busy check. Costs nothing when the card is
                    // already idle - one byte-time - and saves a whole card
                    // programming time when it is not.
                    S_PRE_BUSY: begin
                        if (tick) begin
                            card_busy_q <= (phy_rx_data == 8'h00);
                            if (phy_rx_data != 8'h00) begin
                                // NOT crc7_clear here. The clear would be
                                // asserted during the first cycle of S_CMD,
                                // which is exactly when the first byte is
                                // accepted (the prefetch is empty on entry), so
                                // it would wipe that byte's contribution and
                                // send a CRC computed over four bytes instead
                                // of five. The accumulator was already cleared
                                // when the command was latched.
                                state <= S_CMD;
                                tmo   <= '0;
                            end else if (tmo >= timeout) begin
                                err_flags[E_DAT_TMO] <= 1'b1;
                                err_phase <= PHASE_BUSY;
                                state     <= S_ABORT;
                            end
                        end
                    end

                    // Same check, different destination: this one guards the
                    // next DATA BLOCK of a multi-block write rather than a
                    // command. It is where the card's programming time for the
                    // previous block is actually absorbed, overlapped with the
                    // DMA refilling the FIFO.
                    S_PRE_BUSY_W: begin
                        if (tick) begin
                            card_busy_q <= (phy_rx_data == 8'h00);
                            if (phy_rx_data != 8'h00) begin
                                tmo   <= '0;
                                state <= S_WR_TOKEN;
                            end else if (tmo >= timeout) begin
                                err_flags[E_DAT_TMO] <= 1'b1;
                                err_phase <= PHASE_BUSY;
                                state     <= S_ABORT;
                            end
                        end
                    end

                    // -----------------------------------------------------
                    S_CMD: begin
                        if (tick) begin
                            if (byte_cnt == BCW'(5)) begin
                                byte_cnt <= '0;
                                ncr_cnt  <= '0;
                                tmo      <= '0;
                                state    <= S_RESP_WAIT;
                            end else begin
                                byte_cnt <= byte_cnt + BCW'(1);
                            end
                        end
                    end

                    // -----------------------------------------------------
                    // N_CR is 0-8 byte-times. The response is the first byte
                    // with bit 7 clear; everything before it is 0xFF, including
                    // the stuff byte that follows CMD12.
                    S_RESP_WAIT: begin
                        if (tick) begin
                            if (rx_is_resp) begin
                                last_r1 <= phy_rx_data;
                                resp0   <= {24'h0, phy_rx_data};
                                tmo     <= '0;

                                if (phy_rx_data[R1_COM_CRC_ERR])
                                    err_flags[E_CMD_CRC] <= 1'b1;
                                if (phy_rx_data[R1_ILLEGAL_CMD])
                                    err_flags[E_CMD_ILL] <= 1'b1;

                                // §7.3.2: on Illegal Command or Command CRC
                                // Error the card sends ONLY this byte. Reading
                                // a trailer that will never arrive would eat
                                // the next command's bytes.
                                if (phy_rx_data[R1_COM_CRC_ERR] ||
                                    phy_rx_data[R1_ILLEGAL_CMD]) begin
                                    cmd_done <= 1'b1;
                                    state    <= S_ABORT;
                                end else begin
                                    unique case (resp_q)
                                        RESP_R1: begin
                                            cmd_done  <= 1'b1;
                                            // `stopping` means this command was
                                            // the auto CMD12 closing a
                                            // multi-block read: its completion
                                            // IS the transfer's completion.
                                            if (stopping) data_done <= 1'b1;
                                            state <= data_q ? S_DAT_START : S_DONE;
                                        end
                                        RESP_R1B: begin
                                            state <= S_R1B_BUSY;
                                        end
                                        RESP_R2: begin
                                            trail_cnt <= 3'd1;
                                            state     <= S_RESP_TRAIL;
                                        end
                                        RESP_R3R7: begin
                                            trail_cnt <= 3'd4;
                                            state     <= S_RESP_TRAIL;
                                        end
                                        default: state <= S_DONE;
                                    endcase
                                end
                            end else begin
                                ncr_cnt <= ncr_cnt + 4'd1;
                                if ((ncr_cnt >= 4'(NCR_MAX_BYTES)) || (tmo >= timeout)) begin
                                    err_flags[E_CMD_TMO] <= 1'b1;
                                    err_phase <= PHASE_RESP;
                                    state     <= S_ABORT;
                                end
                            end
                        end
                    end

                    // -----------------------------------------------------
                    S_RESP_TRAIL: begin
                        if (tick) begin
                            resp1 <= {resp1[23:0], phy_rx_data};
                            if (trail_cnt == 3'd1) begin
                                cmd_done <= 1'b1;
                                state    <= data_q ? S_DAT_START : S_DONE;
                            end else begin
                                trail_cnt <= trail_cnt - 3'd1;
                            end
                        end
                    end

                    // -----------------------------------------------------
                    S_R1B_BUSY: begin
                        if (tick) begin
                            card_busy_q <= (phy_rx_data == 8'h00);
                            if (phy_rx_data != 8'h00) begin
                                cmd_done <= 1'b1;
                                if (stopping) data_done <= 1'b1;
                                state    <= data_q ? S_DAT_START : S_DONE;
                            end else if (tmo >= timeout) begin
                                err_flags[E_DAT_TMO] <= 1'b1;
                                err_phase <= PHASE_BUSY;
                                state     <= S_ABORT;
                            end
                        end
                    end

                    // -----------------------------------------------------
                    S_DAT_START: begin
                        byte_cnt       <= '0;
                        crc_cnt        <= '0;
                        tmo            <= '0;
                        crc16_tx_clear <= 1'b1;
                        crc16_rx_clear <= 1'b1;
                        state <= dir_q ? S_WR_TOKEN : S_RD_TOKEN;

                        // Card->host: the DMA drains the FIFO as bytes land, so
                        // it starts here rather than up front. (Host->card
                        // started at S_IDLE, because that direction must have
                        // data ready BEFORE the block begins.)
                        if (!dir_q) begin
                            dma_start     <= 1'b1;
                            dma_keep_addr <= 1'b0;
                        end
                    end

                    // ---- read path --------------------------------------
                    S_RD_TOKEN: begin
                        if (tick) begin
                            if (rx_is_start_tok) begin
                                byte_cnt       <= '0;
                                crc16_rx_clear <= 1'b1;
                                tmo            <= '0;
                                state          <= S_RD_DATA;
                            end else if (rx_is_daterr_tok) begin
                                // Upper nibble zero: the card is reporting a
                                // read failure instead of sending a block.
                                last_daterr <= phy_rx_data;
                                err_flags[E_DAT_TOKEN] <= 1'b1;
                                err_phase   <= PHASE_TOKEN;
                                state       <= S_ABORT;
                            end else if (tmo >= timeout) begin
                                err_flags[E_DAT_TMO] <= 1'b1;
                                err_phase <= PHASE_TOKEN;
                                state     <= S_ABORT;
                            end
                        end
                    end

                    S_RD_DATA: begin
                        if (tick) begin
                            if (byte_cnt == BCW'(blk_size - 1)) begin
                                crc_cnt <= '0;
                                state   <= S_RD_CRC;
                            end else begin
                                byte_cnt <= byte_cnt + BCW'(1);
                            end
                        end
                    end

                    S_RD_CRC: begin
                        if (tick) begin
                            if (crc_cnt == 2'd1) begin
                                // The accumulation runs through both CRC bytes,
                                // so an intact block leaves the register at
                                // zero. Anything else is a corrupt block.
                                //
                                // The final byte must be folded in
                                // COMBINATIONALLY here rather than read from
                                // the register: crc16_rx_en fires this cycle
                                // too, but its result is only visible next
                                // cycle. Reading crc16_rx_val directly checks
                                // the CRC one byte early - which fails on every
                                // block, always, and looks exactly like a
                                // wiring or polynomial fault.
                                if (crc_en &&
                                    (crc16_byte(crc16_rx_val, phy_rx_data) != 16'h0000)) begin
                                    err_flags[E_DAT_CRC] <= 1'b1;
                                    err_phase <= PHASE_CRC;
                                    state     <= S_ABORT;
                                end else begin
                                    fifo_flush <= 1'b1;
                                    state      <= S_BLOCK_END;
                                end
                            end else begin
                                crc_cnt <= crc_cnt + 2'd1;
                            end
                        end
                    end

                    // ---- write path -------------------------------------
                    S_WR_TOKEN: begin
                        if (tick) begin
                            // Same reasoning as S_PRE_BUSY above: no CRC clear
                            // on the way into a state whose first byte may be
                            // accepted immediately. S_DAT_START and S_BLOCK_END
                            // already cleared it, and neither S_WR_TOKEN nor
                            // anything before it feeds the accumulator.
                            byte_cnt <= '0;
                            tmo      <= '0;
                            state    <= S_WR_DATA;
                        end
                    end

                    S_WR_DATA: begin
                        if (tick) begin
                            if (byte_cnt == BCW'(blk_size - 1)) begin
                                crc_cnt <= '0;
                                state         <= S_WR_CRC;
                            end else begin
                                byte_cnt <= byte_cnt + BCW'(1);
                            end
                        end
                    end

                    S_WR_CRC: begin
                        if (tick) begin
                            if (crc_cnt == 2'd1) begin
                                tmo   <= '0;
                                state <= S_WR_RESP;
                            end else begin
                                crc_cnt <= crc_cnt + 2'd1;
                            end
                        end
                    end

                    S_WR_RESP: begin
                        if (tick) begin
                            if ((phy_rx_data & DATRESP_MASK) == DATRESP_ACCEPTED) begin
                                last_datresp <= phy_rx_data;
                                state        <= S_WR_TAIL;
                            end else if (!rx_is_idle_ff) begin
                                last_datresp <= phy_rx_data;
                                // CRC error or write error. §7.3.3.1: a failed
                                // multi-block write is stopped with CMD12, not
                                // with the stop-tran token - which is why this
                                // goes to S_ABORT rather than S_STOP_TRAN.
                                err_flags[E_WRITE] <= 1'b1;
                                err_phase <= PHASE_DATRESP;
                                state     <= S_ABORT;
                            end else if (tmo >= timeout) begin
                                err_flags[E_DAT_TMO] <= 1'b1;
                                err_phase <= PHASE_DATRESP;
                                state     <= S_ABORT;
                            end
                        end
                    end

                    // §7.2.4: programming starts a byte AFTER the data
                    // response, so one byte-time must pass before MISO means
                    // anything. Busy itself is then absorbed by the pre-emptive
                    // check ahead of the next packet rather than waited on here.
                    S_WR_TAIL: begin
                        if (tick) state <= S_BLOCK_END;
                    end

                    // -----------------------------------------------------
                    S_BLOCK_END: begin
                        if (blocks_left <= BLKCNT_WIDTH'(1)) begin
                            if (multi_q && autostop_q && dir_q) begin
                                // Clean end of a multi-block WRITE: the stop is
                                // a token on the data line, not a command.
                                state <= S_STOP_TRAN;
                            end else if (multi_q && autostop_q && !dir_q) begin
                                // End of a multi-block READ: the card is still
                                // streaming and only CMD12 stops it. Re-enter
                                // the command path with `stopping` set so the
                                // response handler finishes the transfer rather
                                // than starting a data phase.
                                //
                                // §7.2.3: the byte immediately after CMD12 is a
                                // stuff byte. S_RESP_WAIT discards it for free,
                                // because it skips everything until a byte with
                                // bit 7 clear and the stuff byte is 0xFF.
                                stopping  <= 1'b1;
                                index_q   <= 6'd12;
                                arg_q     <= 32'h0;
                                resp_q    <= RESP_R1B;
                                data_q    <= 1'b0;
                                byte_cnt  <= '0;
                                ncr_cnt   <= '0;
                                tmo       <= '0;
                                crc7_clear<= 1'b1;
                                state     <= S_PRE_BUSY;
                            end else begin
                                data_done <= 1'b1;
                                state     <= S_DONE;
                            end
                        end else begin
                            blocks_left <= blocks_left - BLKCNT_WIDTH'(1);
                            byte_cnt    <= '0;
                            tmo         <= '0;
                            crc16_tx_clear <= 1'b1;
                            crc16_rx_clear <= 1'b1;

                            // Another block's worth of DMA, continuing from
                            // where the last one stopped rather than reloading
                            // the base address.
                            dma_start     <= 1'b1;
                            dma_keep_addr <= 1'b1;

                            // Next block. On the write side the pre-emptive
                            // busy check runs first; on the read side the card
                            // streams straight into the next start token.
                            state <= dir_q ? S_PRE_BUSY_W : S_RD_TOKEN;
                        end
                    end

                    S_STOP_TRAN: begin
                        if (tick) begin
                            data_done <= 1'b1;
                            state     <= S_DONE;
                        end
                    end

                    // -----------------------------------------------------
                    // A transaction is not over until BOTH the DMA has drained
                    // and the shifter has gone quiet.
                    //
                    // The shifter half is the subtle one. Sending states exit
                    // on a receive tick, and the transmit side runs a byte
                    // ahead - so the last byte of a transfer (the stop-tran
                    // token ending a multi-block write, most visibly) is still
                    // in flight when the state machine believes it is finished.
                    // Clearing busy there tells software the transfer completed
                    // while a byte of it has not yet reached the card, and the
                    // next command is then issued on top of it.
                    S_DONE: begin
                        if (!dma_busy && phy_idle) begin
                            if (dma_err) err_flags[E_DMA] <= 1'b1;
                            dma_abort <= 1'b0;
                            state     <= S_IDLE;
                        end else begin
                            // Release the error levels once the CSR has had
                            // them. IRQ_STATUS is the sticky record - that is
                            // its whole job - and holding these asserted as
                            // well means software cannot clear the register:
                            // the write lands, and the level immediately sets
                            // the bit again. The persistent diagnostic detail
                            // stays in ERR_INFO, which is not self-clearing.
                            err_flags <= '0;
                        end
                    end

                    // An aborted transfer drains the same way a successful one
                    // does. Returning straight to idle would leave a DMA burst
                    // in flight and bytes in the shifter, both of which then
                    // collide with whatever software issues next - so a card
                    // that rejects one block wedges every command after it.
                    // Avalon also forbids abandoning a burst part-way.
                    S_ABORT: begin
                        data_done <= 1'b1;
                        dma_abort <= 1'b1;   // held until S_IDLE
                        state     <= S_DONE;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule : avalon_mm_sdcard_controller_seq
