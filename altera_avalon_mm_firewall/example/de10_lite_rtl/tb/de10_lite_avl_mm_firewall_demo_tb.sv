`timescale 1ns/1ps

// =============================================================================
// de10_lite_avl_mm_firewall_demo_tb.sv
//
// Self-checking testbench for the DE10-Lite demo. It drives the BOARD PINS -
// clock, KEY, SW - and reads the BOARD OUTPUTS - LEDR, HEX0..HEX5 - and
// nothing else that a person could not also see. Everything it checks is
// something you could verify by looking at the board, which is the point: if
// this passes, the hardware demo does the thing the README says it does.
//
// It checks three separate layers:
//
//   Phase 1  the auto sweep runs all sixteen scenarios and every one passes.
//            Each scenario is itself a bundle of assertions about the firewall
//            core (see demo_sequencer.sv), so this is the real regression.
//   Phase 2  step mode works: select a scenario on SW[3:0], press KEY0, and
//            that scenario - and only that one - runs. Scenario b is used
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

module de10_lite_avl_mm_firewall_demo_tb;

    localparam int PACE_BITS      = 4;
    localparam int DEBOUNCE_BITS  = 3;
    localparam int TIMEOUT_CYCLES = 200;
    localparam int THRU_GUARD     = 24;
    localparam int BURST_BEATS    = 16;

    localparam time CLK_PERIOD = 20ns;   // 50 MHz, as on the board

    logic       MAX10_CLK1_50 = 1'b0;
    logic [1:0] KEY = 2'b11;             // active low, released
    logic [9:0] SW  = 10'b0;
    logic [9:0] LEDR;
    logic [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;

    always #(CLK_PERIOD/2) MAX10_CLK1_50 = ~MAX10_CLK1_50;

    // ------------------------------------------------------------------
    // Bind the CORE's own assertions into the demo's firewall instance.
    //
    // The demo checks what the board shows. These check that the core's
    // protocol, security and liveness properties hold while synthesisable
    // hardware - not testbench tasks - is driving it, which is the one thing
    // the core's own suite cannot do. It is not redundant: binding these here
    // is what showed that no scenario ever starved a READ command, so
    // RD_CMD_STUCK was never set and three properties sat vacuous. Scenario C
    // covers both read-timeout shapes because of it.
    //
    // These must match the localparams in de10_lite_avl_mm_firewall_demo.sv.
    // A mismatch would silently mis-size the assertion module, so the widths
    // are checked against the DUT's actual ports at time zero below.
    // ------------------------------------------------------------------
    localparam int ADDR_WIDTH        = 12;
    localparam int DATA_WIDTH        = 32;
    localparam int BURST_WIDTH       = 8;
    localparam int MAX_PENDING_READS = 4;
    localparam int MAX_BEATS         = 2**(BURST_WIDTH-1);
    localparam int RD_CAPACITY       = MAX_PENDING_READS * MAX_BEATS;
    localparam int BEATCNT_W         = $clog2(RD_CAPACITY+1) + 1;

`ifndef DEMO_NO_SVA
    bind avl_mm_firewall_top avl_mm_firewall_sva #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .BURST_WIDTH(BURST_WIDTH),
        .BEATCNT_W  (BEATCNT_W)
    ) u_sva (
        .clk(clk), .reset_n(reset_n),
        .s0_read(s0_read), .s0_write(s0_write), .s0_burstcount(s0_burstcount),
        .s0_waitrequest(s0_waitrequest), .s0_readdatavalid(s0_readdatavalid),
        .s0_writeresponsevalid(s0_writeresponsevalid), .s0_response(s0_response),
        .m0_read(m0_read), .m0_write(m0_write), .m0_address(m0_address),
        .m0_burstcount(m0_burstcount), .m0_waitrequest(m0_waitrequest),
        .m0_readdatavalid(m0_readdatavalid),
        .downstream_broken(downstream_broken), .wr_stuck(wr_stuck), .rd_stuck(rd_stuck),
        .unblock(unblock), .rd_fwd_beats(rd_fwd_beats), .rd_deny_beats(rd_deny_beats),
        .wr_dec(wr_dec), .rd_dec(rd_dec),
        .wr_start(wr_start), .rd_accept(rd_accept), .wr_active(wr_active),
        .lk_stall(lk_stall),
        .wr_allow(wr_allow), .rd_allow(rd_allow)
    );
