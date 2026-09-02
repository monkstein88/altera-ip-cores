`timescale 1ns/1ps
// =============================================================================
// timing_check_selftest.sv
//
// Proves that sdram_timing_check fires at the RIGHT THRESHOLD.
//
// WHY THIS EXISTS
// ---------------
// The checker was previously validated only by fault injection: tell it the
// part needs a 100 ns tRCD, watch it complain about a 15 ns one. That proves
// the checker is alive. It does not prove the checker is correct, and it was
// not - it carried two bugs that both made it one cycle too strict:
//
//   1. ns -> cycles used `int'((ns*khz + 999_999.0)/1_000_000.0)`. In
//      SystemVerilog `int'(real)` rounds to NEAREST, so the +999_999 bias and
//      the rounding compounded: tRC 60 ns at 100 MHz became 7 cycles, tRAS
//      37 ns became 5. Both are one more than the true ceiling.
//
//   2. The elapsed counters were zeroed on the event they measure and read
//      before the next increment, so two commands genuinely N cycles apart
//      were reported as N-1.
//
// Those bugs were found by a controller that failed the checker while being
// legal. That is a bad way to find them - the incentive runs the wrong way, and
// "the checker is wrong" is exactly what a broken controller would like to be
// true. So the threshold is now pinned from the other side, by a stimulus with
// hand-counted cycle separations that owes nothing to any controller:
//
//   for each parameter, a separation of exactly (N-1) cycles MUST be reported,
//   and a separation of exactly N cycles MUST NOT be.
//
// A checker that is one cycle strict fails the second half; one that is one
// cycle lax fails the first. Only a correct threshold passes both.
//
// tRC is not testable this way with a real device profile, because
// tRC == tRAS + tRP holds for the parts we care about and tRAS and tRP bind
// first. It gets a second checker instance with a stretched tRC, where it is
// the only constraint that can fire.
// =============================================================================

