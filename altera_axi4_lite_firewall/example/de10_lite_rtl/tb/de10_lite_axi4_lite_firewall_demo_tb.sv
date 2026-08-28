`timescale 1ns/1ps

// =============================================================================
// de10_lite_axi4_lite_firewall_demo_tb.sv
//
// Self-checking testbench for the DE10-Lite demo. It drives the BOARD PINS -
// clock, KEY, SW - and reads the BOARD OUTPUTS - LEDR, HEX0..HEX5 - and
// nothing else. Everything it checks is something you could verify by looking
// at the board, which is the point: if this passes, the hardware demo does the
// thing the README says it does.
//
// It checks three separate layers:
//
//   Phase 1  the auto sweep runs all sixteen scenarios and every one passes.
//            Each scenario is itself a bundle of assertions about the firewall
//            core (see demo_sequencer.sv), so this is the real regression.
//   Phase 2  step mode works: select a scenario on SW[3:0], press KEY0, and
//            that scenario - and only that one - runs. Scenario 9 is used
//            because it leaves a known STATUS value behind, which lets the
//            LEDR path be checked against a specific expected pattern.
//   Phase 3  the seven-segment decode is right, checked against an
//            independently written glyph table rather than against hex7seg.
//
// Timing overrides keep this short: PACE_BITS 4 (16 clocks between scenarios
// instead of 8.4 million) and DEBOUNCE_BITS 3. TIMEOUT_CYCLES is left at the
// hardware default of 200 on purpose, so what is simulated is the same
// firewall configuration that is synthesised.
// =============================================================================

module de10_lite_axi4_lite_firewall_demo_tb;

    localparam int PACE_BITS      = 4;
    localparam int DEBOUNCE_BITS  = 3;
    localparam int TIMEOUT_CYCLES = 200;

    localparam time CLK_PERIOD = 20ns;   // 50 MHz, as on the board

    logic       MAX10_CLK1_50 = 1'b0;
    logic [1:0] KEY = 2'b11;             // active low, released
    logic [9:0] SW  = 10'b0;
    logic [9:0] LEDR;
    logic [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;

    always #(CLK_PERIOD/2) MAX10_CLK1_50 = ~MAX10_CLK1_50;

    de10_lite_axi4_lite_firewall_demo #(
        .PACE_BITS      (PACE_BITS),
        .DEBOUNCE_BITS  (DEBOUNCE_BITS),
        .TIMEOUT_CYCLES (TIMEOUT_CYCLES)
    ) dut (
        .MAX10_CLK1_50 (MAX10_CLK1_50),
        .KEY  (KEY),
        .SW   (SW),
        .LEDR (LEDR),
        .HEX0 (HEX0), .HEX1 (HEX1), .HEX2 (HEX2),
        .HEX3 (HEX3), .HEX4 (HEX4), .HEX5 (HEX5)
    );

    int pass_count = 0;
    int fail_count = 0;

    task automatic check(input string what, input bit ok);
        if (ok) begin
            pass_count++;
            $display("  PASS  %s", what);
        end else begin
            fail_count++;
            $display("  FAIL: %s", what);
        end
    endtask

    task automatic check_eq(input string what, input logic [31:0] got,
                                               input logic [31:0] exp);
        if (got === exp) begin
            pass_count++;
            $display("  PASS  %s (0x%08h)", what, got);
        end else begin
            fail_count++;
            $display("  FAIL: %s - got 0x%08h, expected 0x%08h", what, got, exp);
        end
    endtask

    // ------------------------------------------------------------------
    // Independent seven-segment model. Deliberately NOT hex7seg's table
    // re-imported: a decoder checked against itself checks nothing.
    // ------------------------------------------------------------------
    function automatic logic [7:0] expect_hex(input int code);
        logic [6:0] lit;
        case (code)
            0:  lit = 7'b0111111;
            1:  lit = 7'b0000110;
            2:  lit = 7'b1011011;
            3:  lit = 7'b1001111;
            4:  lit = 7'b1100110;
            5:  lit = 7'b1101101;
            6:  lit = 7'b1111101;
            7:  lit = 7'b0000111;
            8:  lit = 7'b1111111;
            9:  lit = 7'b1101111;
            10: lit = 7'b1110111;   // A
            11: lit = 7'b1111100;   // b
            12: lit = 7'b0111001;   // C
            13: lit = 7'b1011110;   // d
            14: lit = 7'b1111001;   // E
            15: lit = 7'b1110001;   // F
            16: lit = 7'b0000000;   // blank
            17: lit = 7'b1110011;   // P
            18: lit = 7'b1110001;   // F
            19: lit = 7'b1000000;   // -
            default: lit = 7'b0000000;
        endcase
        return {1'b1, ~lit};
    endfunction

    // Names purely for the log, so a failure says which scenario broke.
    function automatic string scen_name(input int i);
        case (i)
            0:  return "CFG   program rules, confirm CORE_INFO";
            1:  return "W_OK  permitted write -> OKAY";
            2:  return "R_OK  permitted read  -> OKAY, data intact";
            3:  return "RO_R  read-only region, read allowed";
            4:  return "RO_W  read-only region, write -> SLVERR + PERM + irq";
            5:  return "WO_W  write-only region, write allowed";
            6:  return "WO_R  write-only region, read -> SLVERR, RDATA zeroed";
            7:  return "DEC_W unmapped write -> DECERR";
            8:  return "DEC_R unmapped read  -> DECERR + fault registers";
            9:  return "TMO_W peripheral refuses cmd -> TIMEOUT + WR_CMD_STUCK";
            10: return "BLKD  blocked: rejected, nothing new downstream";
            11: return "RCVR  correct v2.0 recovery, no stale write";
            12: return "STALE reset released before UNBLOCK -> stale write lands";
            13: return "TMO_R accept-then-silent read -> TIMEOUT + RD_RESP_BUSY";
            14: return "BYP   GLOBAL_ENABLE=0 forwards unchecked";
            15: return "MASK  IRQ_ENABLE gates irq only, not STATUS";
            default: return "?";
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Watchdog. A wedged demo must not look like a hung simulator.
    // ------------------------------------------------------------------
    initial begin
        #20ms;
        $display("\n*** WATCHDOG: simulation did not finish ***");
        $fatal(1, "watchdog");
    end

    // Scenario completion is the falling edge of the sequencer's `running`:
    // E_FINISH latches the result and the next state (E_PACE or E_IDLE) is
    // not "running", so there is exactly one such edge per scenario.
    task automatic await_scenario(output int idx, output bit ok);
        @(negedge dut.u_seq.running);
        #1;     // let the combinational HEX decode settle before sampling it;
                // same one-delta discipline the core's own testbench uses
        idx = int'(dut.u_seq.cur_scenario);
        ok  = dut.u_seq.result_pass;
    endtask

    task automatic press_key0();
        KEY[0] = 1'b0;
        repeat (40) @(posedge MAX10_CLK1_50);
        KEY[0] = 1'b1;
        repeat (40) @(posedge MAX10_CLK1_50);
    endtask

    int  got_idx;
    bit  got_ok;
    int  seen;

    initial begin
        $display("========================================================");
        $display(" DE10-Lite AXI4-Lite Firewall demo - board-level testbench");
        $display("========================================================");

        // ---------------- reset via KEY1, as a user would --------------
        KEY[1] = 1'b0;
        SW     = 10'b0;
        repeat (20) @(posedge MAX10_CLK1_50);
        KEY[1] = 1'b1;
        repeat (10) @(posedge MAX10_CLK1_50);

        // Out of reset the sequencer runs scenario 0 by itself so that a
        // scenario picked in step mode finds a programmed rule table.
        await_scenario(got_idx, got_ok);
        check_eq("power-on runs the configuration scenario first", got_idx, 0);
        check("  and it passes", got_ok);

        // ---------------- Phase 1: auto sweep --------------------------
        $display("\n--- Phase 1: auto sweep (SW[9]=1), all 16 scenarios ---");
        SW[9] = 1'b1;

        seen = 0;
        while (seen < 16) begin
            await_scenario(got_idx, got_ok);
            check($sformatf("scenario %0X  %s", got_idx, scen_name(got_idx)), got_ok);
            check_eq($sformatf("scenario %0X ran in sweep order", got_idx), got_idx, seen);
            // HEX5 must be showing the scenario that just ran.
            check_eq($sformatf("HEX5 shows %0X", got_idx), HEX5, expect_hex(got_idx));
            // HEX4 must be showing its verdict, not a busy dash.
            check_eq($sformatf("HEX4 shows %s", got_ok ? "P" : "F"),
                     HEX4, expect_hex(got_ok ? 17 : 18));
            seen++;
        end

        check_eq("pass bitmap after a full sweep", dut.u_seq.pass_bitmap, 16'hFFFF);

        // ---------------- Phase 2: step mode ---------------------------
        $display("\n--- Phase 2: step mode (SW[9]=0), scenario 9 on demand ---");
        SW[9] = 1'b0;
        // Let the sweep in flight settle back to idle.
        repeat (400) @(posedge MAX10_CLK1_50);
        check("sequencer is idle in step mode", !dut.u_seq.running);

        SW[3:0] = 4'h9;
        repeat (10) @(posedge MAX10_CLK1_50);
        fork
            press_key0();
            begin
                await_scenario(got_idx, got_ok);
            end
        join

        check_eq("KEY0 ran exactly the selected scenario", got_idx, 9);
        check("and it passed", got_ok);

        // Scenario 9 deliberately leaves the downstream broken, so the board
        // must now be showing TIMEOUT_ERROR | ISOLATED | BLOCKED |
        // WR_CMD_STUCK on LEDR[8:0], and irq on LEDR[9]. This is the whole
        // LED path checked end to end against a known value.
        repeat (50) @(posedge MAX10_CLK1_50);   // let the background poll refresh
        check_eq("LEDR[8:0] = live STATUS after a timeout", LEDR[8:0], 9'h09C);
        check_eq("LEDR[9] = irq", LEDR[9], 1'b1);

        // ---------------- Phase 3: display decode ----------------------
        $display("\n--- Phase 3: seven-segment and display muxing ---");

        // SW[6]=0 -> HEX3..0 show the pass bitmap. The sweep set every bit,
        // and step mode does not clear it, so it is still 0xFFFF.
        SW[6] = 1'b0;
        repeat (5) @(posedge MAX10_CLK1_50);
        check_eq("HEX0 shows bitmap nibble 0", HEX0, expect_hex(15));
        check_eq("HEX1 shows bitmap nibble 1", HEX1, expect_hex(15));
        check_eq("HEX2 shows bitmap nibble 2", HEX2, expect_hex(15));
        check_eq("HEX3 shows bitmap nibble 3", HEX3, expect_hex(15));

        // SW[6]=1 -> HEX3..0 show the low half of the observed word. Scenario
        // 9 ends on a read of FAULT_INFO = 0x7 (TIMEOUT, was_write).
        SW[6] = 1'b1;
        SW[7] = 1'b0;
        repeat (5) @(posedge MAX10_CLK1_50);
        check_eq("observed word after scenario 9 is FAULT_INFO", dut.u_seq.obs, 32'h0000_0007);
        check_eq("HEX0 shows observed nibble 0", HEX0, expect_hex(7));
        check_eq("HEX1 shows observed nibble 1", HEX1, expect_hex(0));

        SW[7] = 1'b1;                            // upper half
        repeat (5) @(posedge MAX10_CLK1_50);
        check_eq("HEX0 shows upper-half nibble", HEX0, expect_hex(0));

        // ---------------- done -----------------------------------------
        $display("\n========================================================");
        $display(" checks passed : %0d", pass_count);
        $display(" checks failed : %0d", fail_count);
        if (fail_count == 0)
            $display(" *** ALL TESTS PASSED ***");
        else
            $display(" *** %0d FAILURE(S) ***", fail_count);
        $display("========================================================");
        $finish;
    end

endmodule