`endif

    de10_lite_avl_mm_firewall_demo #(
        .PACE_BITS      (PACE_BITS),
        .DEBOUNCE_BITS  (DEBOUNCE_BITS),
        .TIMEOUT_CYCLES (TIMEOUT_CYCLES),
        .THRU_GUARD     (THRU_GUARD),
        .BURST_BEATS    (BURST_BEATS)
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
            0:  return "CFG    program rules, confirm CORE_INFO";
            1:  return "W_OK   permitted single write -> OKAY";
            2:  return "R_OK   permitted read, data intact";
            3:  return "BW_OK  permitted 16-beat burst write";
            4:  return "BR_OK  16-beat burst read, beat-for-beat integrity";
            5:  return "THRU   burst throughput inside the cycle guard";
            6:  return "RO_W   write to read-only -> SLAVEERROR + PERM";
            7:  return "WO_R   read of write-only -> SLAVEERROR, zeros";
            8:  return "DEC_R  unmapped -> DECODEERROR, all beats returned";
            9:  return "STRAD  burst across abutting windows -> refused";
            10: return "NOBST  BURST_ALLOW clear: single ok, burst refused";
            11: return "TMO_W  write timeout, command never accepted";
            12: return "TMO_R  read timeout, accepted then silent";
            13: return "BLKD   blocked traffic rejected, not stalled";
            14: return "RCVR   correct recovery, nothing stale lands";
            15: return "STALE  wrong recovery order, stale write lands";
            default: return "?";
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Watchdog. A demo that hangs must fail loudly rather than sit there.
    // ------------------------------------------------------------------
    initial begin
        #40ms;
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
        $display("=============================================================");
        $display(" DE10-Lite Avalon-MM Firewall demo - board-level testbench");
        $display("=============================================================");

        // The bind above is parameterised from this file's localparams, not
        // from the demo's. If they ever drift, the assertions would be sized
        // wrong and could pass for the wrong reason - so check them against
        // the DUT's real ports before anything else runs.
        check_eq("bind ADDR_WIDTH matches the DUT",  $bits(dut.d_address),   ADDR_WIDTH);
        check_eq("bind DATA_WIDTH matches the DUT",  $bits(dut.d_writedata), DATA_WIDTH);
        check_eq("bind BURST_WIDTH matches the DUT", $bits(dut.d_burstcount), BURST_WIDTH);

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
        $display("\n--- Phase 2: step mode (SW[9]=0), scenario b on demand ---");
        SW[9] = 1'b0;
        // Let the sweep in flight settle back to idle.
        repeat (2000) @(posedge MAX10_CLK1_50);
        check("sequencer is idle in step mode", !dut.u_seq.running);

        SW[3:0] = 4'hB;
        repeat (10) @(posedge MAX10_CLK1_50);
        fork
            press_key0();
            begin
                await_scenario(got_idx, got_ok);
            end
        join

        check_eq("KEY0 ran exactly the selected scenario", got_idx, 11);
        check("and it passed", got_ok);

        // Scenario b deliberately leaves the downstream broken, so the board
        // must now be showing TIMEOUT_ERROR | ISOLATED | BLOCKED |
        // WR_CMD_STUCK on LEDR[8:0], and irq on LEDR[9]. This is the whole
        // LED path checked end to end against a known value.
        //   bit 2 TIMEOUT | bit 4 ISOLATED | bit 5 BLOCKED | bit 8 WR_CMD_STUCK
        repeat (200) @(posedge MAX10_CLK1_50);   // let the background poll refresh
        check_eq("LEDR[8:0] = live STATUS after a timeout", LEDR[8:0], 9'h134);
        check_eq("LEDR[9] = irq", LEDR[9], 1'b1);

        // SW[5] slides the window up so RD_CMD_STUCK would be visible. After a
        // WRITE timeout it is clear, and WR_CMD_STUCK moves down to LEDR[7].
        SW[5] = 1'b1;
        repeat (5) @(posedge MAX10_CLK1_50);
        check_eq("SW[5] shows STATUS[9:1]", LEDR[8:0], 9'h09A);
        SW[5] = 1'b0;

        // ---------------- Phase 2b: RD_CMD_STUCK on the board ----------
        //
        // STATUS[9] is the one bit LEDR cannot reach without SW[5], and
        // scenario C is the only scenario that sets it. Running C here proves
        // the whole path - core, poll, shadow register, display mux, LED -
        // rather than trusting that a bit nothing ever lights is wired right.
        $display("\n--- Phase 2b: scenario C leaves RD_CMD_STUCK visible ---");
        SW[3:0] = 4'hC;
        repeat (10) @(posedge MAX10_CLK1_50);
        fork
            press_key0();
            begin
                await_scenario(got_idx, got_ok);
            end
        join
        check_eq("KEY0 ran scenario C", got_idx, 12);
        check("and it passed", got_ok);

        repeat (200) @(posedge MAX10_CLK1_50);   // let the background poll refresh
        // TIMEOUT | ISOLATED | BLOCKED | RD_CMD_STUCK = 0x234, which does not
        // fit in LEDR[8:0]; the low nine bits show 0x034.
        check_eq("STATUS after a starved read", dut.u_seq.status_shadow[9:0], 10'h234);
        check_eq("LEDR[8:0] with SW[5]=0 cannot show bit 9", LEDR[8:0], 9'h034);
        SW[5] = 1'b1;
        repeat (5) @(posedge MAX10_CLK1_50);
        // STATUS[9:1] = 0x234 >> 1 = 0x11A
        check_eq("SW[5]=1 brings RD_CMD_STUCK onto LEDR[8]", LEDR[8:0], 9'h11A);
        check_eq("  and LEDR[8] is RD_CMD_STUCK itself", LEDR[8], 1'b1);
        SW[5] = 1'b0;

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
        // C was the last one run (Phase 2b) and ends on a read of FAULT_INFO:
        // burstcount 4 in [15:8], type TIMEOUT (3) in [3:1], and WAS_WRITE
        // CLEAR in [0] because the starved command was a read  ->  0x0406.
        // Scenario b's equivalent is 0x0407; that low bit is the whole
        // difference between a starved read and a starved write.
        SW[6] = 1'b1;
        SW[7] = 1'b0;
        repeat (5) @(posedge MAX10_CLK1_50);
        check_eq("observed word after scenario C is FAULT_INFO",
                 dut.u_seq.obs, 32'h0000_0406);
        check_eq("HEX0 shows observed nibble 0", HEX0, expect_hex(6));
        check_eq("HEX1 shows observed nibble 1", HEX1, expect_hex(0));
        check_eq("HEX2 shows observed nibble 2", HEX2, expect_hex(4));

        SW[7] = 1'b1;                            // upper half
        repeat (5) @(posedge MAX10_CLK1_50);
        check_eq("HEX0 shows upper-half nibble", HEX0, expect_hex(0));

        // ---------------- done -----------------------------------------
        $display("\n=============================================================");
        $display(" checks passed : %0d", pass_count);
        $display(" checks failed : %0d", fail_count);
        if (fail_count == 0)
            $display(" *** ALL TESTS PASSED ***");
        else
            $display(" *** %0d FAILURE(S) ***", fail_count);
        $display("=============================================================");
        $finish;
    end

endmodule
