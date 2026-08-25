`timescale 1ns/1ps

// =============================================================================
// demo_avl_mm_master.sv
//
// Minimal synthesisable Avalon-MM master, single-outstanding, BURST CAPABLE,
// driven by a simple request/done handshake. The demo sequencer instantiates
// two of these: one aimed at the firewall's `csr` port (the "software" side)
// and one aimed at its `s0` data port (the "CPU or DMA issuing transactions"
// side).
//
// Request protocol:
//   assert `req` for one cycle together with req_write/req_addr/req_wdata/
//   req_burst. `busy` goes high in that same cycle and stays high until the
//   transaction completes; `done` pulses for one cycle when it does, with
//   `resp`, `rdata`, `beats`, `data_ok` and `cycles` valid from that cycle on.
//
// `busy` spans BOTH ends of the transaction, and both terms are load-bearing:
//
//   || req    without it, a caller that issues on cycle N and tests !busy on
//            cycle N+1 sees the state machine having only just left M_IDLE -
//            the classic window in which a request looks already finished.
//
//   || done   the results are registered, so they are only readable the cycle
//            AFTER the last beat - by which point the state machine is already
//            back in M_IDLE. Without this term a caller gating on !busy runs
//            its next instruction in the same cycle the results land and
//            therefore reads the PREVIOUS transaction's values. That is not a
//            subtle skew; it silently shifts every check in the program one
//            step, and the failures it produces look like unrelated bugs in
//            whatever the previous scenario did.
//
// The contract is therefore: busy stays high until the results are visible.
//
// BURST DATA is a ramp, not a buffer. A write burst drives req_wdata,
// req_wdata+1, req_wdata+2 ...; a read burst checks each beat against the
// same ramp and reports one `data_ok` bit. That is enough to prove a burst
// moved the right bytes in the right order without carrying a scratch buffer
// through the sequencer, and it is what makes "did this burst actually reach
// the peripheral?" a single-bit check in the program.
//
// `cycles` counts from the request to completion, so the program can assert
// the core's headline claim - one beat per cycle, no added latency - on real
// silicon rather than only in simulation.
//
// THE WATCHDOG is not decoration. The firewall's guarantee is that every
// transaction completes: a violation, a block and a downstream timeout all
// produce a response rather than a stall. If that guarantee ever failed on
// hardware the board would simply freeze, which is indistinguishable from a
// bad bitstream. `stuck` turns that into a visible, reportable failure. It
// should never fire, and the scenario program checks that it does not.
// =============================================================================

module demo_avl_mm_master #(
    parameter int ADDR_WIDTH         = 32,
    parameter int DATA_WIDTH         = 32,
    parameter int BURST_WIDTH        = 8,
    parameter int USE_WRITE_RESPONSE = 1,
    parameter int WATCHDOG_BITS      = 20   // 2^20 / 50 MHz = 21 ms
) (
    input  logic                     clk,
    input  logic                     resetn,

    // ------------------------- request / result ---------------------------
    input  logic                     req,        // one-cycle start pulse
    input  logic                     req_write,  // 1 = write, 0 = read
    input  logic [ADDR_WIDTH-1:0]    req_addr,
    input  logic [DATA_WIDTH-1:0]    req_wdata,  // seed of the data ramp
    input  logic [BURST_WIDTH-1:0]   req_burst,  // beats; 1 = single access
    output logic                     busy,
    output logic                     done,       // one-cycle completion pulse
    output logic                     done_write, // qualifies `done`: was a write
    output logic [DATA_WIDTH-1:0]    rdata,      // last beat received
    output logic [1:0]               resp,       // response seen
    output logic [BURST_WIDTH:0]     beats,      // beats transferred
    output logic                     data_ok,    // read beats matched the ramp
    output logic [15:0]              cycles,     // req -> done, saturating
    output logic                     stuck,      // watchdog fired

    // ------------------------- Avalon-MM master ---------------------------
    output logic [ADDR_WIDTH-1:0]    m_address,
    output logic                     m_read,
    output logic                     m_write,
    output logic [DATA_WIDTH-1:0]    m_writedata,
    output logic [DATA_WIDTH/8-1:0]  m_byteenable,
    output logic [BURST_WIDTH-1:0]   m_burstcount,
    input  logic                     m_waitrequest,
    input  logic [DATA_WIDTH-1:0]    m_readdata,
    input  logic                     m_readdatavalid,
    input  logic [1:0]               m_response,
    input  logic                     m_writeresponsevalid
);

    localparam bit HAS_WRESP = (USE_WRITE_RESPONSE != 0);

    typedef enum logic [2:0] {
        M_IDLE,
        M_WR,        // driving write beats
        M_WRESP,     // last beat gone, waiting for writeresponsevalid
        M_RD,        // read command asserted, waiting for it to be taken
        M_RDATA      // command taken, collecting beats
    } state_e;

    state_e state;

    logic [ADDR_WIDTH-1:0]  addr_r;
    logic [DATA_WIDTH-1:0]  seed_r;
    logic [BURST_WIDTH-1:0] burst_r;
    logic [BURST_WIDTH:0]   sent;      // write beats accepted
    logic [BURST_WIDTH:0]   got;       // read beats received
    logic [WATCHDOG_BITS-1:0] wdog;

    // The expected value for the next read beat, and the value to drive for
    // the next write beat. Both are the same ramp.
    logic [DATA_WIDTH-1:0] ramp_wr, ramp_rd;
    assign ramp_wr = seed_r + DATA_WIDTH'(sent);
    assign ramp_rd = seed_r + DATA_WIDTH'(got);

    assign busy = (state != M_IDLE) || req || done;

    assign m_byteenable = '1;
    assign m_address    = addr_r;
    assign m_burstcount = burst_r;
    assign m_writedata  = ramp_wr;
    assign m_write      = (state == M_WR);
    assign m_read       = (state == M_RD);

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state      <= M_IDLE;
            addr_r     <= '0;
            seed_r     <= '0;
            burst_r    <= BURST_WIDTH'(1);
            sent       <= '0;
            got        <= '0;
            wdog       <= '0;
            done       <= 1'b0;
            done_write <= 1'b0;
            rdata      <= '0;
            resp       <= 2'b00;
            beats      <= '0;
            data_ok    <= 1'b0;
            cycles     <= '0;
            stuck      <= 1'b0;
        end else begin
            done <= 1'b0;

            // ---- elapsed-cycle counter, saturating ----
            if (state != M_IDLE && !(&cycles)) cycles <= cycles + 1'b1;

            case (state)
                M_IDLE: begin
                    if (req) begin
                        addr_r     <= req_addr;
                        seed_r     <= req_wdata;
                        burst_r    <= (req_burst == '0) ? BURST_WIDTH'(1) : req_burst;
                        sent       <= '0;
                        got        <= '0;
                        cycles     <= '0;
                        resp       <= 2'b00;
                        data_ok    <= 1'b1;     // cleared by the first mismatch
                        beats      <= '0;
                        done_write <= req_write;
                        state      <= req_write ? M_WR : M_RD;
                    end
                end

                // ---- write burst ----
                //
                // The address is presented on every beat. Avalon-MM only
                // requires it on the first, and the firewall latches the
                // burst's verdict there, but holding it steady costs nothing
                // and keeps the waveform readable.
                M_WR: begin
                    if (!m_waitrequest) begin
                        sent <= sent + 1'b1;
                        if (sent + 1'b1 >= {1'b0, burst_r}) begin
                            beats <= sent + 1'b1;
                            if (HAS_WRESP) begin
                                state <= M_WRESP;
                            end else begin
                                // Without write responses the burst is
                                // complete when its last beat is accepted.
                                state <= M_IDLE;
                                done  <= 1'b1;
                            end
                        end
                    end
                end

                M_WRESP: begin
                    if (m_writeresponsevalid) begin
                        resp  <= m_response;
                        state <= M_IDLE;
                        done  <= 1'b1;
                    end
                end

                // ---- read burst ----
                M_RD: begin
                    if (!m_waitrequest) state <= M_RDATA;
                    // A beat can arrive in the same cycle the command is
                    // taken, so the collector below runs in this state too.
                end

                M_RDATA: ;

                default: state <= M_IDLE;
            endcase

            // ---- read beat collector ----
            //
            // Outside the case statement on purpose: readdatavalid may arrive
            // in the cycle the command handshakes, which is still M_RD.
            if ((state == M_RD || state == M_RDATA) && m_readdatavalid) begin
                rdata <= m_readdata;
                resp  <= m_response;
                got   <= got + 1'b1;
                if (m_readdata != ramp_rd) data_ok <= 1'b0;
                if (got + 1'b1 >= {1'b0, burst_r}) begin
                    beats <= got + 1'b1;
                    state <= M_IDLE;
                    done  <= 1'b1;
                end
            end

            // ---- watchdog ----
            //
            // Last in the block on purpose: its assignments must beat the
            // state machine's, not race them.
            if (state == M_IDLE) begin
                wdog <= '0;
            end else begin
                wdog <= wdog + 1'b1;
                if (&wdog) begin
                    // Give up. Dropping a command without waitrequest having
                    // fallen is itself a protocol violation, and committing it
                    // here is the lesser evil: the alternative is a board that
                    // looks dead with nothing to report.
                    state      <= M_IDLE;
                    stuck      <= 1'b1;
                    done       <= 1'b1;
                    beats      <= (state == M_RD || state == M_RDATA) ? got : sent;
                    done_write <= (state == M_WR) || (state == M_WRESP);
                end
            end
        end
    end

endmodule
