`timescale 1ns/1ps

// =============================================================================
// demo_sdram_seq.sv
//
// The scenario engine for the SDRAM controller demonstration. It generates
// addresses and data, checks what comes back, and times the block transfers.
// All bus protocol lives in demo_avl_mm_master.sv; this module speaks a plain
// ready/valid command interface.
//
// -----------------------------------------------------------------------------
// THE ADDRESS MAP THIS DEMO IS BUILT AROUND
// -----------------------------------------------------------------------------
// The scenarios below are not arbitrary sizes. They are chosen from the
// controller's real address decode, which is NOT the {bank, row, column}
// layout most people assume. Read out of the generated RTL:
//
//     assign f_bank   = {f_addr[24], f_addr[10]};
//     assign row_match = active_addr[23:11] == f_addr[23:11];
//     assign cas_addr  = {3'b000, f_addr[9:0]};
//
// so a 25-bit word address decomposes as:
//
//     addr[24]     bank[1]
//     addr[23:11]  row[12:0]
//     addr[10]     bank[0]      <-- sits BELOW the row, not above it
//     addr[9:0]    column[9:0]
//
// The consequence is worth stating plainly: walking a linear address range
// does NOT change row every 1024 words. It changes BANK at every 1024-word
// boundary and only changes ROW every 2048 words. Scenarios 3, 4 and 5 exist
// to exercise exactly those three cases and to time them, which is why their
// lengths are 1024, 2048 and a stride of 2048.
//
// -----------------------------------------------------------------------------
// HOW READS ARE CHECKED
// -----------------------------------------------------------------------------
// Reads are pipelined: the issue side keeps commands going out for as long as
// the controller's command FIFO will take them, while a second, independent
// address counter walks the same sequence one response at a time and
// regenerates the expected word. Avalon-MM returns read data in order, so the
// two stay in step without any tag or queue.
//
// This is what makes the throughput figures meaningful. Issuing a read and
// waiting for it before issuing the next would measure the round trip, not
// the memory.
//
// -----------------------------------------------------------------------------
// WHY THERE IS A WATCHDOG
// -----------------------------------------------------------------------------
// `running` is derived from the state register alone and every scenario has a
// cycle budget. If a scenario ever fails to finish - a lost response, a
// controller that stops accepting commands - the watchdog fails it and forces
// the machine back to IDLE. A JTAG host can therefore always tell "still
// working" from "wedged", and never has to break the board out of a state it
// cannot leave. `seq_reset` gives the host a direct way back to IDLE as well.
// =============================================================================

module demo_sdram_seq #(
    parameter int ADDR_WIDTH   = 25,
    parameter int DATA_WIDTH   = 16,
    // Column bits of the part underneath. The scenarios below are defined in
    // terms of the address decode - one row, one bank, a row miss on every
    // access - so they have to know where the column ends and the bank begins.
    // The DE10-Lite's IS42S16320D has a 10-bit column, the DE0-Nano's
    // IS42S16160B a 9-bit one, and the scenarios mean the same thing on both
    // only if these follow the part.
    parameter int COL_BITS     = 10,
    // 250 ms at 100 MHz. Scenario 6 sits idle for this long, which is ~32000
    // refresh intervals - if auto-refresh were not happening the data would
    // be long gone.
    parameter int unsigned REFRESH_IDLE_CYCLES = 32'd25_000_000,
    // 15 s at 100 MHz. Generous on purpose: it is a wedge detector, not a
    // performance limit. The full-memory march is the only scenario that
    // takes a meaningful fraction of it.
    parameter int unsigned WATCHDOG_CYCLES     = 32'd1_500_000_000,
    // ~328 us at 100 MHz, covering the controller's 100 us power-up delay
    // plus its precharge / refresh / mode-register init before the first
    // access is offered.
    parameter int unsigned INIT_WAIT_CYCLES    = 32'd32_768,
    // How many words scenario 7 marches over. The default is the whole chip -
    // which is the point of it on hardware - so it FOLLOWS ADDR_WIDTH rather
    // than being a constant. It used to be 33,554,432, the DE10-Lite's word
    // count, which on the DE0-Nano's 24-bit address is twice the device: the
    // march wrapped and tested every location twice, passing while reporting
    // a word count for a chip that is not there.
    //
    // A testbench overrides this: at ~1 clock per word a full march is tens of
    // millions of simulated cycles, so a simulation using the default would
    // not finish in any useful time.
    parameter int unsigned MARCH_WORDS        = 32'd1 << ADDR_WIDTH
) (
    input  logic                     clk,
    input  logic                     resetn,

    // ---- controls --------------------------------------------------------
    input  logic [3:0]               select,
    input  logic                     auto_mode,
    input  logic                     freeze,        // stop an auto sweep on a failure
    input  logic                     start_pulse,
    input  logic                     seq_reset,     // force back to IDLE

    // ---- status ----------------------------------------------------------
    output logic                     running,
    output logic [3:0]               cur_scenario,
    output logic                     result_valid,
    output logic                     result_pass,
    output logic [7:0]               pass_bitmap,
    output logic [3:0]               done_count,
    output logic [2:0]               err_code,
    output logic [ADDR_WIDTH-1:0]    fail_addr,
    output logic [DATA_WIDTH-1:0]    fail_expected,
    output logic [DATA_WIDTH-1:0]    fail_actual,
    output logic [31:0]              perf_wr_cycles,
    output logic [31:0]              perf_rd_cycles,
    output logic [31:0]              perf_words,

    // ---- command interface to demo_avl_mm_master --------------------------
    output logic                     cmd_valid,
    output logic                     cmd_write,
    output logic [ADDR_WIDTH-1:0]    cmd_addr,
    output logic [DATA_WIDTH-1:0]    cmd_wdata,
    output logic [DATA_WIDTH/8-1:0]  cmd_be,
    input  logic                     cmd_ready,
    input  logic                     rsp_valid,
    input  logic [DATA_WIDTH-1:0]    rsp_data
);

    localparam int NUM_SCENARIOS = 8;

    // ---- error codes ------------------------------------------------------
    localparam logic [2:0] ERR_NONE    = 3'd0;
    localparam logic [2:0] ERR_DATA    = 3'd1;   // read back the wrong word
    localparam logic [2:0] ERR_TIMEOUT = 3'd2;   // watchdog fired

    // ---- phase kinds ------------------------------------------------------
    localparam logic [2:0] PH_END    = 3'd0;
    localparam logic [2:0] PH_WBLK   = 3'd1;     // streamed block write
    localparam logic [2:0] PH_RBLK   = 3'd2;     // streamed block read + check
    localparam logic [2:0] PH_WAIT   = 3'd3;     // idle, touching nothing
    localparam logic [2:0] PH_DQWALK = 3'd4;     // walking 1s / 0s at one address
    localparam logic [2:0] PH_BE     = 3'd5;     // byte-enable sequence

    // ---- address modes ----------------------------------------------------
    localparam logic AM_LINEAR = 1'b0;           // addr += stride
    localparam logic AM_POW2   = 1'b1;           // 0, 1, 2, 4, 8, ... 2^24

    // ---- fixed addresses for the small scenarios --------------------------
    localparam logic [ADDR_WIDTH-1:0] DQ_ADDR   = ADDR_WIDTH'('h0001234);
    localparam logic [ADDR_WIDTH-1:0] BE_ADDR   = ADDR_WIDTH'('h0005678);
    localparam logic [ADDR_WIDTH-1:0] REFR_BASE = ADDR_WIDTH'('h0100000);

    // Every word in the chip. Scenario 7 marches over MARCH_WORDS of them,
    // which defaults to all of it - 2^ADDR_WIDTH.
    localparam logic [31:0] TOTAL_WORDS = MARCH_WORDS;

    // -----------------------------------------------------------------------
    // The expected word at an address.
    //
    // Address-derived rather than an LFSR, for two reasons: the read pass
    // needs no state shared with the write pass, and a single stuck or
    // shorted address line always shows up. If two addresses differ in
    // exactly one bit k, then k<9 changes the low term only, k>15 changes the
    // high term only, and 9<=k<=15 changes both - but at bit positions k and
    // k-9, which are never the same bit. So the pattern differs in every case.
    // -----------------------------------------------------------------------
    // The slice is taken from a zero-extended copy rather than from `a`
    // directly. a[24:9] is only a legal slice when ADDR_WIDTH is at least 25,
    // and on the DE0-Nano's 24-bit address it is not - Quartus rejects the
    // out-of-range index outright, while Verilator quietly returns zero for
    // the missing bit and simulates on. Zero-extending first means the two
    // agree, and the value is unchanged wherever the wider slice was legal.
    function automatic logic [15:0] patt(input logic [ADDR_WIDTH-1:0] a);
        logic [31:0] ax;
        ax   = 32'(a);
        patt = ax[15:0] ^ ax[24:9] ^ 16'hA5A5;
    endfunction

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------
    localparam logic [2:0] ST_IDLE    = 3'd0;
    localparam logic [2:0] ST_INIT    = 3'd1;
    localparam logic [2:0] ST_SETUP   = 3'd2;
    localparam logic [2:0] ST_BLOCK   = 3'd3;
    localparam logic [2:0] ST_WAITN   = 3'd4;
    localparam logic [2:0] ST_SERIAL  = 3'd5;
    localparam logic [2:0] ST_FINISH  = 3'd6;

    logic [2:0] state;

    logic [3:0]  scen;           // scenario being run
    logic [2:0]  phase;          // phase index within it
    logic        sweep;          // this run is an auto sweep
    logic        pass_acc;       // no failure seen yet in this scenario
    // Cleared once per RUN, not once per scenario. pass_acc restarts at every
    // scenario of a sweep, so gating the capture on it alone would leave
    // fail_addr describing the last scenario that failed rather than the
    // first - and in a sweep the first one is the one that explains the rest.
    logic        fail_latched;

    // phase parameters, latched in ST_SETUP
    logic [2:0]  p_kind;
    logic        p_mode;
    logic [ADDR_WIDTH-1:0] p_stride;

    // issue side
    logic [ADDR_WIDTH-1:0] iss_addr;
    logic [31:0]           iss_left;
    // check side
    logic [ADDR_WIDTH-1:0] chk_addr;
    logic [31:0]           chk_left;

    logic [31:0] wait_left;
    logic [31:0] phase_cycles;
    logic [31:0] wdog;

    // serial engine (PH_DQWALK / PH_BE)
    logic [5:0]  ser_i;
    logic [1:0]  ser_st;
    localparam logic [1:0] SER_WR = 2'd0, SER_RD = 2'd1, SER_CHK = 2'd2, SER_NXT = 2'd3;
    logic [DATA_WIDTH-1:0] ser_expect;

    logic [31:0] init_cnt;

    // -----------------------------------------------------------------------
    // The phase table: what scenario `scen` does at step `phase`.
    // -----------------------------------------------------------------------
    logic [2:0]            t_kind;
    logic                  t_mode;
    // Derived from COL_BITS: one full row of columns, and the stride that
    // moves to the next bank (ADDR_MAP 0 puts bank[0] directly above the
    // column). At COL_BITS 10 these are the 1024 and 2048 the scenarios were
    // originally written with.
    // Address 0 plus one address per address BIT. Following ADDR_WIDTH matters:
    // on a 24-bit part, walking up to 2^24 would step off the end of memory
    // and the read-back would compare against a word that was never written.
    localparam int unsigned POW2_COUNT  = 32'(ADDR_WIDTH) + 32'd1;

    localparam int unsigned COL_WORDS   = 32'd1 << COL_BITS;
    localparam int unsigned BANK_STRIDE = 32'd1 << (COL_BITS + 1);

    logic [ADDR_WIDTH-1:0] t_base;
    logic [31:0]           t_count;
    logic [ADDR_WIDTH-1:0] t_stride;
    logic [31:0]           t_wait;

    always_comb begin
        t_kind   = PH_END;
        t_mode   = AM_LINEAR;
        t_base   = '0;
        t_count  = 32'd0;
        t_stride = ADDR_WIDTH'(1);
        t_wait   = 32'd0;

        unique case (scen)
        // 0 - data bus integrity. Walking 1s then walking 0s then all-zero
        //     and all-ones, each written and immediately read back at one
        //     address. Catches a DQ line that is stuck, open, or shorted to
        //     its neighbour.
        4'd0: if (phase == 0) t_kind = PH_DQWALK;

        // 1 - address bus integrity. A distinct word at address 0 and at
        //     every power of two up to 2^24, written then read back. If two
        //     address lines are swapped or one is stuck, two of these
        //     addresses collide and the check fails.
        4'd1: case (phase)
                3'd0: begin t_kind = PH_WBLK; t_mode = AM_POW2; t_count = POW2_COUNT; end
                3'd1: begin t_kind = PH_RBLK; t_mode = AM_POW2; t_count = POW2_COUNT; end
                default: t_kind = PH_END;
              endcase

        // 2 - byte enables, i.e. does DQM reach the chip. Half-word writes
        //     that must leave the other half untouched.
        4'd2: if (phase == 0) t_kind = PH_BE;

        // 3 - column sweep: 1024 words from a 1024-aligned base. addr[10] and
        //     addr[23:11] never change, so this is one bank and one row from
        //     start to finish - every access after the first is a row hit.
        //     The fastest case the controller has.
        4'd3: case (phase)
                3'd0: begin t_kind = PH_WBLK; t_base = '0; t_count = COL_WORDS; end
                3'd1: begin t_kind = PH_RBLK; t_base = '0; t_count = COL_WORDS; end
                default: t_kind = PH_END;
              endcase

        // 4 - bank toggle: 2048 words from 0, so the walk crosses addr[10] at
        //     word 1024 and moves to the other bank at the same row index.
        //     Same row, different bank - one extra ACTIVATE in the middle.
        4'd4: case (phase)
                3'd0: begin t_kind = PH_WBLK; t_base = '0; t_count = BANK_STRIDE; end
                3'd1: begin t_kind = PH_RBLK; t_base = '0; t_count = BANK_STRIDE; end
                default: t_kind = PH_END;
              endcase

        // 5 - row thrash: 256 accesses at stride 2048. Stride 2048 clears
        //     addr[10] on every access and increments addr[23:11], so every
        //     single access is a row miss in the SAME bank: PRECHARGE,
        //     ACTIVATE, then one word. The worst case the controller has, and
        //     the interesting one to compare against scenario 3.
        4'd5: case (phase)
                3'd0: begin t_kind = PH_WBLK; t_base = '0; t_count = 32'd256; t_stride = ADDR_WIDTH'(BANK_STRIDE); end
                3'd1: begin t_kind = PH_RBLK; t_base = '0; t_count = 32'd256; t_stride = ADDR_WIDTH'(BANK_STRIDE); end
                default: t_kind = PH_END;
              endcase

        // 6 - refresh retention. Write a block, then touch nothing at all for
        //     a quarter of a second, then read it back. The controller's
        //     auto-refresh is the only thing keeping those cells alive across
        //     the gap; without it the read-back is garbage.
        4'd6: case (phase)
                3'd0: begin t_kind = PH_WBLK; t_base = REFR_BASE; t_count = 32'd4096; end
                3'd1: begin t_kind = PH_WAIT; t_wait = REFRESH_IDLE_CYCLES; end
                3'd2: begin t_kind = PH_RBLK; t_base = REFR_BASE; t_count = 32'd4096; end
                default: t_kind = PH_END;
              endcase

        // 7 - the whole chip. Every one of 33,554,432 words written, then
        //     every one read back and checked. This is the scenario that
        //     proves the geometry in the .qsys file matches the part on the
        //     board: get rowWidth or columnWidth wrong and the address space
        //     folds back on itself, which shows up here and nowhere else.
        4'd7: case (phase)
                3'd0: begin t_kind = PH_WBLK; t_base = '0; t_count = TOTAL_WORDS; end
                3'd1: begin t_kind = PH_RBLK; t_base = '0; t_count = TOTAL_WORDS; end
                default: t_kind = PH_END;
              endcase

        default: t_kind = PH_END;
        endcase
    end

    // -----------------------------------------------------------------------
    // The serial engine's step table (PH_DQWALK and PH_BE).
    // -----------------------------------------------------------------------
    logic                  s_last;       // this is the final step
    logic                  s_is_write;
    logic [DATA_WIDTH-1:0] s_wdata;
    logic [DATA_WIDTH/8-1:0] s_be;
    logic [DATA_WIDTH-1:0] s_expect;     // what a read at this step must return
    logic [ADDR_WIDTH-1:0] s_addr;

    always_comb begin
        s_last     = 1'b0;
        s_is_write = 1'b1;
        s_wdata    = '0;
        s_be       = '1;
        s_expect   = '0;
        s_addr     = DQ_ADDR;

        if (p_kind == PH_DQWALK) begin
            // 34 steps, each a write followed by a read-back of the same word.
            s_addr = DQ_ADDR;
            if (ser_i < 6'd16)      s_wdata = 16'h0001 << ser_i;             // walking 1
            else if (ser_i < 6'd32) s_wdata = ~(16'h0001 << (ser_i - 6'd16)); // walking 0
            else if (ser_i == 6'd32) s_wdata = 16'h0000;
            else                     s_wdata = 16'hFFFF;
            s_expect = s_wdata;
            s_last   = (ser_i == 6'd33);
        end else begin
            // PH_BE. Two half-word writes that must each leave the other half
            // of the word alone, then a full write to prove the port still
            // does the ordinary thing.
            s_addr = BE_ADDR;
            case (ser_i)
                6'd0: begin s_is_write = 1'b1; s_wdata = 16'hFFFF; s_be = 2'b11; end
                6'd1: begin s_is_write = 1'b1; s_wdata = 16'h00AA; s_be = 2'b01; end
                6'd2: begin s_is_write = 1'b0; s_expect = 16'hFFAA; end
                6'd3: begin s_is_write = 1'b1; s_wdata = 16'h5500; s_be = 2'b10; end
                6'd4: begin s_is_write = 1'b0; s_expect = 16'h55AA; end
                6'd5: begin s_is_write = 1'b1; s_wdata = 16'h1234; s_be = 2'b11; end
                default: begin s_is_write = 1'b0; s_expect = 16'h1234; s_last = 1'b1; end
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Issue-side load enable. `cmd_valid` is a register, so it never depends
    // combinationally on `cmd_ready` and the ready/valid contract holds.
    // -----------------------------------------------------------------------
    logic blk_issue;
    assign blk_issue = (state == ST_BLOCK) && (iss_left != 0) && (!cmd_valid || cmd_ready);

    logic cmd_taken;
    assign cmd_taken = cmd_valid && cmd_ready;

    // Next address in the walk.
    logic [ADDR_WIDTH-1:0] iss_next, chk_next;
    assign iss_next = (p_mode == AM_POW2)
                    ? ((iss_addr == '0) ? {{(ADDR_WIDTH-1){1'b0}}, 1'b1} : (iss_addr << 1))
                    : (iss_addr + p_stride);
    assign chk_next = (p_mode == AM_POW2)
                    ? ((chk_addr == '0) ? {{(ADDR_WIDTH-1){1'b0}}, 1'b1} : (chk_addr << 1))
                    : (chk_addr + p_stride);

    assign running = (state != ST_IDLE);

    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!resetn) begin
            state          <= ST_IDLE;
            scen           <= 4'd0;
            phase          <= 3'd0;
            sweep          <= 1'b0;
            pass_acc       <= 1'b1;
            fail_latched   <= 1'b0;
            cmd_valid      <= 1'b0;
            cmd_write      <= 1'b0;
            cmd_addr       <= '0;
            cmd_wdata      <= '0;
            cmd_be         <= '1;
            cur_scenario   <= 4'd0;
            result_valid   <= 1'b0;
            result_pass    <= 1'b0;
            pass_bitmap    <= '0;
            done_count     <= 4'd0;
            err_code       <= ERR_NONE;
            fail_addr      <= '0;
            fail_expected  <= '0;
            fail_actual    <= '0;
            perf_wr_cycles <= '0;
            perf_rd_cycles <= '0;
            perf_words     <= '0;
            iss_addr       <= '0;
            iss_left       <= '0;
            chk_addr       <= '0;
            chk_left       <= '0;
            wait_left      <= '0;
            phase_cycles   <= '0;
            wdog           <= '0;
            ser_i          <= '0;
            ser_st         <= SER_WR;
            ser_expect     <= '0;
            p_kind         <= PH_END;
            p_mode         <= AM_LINEAR;
            p_stride       <= ADDR_WIDTH'(1);
            init_cnt       <= '0;
        end else begin

            // ---- watchdog: `running` can never stick ----------------------
            if (state == ST_IDLE) begin
                wdog <= '0;
            end else begin
                wdog <= wdog + 32'd1;
            end

            // ---- host escape hatch ---------------------------------------
            if (seq_reset) begin
                state     <= ST_IDLE;
                cmd_valid <= 1'b0;
            end else
            unique case (state)

            // ---------------------------------------------------------------
            ST_IDLE: begin
                cmd_valid <= 1'b0;
                if (start_pulse) begin
                    // An auto sweep starts a fresh bitmap; a hand-picked
                    // scenario leaves the other bits alone.
                    // select is masked to the number of scenarios that
                    // exist. Without this, SW[3] high would run a scenario
                    // whose phase table is empty - which "passes" instantly
                    // and sets a bitmap bit that means nothing.
                    sweep        <= auto_mode;
                    scen         <= auto_mode ? 4'd0 : {1'b0, select[2:0]};
                    cur_scenario <= auto_mode ? 4'd0 : {1'b0, select[2:0]};
                    if (auto_mode) pass_bitmap <= '0;
                    phase        <= 3'd0;
                    pass_acc     <= 1'b1;
                    fail_latched <= 1'b0;
                    result_valid <= 1'b0;
                    err_code     <= ERR_NONE;
                    perf_wr_cycles <= '0;
                    perf_rd_cycles <= '0;
                    // Cleared per run: the two serial scenarios never set it,
                    // and leaving the previous scenario's count in place made
                    // the JTAG readout look like they had moved words.
                    perf_words   <= '0;
                    init_cnt     <= '0;
                    state        <= ST_INIT;
                end
            end

            // Let the controller finish its own power-up sequence before the
            // first access of a run. Cheap, and it keeps the demo's behaviour
            // independent of how the controller's command FIFO behaves while
            // it is still initialising.
            ST_INIT: begin
                if (init_cnt >= INIT_WAIT_CYCLES) state <= ST_SETUP;
                else                              init_cnt <= init_cnt + 32'd1;
            end

            // ---------------------------------------------------------------
            ST_SETUP: begin
                p_kind       <= t_kind;
                p_mode       <= t_mode;
                p_stride     <= t_stride;
                iss_addr     <= t_base;
                chk_addr     <= t_base;
                iss_left     <= t_count;
                chk_left     <= t_count;
                wait_left    <= t_wait;
                phase_cycles <= '0;
                ser_i        <= '0;
                ser_st       <= SER_WR;
                cmd_valid    <= 1'b0;

                unique case (t_kind)
                    PH_WBLK, PH_RBLK: begin
                        perf_words <= t_count;
                        state      <= ST_BLOCK;
                    end
                    PH_WAIT:            state <= ST_WAITN;
                    PH_DQWALK, PH_BE:   state <= ST_SERIAL;
                    default:            state <= ST_FINISH;
                endcase
            end

            // ---------------------------------------------------------------
            // Streamed block. Writes are fire-and-forget; reads are issued as
            // fast as the controller will take them and checked in order as
            // they come back.
            // ---------------------------------------------------------------
            ST_BLOCK: begin
                phase_cycles <= phase_cycles + 32'd1;

                if (blk_issue) begin
                    cmd_valid <= 1'b1;
                    cmd_write <= (p_kind == PH_WBLK);
                    cmd_addr  <= iss_addr;
                    cmd_wdata <= patt(iss_addr);
                    cmd_be    <= '1;
                    iss_addr  <= iss_next;
                    iss_left  <= iss_left - 32'd1;
                end else if (cmd_taken) begin
                    cmd_valid <= 1'b0;
                end

                if (p_kind == PH_RBLK && rsp_valid) begin
                    if (rsp_data != patt(chk_addr)) begin
                        // First failure wins: later ones would overwrite the
                        // address that actually explains the problem.
                        if (!fail_latched) begin
                            fail_addr     <= chk_addr;
                            fail_expected <= patt(chk_addr);
                            fail_actual   <= rsp_data;
                            err_code      <= ERR_DATA;
                            fail_latched  <= 1'b1;
                        end
                        pass_acc <= 1'b0;
                    end
                    chk_addr <= chk_next;
                    chk_left <= chk_left - 32'd1;
                end

                // Phase end. A write phase is done when the last command has
                // been taken; the controller completes it from its FIFO. A
                // read phase is done when the last word has been checked.
                if (p_kind == PH_WBLK) begin
                    if ((iss_left == 0) && (!cmd_valid || cmd_ready)) begin
                        perf_wr_cycles <= perf_wr_cycles + phase_cycles + 32'd1;
                        cmd_valid <= 1'b0;
                        phase     <= phase + 3'd1;
                        state     <= ST_SETUP;
                    end
                end else begin
                    if (rsp_valid && (chk_left == 1)) begin
                        perf_rd_cycles <= perf_rd_cycles + phase_cycles + 32'd1;
                        cmd_valid <= 1'b0;
                        phase     <= phase + 3'd1;
                        state     <= ST_SETUP;
                    end
                end
            end

            // ---------------------------------------------------------------
            ST_WAITN: begin
                if (wait_left == 0) begin
                    phase <= phase + 3'd1;
                    state <= ST_SETUP;
                end else begin
                    wait_left <= wait_left - 32'd1;
                end
            end

            // ---------------------------------------------------------------
            // One transaction at a time. Used only by the two short
            // scenarios, where clarity matters more than throughput.
            // ---------------------------------------------------------------
            ST_SERIAL: begin
                unique case (ser_st)
                    SER_WR: begin
                        if (!cmd_valid) begin
                            cmd_valid <= 1'b1;
                            cmd_write <= s_is_write;
                            cmd_addr  <= s_addr;
                            cmd_wdata <= s_wdata;
                            cmd_be    <= s_be;
                            ser_expect <= s_expect;
                            // A DQ-walk step is a write that must then be read
                            // back; a byte-enable step is one or the other.
                            ser_st    <= (p_kind == PH_DQWALK) ? SER_RD
                                       : (s_is_write ? SER_NXT : SER_CHK);
                        end
                    end
                    // Issue the read-back of a DQ-walk step.
                    SER_RD: begin
                        if (cmd_taken) begin
                            cmd_valid <= 1'b1;
                            cmd_write <= 1'b0;
                            cmd_addr  <= s_addr;
                            cmd_be    <= '1;
                            ser_st    <= SER_CHK;
                        end
                    end
                    SER_CHK: begin
                        if (cmd_taken) cmd_valid <= 1'b0;
                        if (rsp_valid) begin
                            if (rsp_data != ser_expect) begin
                                if (!fail_latched) begin
                                    fail_addr     <= s_addr;
                                    fail_expected <= ser_expect;
                                    fail_actual   <= rsp_data;
                                    err_code      <= ERR_DATA;
                                    fail_latched  <= 1'b1;
                                end
                                pass_acc <= 1'b0;
                            end
                            ser_st <= SER_NXT;
                        end
                    end
                    SER_NXT: begin
                        if (cmd_taken) cmd_valid <= 1'b0;
                        if (!cmd_valid || cmd_ready) begin
                            if (s_last) begin
                                phase <= phase + 3'd1;
                                state <= ST_SETUP;
                            end else begin
                                ser_i  <= ser_i + 6'd1;
                                ser_st <= SER_WR;
                            end
                        end
                    end
                endcase
            end

            // ---------------------------------------------------------------
            ST_FINISH: begin
                cmd_valid    <= 1'b0;
                result_valid <= 1'b1;
                result_pass  <= pass_acc;
                pass_bitmap[scen[2:0]] <= pass_acc;
                done_count   <= done_count + 4'd1;

                if (sweep && !(freeze && !pass_acc) && (scen < NUM_SCENARIOS-1)) begin
                    scen         <= scen + 4'd1;
                    cur_scenario <= scen + 4'd1;
                    phase        <= 3'd0;
                    pass_acc     <= 1'b1;
                    perf_wr_cycles <= '0;
                    perf_rd_cycles <= '0;
                    perf_words     <= '0;
                    state        <= ST_SETUP;
                end else begin
                    state <= ST_IDLE;
                end
            end

            default: state <= ST_IDLE;
            endcase

            // ---- watchdog fires -------------------------------------------
            // Checked after the case so it overrides whatever the scenario
            // was about to do. The result is recorded as a failure, which is
            // the honest report: the scenario did not complete.
            if ((state != ST_IDLE) && (wdog >= WATCHDOG_CYCLES)) begin
                cmd_valid    <= 1'b0;
                err_code     <= ERR_TIMEOUT;
                result_valid <= 1'b1;
                result_pass  <= 1'b0;
                pass_bitmap[scen[2:0]] <= 1'b0;
                done_count   <= done_count + 4'd1;
                state        <= ST_IDLE;
            end
        end
    end

endmodule
