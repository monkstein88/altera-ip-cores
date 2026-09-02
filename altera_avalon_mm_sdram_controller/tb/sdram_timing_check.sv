`timescale 1ns/1ps
// =============================================================================
// sdram_timing_check.sv
//
// Watches the SDRAM command bus and asserts that JEDEC timing is respected.
//
// WHY THIS IS SEPARATE FROM THE MEMORY MODEL
// ------------------------------------------
// Intel's functional model decodes commands and returns data. It does NOT
// model tRCD, tRP, tRC, tRAS, tRRD or tWR, does not enforce the refresh
// interval, and does not model retention - its own generator script says so.
// So a controller can violate every timing parameter on the part and still
// pass a data-integrity test against that model. On silicon it would corrupt
// data intermittently, at temperature, months later.
//
// This module closes that hole. It is bound alongside the model and checks
// the command stream itself, per bank, against the same nanosecond parameters
// the controller is configured with. It is the difference between "the
// controller sent the right commands" and "the controller sent them legally".
//
// PARAMETERISED IN NANOSECONDS, LIKE THE CONTROLLER
// -------------------------------------------------
// Cycle counts are derived here with ceiling division, never passed in. A
// checker that took cycles would need the same error the controller might
// make, and would then agree with it.
// =============================================================================

module sdram_timing_check #(
    parameter int CLK_KHZ    = 100_000,  // controller clock

    // Device timings, nanoseconds. Defaults are the ISSI IS42S16320D-7 on
    // the DE10-Lite; override for any other part.
    parameter real T_RC_NS   = 60.0,     // ACT -> ACT, same bank
    parameter real T_RAS_NS  = 37.0,     // ACT -> PRE, same bank (minimum)
    parameter real T_RP_NS   = 15.0,     // PRE -> ACT, same bank
    parameter real T_RCD_NS  = 15.0,     // ACT -> READ/WRITE, same bank
    parameter real T_RRD_NS  = 14.0,     // ACT -> ACT, different bank
    parameter real T_WR_NS   = 14.0,     // last write data -> PRE
    parameter real T_MRD_NS  = 14.0,     // LOAD MODE -> any command
    parameter real T_RFC_NS  = 60.0,     // REFRESH -> ACT/REFRESH
    parameter int  BANKS     = 4,
    parameter int  CAS_LAT   = 3,

    // Refresh: REF_ROWS rows must be refreshed every REF_PERIOD_MS.
    parameter int  REF_ROWS      = 8192,
    parameter real REF_PERIOD_MS = 64.0,
    // JEDEC lets a controller postpone this many intervals before it must
    // catch up; the checker allows exactly that and no more.
    parameter int  REF_MAX_PEND  = 8,

    parameter bit  CHECK_REFRESH = 1
) (
    input logic       clk,
    input logic       reset_n,
    input logic       cke,
    input logic       cs_n,
    input logic       ras_n,
    input logic       cas_n,
    input logic       we_n,
    input logic [1:0] ba,
    // Only A10 is decoded - the precharge-all flag. The row and column bits do
    // not change whether a command is legally timed, which is all this module
    // judges.
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [12:0] addr
    /* verilator lint_on UNUSEDSIGNAL */
);

    // ---- ns -> cycles, always rounding UP, never below 1 ------------------
    // A timing parameter rounded down is a silent data-corruption bug, so the
    // conversion is deliberately pessimistic.
    //
    // This used to be `int'((ns*khz + 999_999.0)/1_000_000.0)`, the familiar
    // integer ceiling trick. It is WRONG in SystemVerilog: `int'(real)` rounds
    // to NEAREST (IEEE 1800-2017 6.24.1), not toward zero, so the +999_999
    // and the rounding both round up and a whole extra cycle appears whenever
    // the exact quotient is an integer. tRC 60 ns at 100 MHz came out as 7
    // cycles instead of 6, and tRAS 37 ns as 5 instead of 4 - a checker that
    // rejects legal command streams.
    //
    // The epsilon absorbs floating-point overshoot, so a quotient that is 6.0
    // in exact arithmetic and 6.0000000001 in doubles does not become 7.
    function automatic int unsigned cyc(input real ns);
        real c;
        c = $ceil((ns * real'(CLK_KHZ)) / 1_000_000.0 - 1.0e-9);
        return (c < 1.0) ? 1 : int'(c);
    endfunction

    // Some SDR timings are specified in CLOCKS, not in time: on this part tRRD,
    // tDPL(tWR) and tMRD are 2 cycles at every speed grade, and the nanosecond
    // figure is just 2 x that grade's tCK written out. Below about 71 MHz,
    // 14 ns is less than one clock and all three round to a single cycle.
    //
    // The checker floors them for the same reason the controller does, and it
    // matters more here: a checker that derives the same wrong number from the
    // same nanoseconds agrees with the controller and reports nothing. That is
    // exactly the failure this file exists to prevent, arrived at from the
    // other direction - not a shared arithmetic bug, but a shared assumption
    // about what the parameter MEANS.
    function automatic int unsigned cyc_min(input real ns, input int unsigned floor_c);
        int unsigned c;
        c = cyc(ns);
        return (c < floor_c) ? floor_c : c;
    endfunction

    int unsigned CYC_RC, CYC_RAS, CYC_RP, CYC_RCD, CYC_RRD, CYC_WR, CYC_MRD;
    int unsigned CYC_RFC;
    // Read-to-write turnaround, in clocks: CAS latency plus the cycle the
    // device needs to release DQ.
    localparam int unsigned CYC_WTR = CAS_LAT + 1;
    int unsigned CYC_REF_INTERVAL;

    initial begin
        CYC_RC  = cyc(T_RC_NS);
        CYC_RAS = cyc(T_RAS_NS);
        CYC_RP  = cyc(T_RP_NS);
        CYC_RCD = cyc(T_RCD_NS);
        CYC_RRD = cyc_min(T_RRD_NS, 2);
        CYC_WR  = cyc_min(T_WR_NS,  2);
        CYC_MRD = cyc_min(T_MRD_NS, 2);
        CYC_RFC = cyc(T_RFC_NS);
        // The refresh interval is a MAXIMUM, so it floors - rounding it up
        // would let the controller refresh less often than the part allows and
        // still be called correct.
        CYC_REF_INTERVAL = int'($floor((REF_PERIOD_MS * 1_000_000.0 / real'(REF_ROWS))
                                       * real'(CLK_KHZ) / 1_000_000.0));
        if (CYC_REF_INTERVAL < 1) CYC_REF_INTERVAL = 1;
        $display("[timing] @%0d kHz: tRC=%0d tRAS=%0d tRP=%0d tRCD=%0d tRRD=%0d tWR=%0d tRFC=%0d refresh<=%0d cycles",
                 CLK_KHZ, CYC_RC, CYC_RAS, CYC_RP, CYC_RCD, CYC_RRD, CYC_WR,
                 CYC_RFC, CYC_REF_INTERVAL);
    end

    // ---- command decode ---------------------------------------------------
    logic sel;
    assign sel = cke && !cs_n;

    logic cmd_act, cmd_rd, cmd_wr, cmd_pre, cmd_ref, cmd_mrs, cmd_pre_all;
    assign cmd_act     = sel && !ras_n &&  cas_n &&  we_n;
    assign cmd_rd      = sel &&  ras_n && !cas_n &&  we_n;
    assign cmd_wr      = sel &&  ras_n && !cas_n && !we_n;
    assign cmd_pre     = sel && !ras_n &&  cas_n && !we_n;
    assign cmd_ref     = sel && !ras_n && !cas_n &&  we_n;
    assign cmd_mrs     = sel && !ras_n && !cas_n && !we_n;
    assign cmd_pre_all = cmd_pre && addr[10];

    // ---- per-bank elapsed-time counters -----------------------------------
    // Saturating, so a long idle period cannot wrap and manufacture a
    // violation.
    //
    // A counter is set to ONE, not zero, on the event it measures. The checks
    // below read the counter at a clock edge, before that edge's increment has
    // taken effect, so a counter zeroed on the event would read 0 at the very
    // next edge - reporting an elapsed time of 0 for two commands that are
    // genuinely one cycle apart. Starting at 1 makes the number the checker
    // prints the true command separation in cycles. Getting this wrong made
    // the checker one cycle stricter than the device is.
    int unsigned since_act  [BANKS];
    int unsigned since_pre  [BANKS];
    int unsigned since_wdata[BANKS];
    int unsigned since_any_act, since_mrs, since_ref, since_rd;
    logic        row_open   [BANKS];
    logic        ref_seen;      // initialisation is over: refresh rate matters
    logic        ref_late;      // already reported this overrun

    function automatic int unsigned sat(input int unsigned v);
        return (v > 32'h4000_0000) ? v : v + 1;
    endfunction

    // NOT cleared by reset. A violation that happened is a fact about the run,
    // and the testbench's last scenario deliberately asserts reset - which used
    // to wipe the tally on the way out, so the summary printed
    // "timing violations: 0" over a run that had reported dozens on the
    // transcript. Everything else here is per-bank state that reset must clear;
    // this is a scoreboard, and it does not.
    int unsigned errs = 0;

    task automatic viol(input string what, input int unsigned got,
                        input int unsigned need, input int bank);
        errs++;
        $display("  TIMING VIOLATION  %-28s bank %0d: %0d cycles elapsed, %0d required (t=%0t)",
                 what, bank, got, need, $time);
    endtask

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (int b = 0; b < BANKS; b++) begin
                since_act[b]   <= 32'h4000_0000;
                since_pre[b]   <= 32'h4000_0000;
                since_wdata[b] <= 32'h4000_0000;
                row_open[b]    <= 1'b0;
            end
            since_any_act <= 32'h4000_0000;
            since_mrs     <= 32'h4000_0000;
            since_ref     <= 0;
            since_rd      <= 32'h4000_0000;
            ref_seen      <= 1'b0;
            ref_late      <= 1'b0;
        end else begin
            for (int b = 0; b < BANKS; b++) begin
                since_act[b]   <= sat(since_act[b]);
                since_pre[b]   <= sat(since_pre[b]);
                since_wdata[b] <= sat(since_wdata[b]);
            end
            since_any_act <= sat(since_any_act);
            since_mrs     <= sat(since_mrs);
            since_ref     <= sat(since_ref);
            since_rd      <= sat(since_rd);

            // ---- ACTIVATE ----
            if (cmd_act) begin
                // tRC: ACT to ACT on the same bank
                if (since_act[ba] < CYC_RC)
                    viol("tRC  (ACT->ACT same bank)", since_act[ba], CYC_RC, int'(ba));
                // tRP: the bank must have been precharged long enough
                if (row_open[ba])
                    viol("ACT to an already-open bank", 0, 0, int'(ba));
                else if (since_pre[ba] < CYC_RP)
                    viol("tRP  (PRE->ACT)", since_pre[ba], CYC_RP, int'(ba));
                // tRRD: ACT to ACT across banks
                if (since_any_act < CYC_RRD)
                    viol("tRRD (ACT->ACT diff bank)", since_any_act, CYC_RRD, int'(ba));
                if (since_mrs < CYC_MRD)
                    viol("tMRD (LMR->cmd)", since_mrs, CYC_MRD, int'(ba));
                // tRFC: an AUTO REFRESH occupies the whole array. Nothing may
                // activate until it has finished. This was unchecked, and it
                // is the ONLY refresh timing there is - a controller that
                // activated too soon after a refresh passed every flow here.
                if (since_ref < CYC_RFC)
                    viol("tRFC (REF->ACT)", since_ref, CYC_RFC, int'(ba));

                since_act[ba] <= 1;
                since_any_act <= 1;
                row_open[ba]  <= 1'b1;
            end

            // ---- READ / WRITE ----
            if (cmd_rd || cmd_wr) begin
                if (!row_open[ba])
                    viol("column command to a closed bank", 0, 0, int'(ba));
                else if (since_act[ba] < CYC_RCD)
                    viol("tRCD (ACT->RD/WR)", since_act[ba], CYC_RCD, int'(ba));
                if (cmd_wr) since_wdata[ba] <= 1;
                if (cmd_rd) since_rd <= 1;

                // Read-to-write bus turnaround. A READ registered at T has the
                // device driving DQ at T+CAS; a WRITE drives DQ in its own
                // cycle, so the earliest safe one is T+CAS+1. This is a
                // property of the shared DQ bus rather than of one bank, so it
                // is not indexed by bank.
                //
                // No functional model can show this failing - the model simply
                // stops driving and the controller reads back what it drove
                // itself - and until now it was only covered by the SVA, which
                // the benchmark harness does not bind. The benchmark therefore
                // had no read-to-write check at all.
                if (cmd_wr && (since_rd < CYC_WTR))
                    viol("read->write turnaround (DQ contention)",
                         since_rd, CYC_WTR, int'(ba));
            end

            // ---- PRECHARGE ----
            if (cmd_pre) begin
                for (int b = 0; b < BANKS; b++) begin
                    if (cmd_pre_all || (b == int'(ba))) begin
                        if (row_open[b]) begin
                            // tRAS: a row may not be closed too soon after opening
                            if (since_act[b] < CYC_RAS)
                                viol("tRAS (ACT->PRE)", since_act[b], CYC_RAS, b);
                            // tWR: write data must settle before precharge
                            if (since_wdata[b] < CYC_WR)
                                viol("tWR  (write->PRE)", since_wdata[b], CYC_WR, b);
                        end
                        row_open[b] <= 1'b0;
                        since_pre[b] <= 1;
                    end
                end
            end

            // ---- AUTO REFRESH ----
            if (cmd_ref) begin
                for (int b = 0; b < BANKS; b++)
                    if (row_open[b])
                        viol("REFRESH with a bank still open", 0, 0, b);
                if (since_ref < CYC_RFC)
                    viol("tRFC (REF->REF)", since_ref, CYC_RFC, 0);
                if (since_mrs < CYC_MRD)
                    viol("tMRD (LMR->cmd)", since_mrs, CYC_MRD, 0);
                ref_seen  <= 1'b1;
                since_ref <= 1;
            end

            if (cmd_mrs) since_mrs <= 1;

            // ---- refresh interval ----
            //
            // This used to be an `if` guarding an empty statement, with a
            // comment promising a summary that did not exist: CHECK_REFRESH
            // was wired to nothing and a controller that never refreshed at
            // all was reported as clean. It now counts a real violation, once
            // per overrun rather than once per cycle.
            //
            // Only meaningful after initialisation, which legitimately issues
            // a burst of refreshes and long NOP waits, so it arms on the first
            // refresh after the mode register is written. JEDEC allows up to
            // REF_MAX_PEND intervals of postponement, so the bound checked
            // here is that allowance plus one interval of slack: the last
            // postponed refresh only becomes due at REF_MAX_PEND x tREFI, and
            // the controller still has to precharge and wait tRP before it can
            // issue. The point is to catch a controller that has stopped
            // refreshing, not to re-derive the scheduler's own arithmetic.
            if (CHECK_REFRESH && ref_seen && (since_mrs < 32'h4000_0000)) begin
                if (since_ref > CYC_REF_INTERVAL * (REF_MAX_PEND + 1)) begin
                    if (!ref_late) begin
                        ref_late <= 1'b1;
                        viol("tREFI (refresh overdue)", since_ref,
                             CYC_REF_INTERVAL * (REF_MAX_PEND + 1), 0);
                    end
                end else begin
                    ref_late <= 1'b0;
                end
            end
        end
    end

    // Reported by the testbench at end of run.
    function automatic int unsigned violation_count();
        return errs;
    endfunction

endmodule