module timing_check_selftest;

    localparam int CLK_KHZ = 100_000;
    localparam real CLK_NS = 1_000_000.0 / real'(CLK_KHZ);

    // Required separations at 100 MHz for the DE10-Lite's IS42S16320D.
    // Hand-derived, not read back from the checker - that is the whole point.
    //   tRCD 15 ns / 10 ns = 1.5 -> 2      tRP  15 ns -> 2
    //   tRAS 37 ns / 10 ns = 3.7 -> 4      tRRD 14 ns -> 2
    //   tWR  14 ns / 10 ns = 1.4 -> 2      tMRD 14 ns -> 2
    localparam int N_RCD = 2, N_RP = 2, N_RAS = 4, N_RRD = 2, N_WR = 2, N_MRD = 2;
    // tRFC 60 ns at 100 MHz is 6 cycles. Read-to-write turnaround is a bus
    // property rather than a device timing: CAS latency plus the cycle the
    // device needs to stop driving DQ.
    localparam int N_RFC = 6, N_WTR = 4;
    // The stretched instance: tRC 105 ns -> 11 cycles.
    localparam int N_RC_STRETCH = 11;

    logic clk = 0, reset_n = 0;
    always #(CLK_NS/2.0) clk = ~clk;

    logic        cs_n = 1, ras_n = 1, cas_n = 1, we_n = 1;
    logic [1:0]  ba   = 0;
    logic [12:0] addr = 0;

    sdram_timing_check #(.CLK_KHZ(CLK_KHZ)) uut (
        .clk(clk), .reset_n(reset_n), .cke(1'b1),
        .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .ba(ba), .addr(addr));

    // Same stimulus, a device that needs a longer tRC than tRAS + tRP.
    sdram_timing_check #(.CLK_KHZ(CLK_KHZ), .T_RC_NS(105.0)) uut_rc (
        .clk(clk), .reset_n(reset_n), .cke(1'b1),
        .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .ba(ba), .addr(addr));

    // ---- command drivers.  Each occupies exactly one cycle. ----------------
    //
    // Timing discipline: every task both starts and ends just after a clock
    // edge, so stimulus is never changed at the instant the checker samples it.
    // `drive` therefore presents its command for exactly one edge, and
    // `ACT(0); nop(k); RD(0)` puts exactly k+1 cycles between the two commands.
    // The counting has to be exact for a threshold test to mean anything.
    task automatic drive(input logic r, input logic c, input logic w,
                         input logic [1:0] b, input logic [12:0] a);
        begin
            cs_n = 1'b0; ras_n = r; cas_n = c; we_n = w; ba = b; addr = a;
            @(posedge clk); #0.1;
            ras_n = 1'b1; cas_n = 1'b1; we_n = 1'b1;
        end
    endtask

    task automatic ACT (input logic [1:0] b); drive(0,1,1,b,13'h100); endtask
    task automatic RD  (input logic [1:0] b); drive(1,0,1,b,13'h000); endtask
    task automatic WR  (input logic [1:0] b); drive(1,0,0,b,13'h000); endtask
    task automatic PRE (input logic [1:0] b); drive(0,1,0,b,13'h000); endtask
    task automatic PREA;                      drive(0,1,0,2'd0,13'h400); endtask
    task automatic MRS;                       drive(0,0,0,2'd0,13'h030); endtask
    task automatic REF;                       drive(0,0,1,2'd0,13'h000); endtask
    task automatic nop(input int n);
        begin repeat (n) begin @(posedge clk); #0.1; end end
    endtask

    // Return every bank to closed with all counters long expired, so each case
    // starts from the same place and only the constraint under test can fire.
    task automatic quiesce;
        begin nop(24); PREA; nop(24); end
    endtask

    // ---- scoreboard --------------------------------------------------------
    int unsigned base, base_rc;
    int          pass_n = 0, fail_n = 0;

    task automatic expect_delta(input string name, input int unsigned want);
        int unsigned got;
        begin
            got = uut.errs - base;
            if (got == want) begin
                pass_n++;
                $display("  PASS  %-42s %0d violation%s", name, got,
                         (got == 1) ? "" : "s");
            end else begin
                fail_n++;
                $display("  FAIL  %-42s expected %0d, got %0d", name, want, got);
            end
            base = uut.errs;
            base_rc = uut_rc.errs;
        end
    endtask

    task automatic expect_delta_rc(input string name, input int unsigned want);
        int unsigned got;
        begin
            got = uut_rc.errs - base_rc;
            if (got == want) begin
                pass_n++;
                $display("  PASS  %-42s %0d violation%s", name, got,
                         (got == 1) ? "" : "s");
            end else begin
                fail_n++;
                $display("  FAIL  %-42s expected %0d, got %0d", name, want, got);
            end
            base = uut.errs;
            base_rc = uut_rc.errs;
        end
    endtask

    initial begin
        @(posedge clk); #0.1;            // establish the "just after an edge" phase
        nop(4); reset_n = 1; nop(4);
        base = 0; base_rc = 0;

        $display("");
        $display("=========================================================================");
        $display(" sdram_timing_check self-test   (thresholds hand-derived at %0d MHz)",
                 CLK_KHZ/1000);
        $display("=========================================================================");

        // ---- tRCD: ACT -> RD on the same bank --------------------------
        quiesce; ACT(0); nop(N_RCD-2); RD(0);
        expect_delta($sformatf("tRCD at %0d cycles (one short) rejected", N_RCD-1), 1);
        quiesce; ACT(0); nop(N_RCD-1); RD(0);
        expect_delta($sformatf("tRCD at %0d cycles (exact)     accepted", N_RCD), 0);

        // ---- tRAS: ACT -> PRE on the same bank -------------------------
        quiesce; ACT(0); nop(N_RAS-2); PRE(0);
        expect_delta($sformatf("tRAS at %0d cycles (one short) rejected", N_RAS-1), 1);
        quiesce; ACT(0); nop(N_RAS-1); PRE(0);
        expect_delta($sformatf("tRAS at %0d cycles (exact)     accepted", N_RAS), 0);

        // ---- tRP: PRE -> ACT on the same bank --------------------------
        // The leading ACT is held open past tRAS so only tRP can fire.
        quiesce; ACT(0); nop(N_RAS+2); PRE(0); nop(N_RP-2); ACT(0);
        expect_delta($sformatf("tRP  at %0d cycles (one short) rejected", N_RP-1), 1);
        quiesce; ACT(0); nop(N_RAS+2); PRE(0); nop(N_RP-1); ACT(0);
        expect_delta($sformatf("tRP  at %0d cycles (exact)     accepted", N_RP), 0);

        // ---- tRRD: ACT -> ACT on different banks -----------------------
        quiesce; ACT(0); nop(N_RRD-2); ACT(1);
        expect_delta($sformatf("tRRD at %0d cycles (one short) rejected", N_RRD-1), 1);
        quiesce; ACT(0); nop(N_RRD-1); ACT(1);
        expect_delta($sformatf("tRRD at %0d cycles (exact)     accepted", N_RRD), 0);

        // ---- tWR: write data -> PRE ------------------------------------
        // The ACT is far enough back that tRAS and tRCD are both satisfied.
        quiesce; ACT(0); nop(N_RAS+2); WR(0); nop(N_WR-2); PRE(0);
        expect_delta($sformatf("tWR  at %0d cycles (one short) rejected", N_WR-1), 1);
        quiesce; ACT(0); nop(N_RAS+2); WR(0); nop(N_WR-1); PRE(0);
        expect_delta($sformatf("tWR  at %0d cycles (exact)     accepted", N_WR), 0);

        // ---- tMRD: LOAD MODE -> any command ----------------------------
        quiesce; MRS; nop(N_MRD-2); ACT(0);
        expect_delta($sformatf("tMRD at %0d cycles (one short) rejected", N_MRD-1), 1);
        quiesce; MRS; nop(N_MRD-1); ACT(0);
        expect_delta($sformatf("tMRD at %0d cycles (exact)     accepted", N_MRD), 0);

        // ---- tRC, on the instance where it is the binding constraint ---
        quiesce; ACT(0); nop(N_RAS+2); PRE(0);
        nop(N_RC_STRETCH - N_RAS - 4 - 1); ACT(0);
        expect_delta_rc($sformatf("tRC  at %0d cycles (one short) rejected",
                                  N_RC_STRETCH-1), 1);
        quiesce; ACT(0); nop(N_RAS+2); PRE(0);
        nop(N_RC_STRETCH - N_RAS - 4); ACT(0);
        expect_delta_rc($sformatf("tRC  at %0d cycles (exact)     accepted",
                                  N_RC_STRETCH), 0);

        // ---- tRFC: AUTO REFRESH -> ACTIVATE ----------------------------
        // tRFC was not checked at all until now, and it is the only refresh
        // timing there is. A controller that activates too soon after a
        // refresh reads a row that has not finished being restored.
        quiesce; REF; nop(N_RFC-2); ACT(0);
        expect_delta($sformatf("tRFC at %0d cycles (one short) rejected", N_RFC-1), 1);
        quiesce; REF; nop(N_RFC-1); ACT(0);
        expect_delta($sformatf("tRFC at %0d cycles (exact)     accepted", N_RFC), 0);

        // ---- tRFC: AUTO REFRESH -> AUTO REFRESH ------------------------
        quiesce; REF; nop(N_RFC-2); REF;
        expect_delta($sformatf("tRFC REF->REF at %0d cycles rejected", N_RFC-1), 1);
        quiesce; REF; nop(N_RFC-1); REF;
        expect_delta($sformatf("tRFC REF->REF at %0d cycles accepted", N_RFC), 0);

        // ---- read -> write bus turnaround ------------------------------
        // Not a device timing but a contention hazard on the shared DQ bus,
        // and invisible to any functional model: the model stops driving and
        // the controller reads back its own value.
        quiesce; ACT(0); nop(N_RAS+2); RD(0); nop(N_WTR-2); WR(0);
        expect_delta($sformatf("read->write at %0d cycles (one short) rejected", N_WTR-1), 1);
        quiesce; ACT(0); nop(N_RAS+2); RD(0); nop(N_WTR-1); WR(0);
        expect_delta($sformatf("read->write at %0d cycles (exact)     accepted", N_WTR), 0);

        // ---- structural checks -----------------------------------------
        quiesce; ACT(0); nop(8); ACT(0);
        expect_delta("ACTIVATE to an already-open bank rejected", 1);
        quiesce; RD(0);
        expect_delta("column command to a closed bank rejected", 1);
        quiesce; ACT(0); nop(8); REF;                       // REFRESH, bank open
        expect_delta("REFRESH with a bank still open rejected", 1);

        $display("-------------------------------------------------------------------------");
        $display("  %0d passed, %0d failed", pass_n, fail_n);
        $display("=========================================================================");
        $display("");
        if (fail_n != 0) $fatal(1, "timing checker self-test FAILED");
        $finish;
    end

    initial begin
        #200_000;
        $fatal(1, "self-test did not finish");
    end

endmodule
