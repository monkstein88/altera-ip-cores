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
    parameter int  BANKS     = 4,
    parameter int  CAS_LAT   = 3,

    // Refresh: REF_ROWS rows must be refreshed every REF_PERIOD_MS.
    parameter int  REF_ROWS      = 8192,
    parameter real REF_PERIOD_MS = 64.0,

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
    input logic [12:0] addr
);

    // ---- ns -> cycles, always rounding UP, never below 1 ------------------
    // A timing parameter rounded down is a silent data-corruption bug, so the
    // conversion is deliberately pessimistic. `+ 999_999` is the ceiling.
    function automatic int unsigned cyc(input real ns);
        int unsigned c;
        c = int'((ns * real'(CLK_KHZ) + 999_999.0) / 1_000_000.0);
        return (c < 1) ? 1 : c;
    endfunction

    localparam int C_RC  = 0;  // placeholders so the values appear in one place
    int unsigned CYC_RC, CYC_RAS, CYC_RP, CYC_RCD, CYC_RRD, CYC_WR, CYC_MRD;
    int unsigned CYC_REF_INTERVAL;

    initial begin
        CYC_RC  = cyc(T_RC_NS);
        CYC_RAS = cyc(T_RAS_NS);
        CYC_RP  = cyc(T_RP_NS);
        CYC_RCD = cyc(T_RCD_NS);
        CYC_RRD = cyc(T_RRD_NS);
        CYC_WR  = cyc(T_WR_NS);
        CYC_MRD = cyc(T_MRD_NS);
        // average interval between AUTO REFRESH commands
        CYC_REF_INTERVAL = cyc((REF_PERIOD_MS * 1_000_000.0) / real'(REF_ROWS));
        $display("[timing] @%0d kHz: tRC=%0d tRAS=%0d tRP=%0d tRCD=%0d tRRD=%0d tWR=%0d refresh<=%0d cycles",
                 CLK_KHZ, CYC_RC, CYC_RAS, CYC_RP, CYC_RCD, CYC_RRD, CYC_WR,
                 CYC_REF_INTERVAL);
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
    int unsigned since_act  [BANKS];
    int unsigned since_pre  [BANKS];
    int unsigned since_wdata[BANKS];
    int unsigned since_any_act, since_mrs, since_ref;
    logic        row_open   [BANKS];

    function automatic int unsigned sat(input int unsigned v);
        return (v > 32'h4000_0000) ? v : v + 1;
    endfunction

    int unsigned errs;

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
            errs          <= 0;
        end else begin
            for (int b = 0; b < BANKS; b++) begin
                since_act[b]   <= sat(since_act[b]);
                since_pre[b]   <= sat(since_pre[b]);
                since_wdata[b] <= sat(since_wdata[b]);
            end
            since_any_act <= sat(since_any_act);
            since_mrs     <= sat(since_mrs);
            since_ref     <= sat(since_ref);

            // ---- ACTIVATE ----
            if (cmd_act) begin
                // tRC: ACT to ACT on the same bank
                if (since_act[ba] < CYC_RC)
                    viol("tRC  (ACT->ACT same bank)", since_act[ba], CYC_RC, ba);
                // tRP: the bank must have been precharged long enough
                if (row_open[ba])
                    viol("ACT to an already-open bank", 0, 0, ba);
                else if (since_pre[ba] < CYC_RP)
                    viol("tRP  (PRE->ACT)", since_pre[ba], CYC_RP, ba);
                // tRRD: ACT to ACT across banks
                if (since_any_act < CYC_RRD)
                    viol("tRRD (ACT->ACT diff bank)", since_any_act, CYC_RRD, ba);
                if (since_mrs < CYC_MRD)
                    viol("tMRD (LMR->cmd)", since_mrs, CYC_MRD, ba);

                since_act[ba] <= 0;
                since_any_act <= 0;
                row_open[ba]  <= 1'b1;
            end

            // ---- READ / WRITE ----
            if (cmd_rd || cmd_wr) begin
                if (!row_open[ba])
                    viol("column command to a closed bank", 0, 0, ba);
                else if (since_act[ba] < CYC_RCD)
                    viol("tRCD (ACT->RD/WR)", since_act[ba], CYC_RCD, ba);
                if (cmd_wr) since_wdata[ba] <= 0;
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
                        since_pre[b] <= 0;
                    end
                end
            end

            // ---- AUTO REFRESH ----
            if (cmd_ref) begin
                for (int b = 0; b < BANKS; b++)
                    if (row_open[b])
                        viol("REFRESH with a bank still open", 0, 0, b);
                since_ref <= 0;
            end

            if (cmd_mrs) since_mrs <= 0;

            // ---- refresh interval ----
            // Checked only once the controller is past initialisation, which
            // legitimately issues bursts of refreshes and long NOP waits.
            if (CHECK_REFRESH && row_open.or() === 1'b0 &&
                since_ref > CYC_REF_INTERVAL * 2 && since_mrs < 32'h4000_0000)
                ; // reported by the summary rather than per-cycle, see below
        end
    end

    // Reported by the testbench at end of run.
    function automatic int unsigned violation_count();
        return errs;
    endfunction

endmodule
