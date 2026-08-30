`timescale 1ns/1ps

// =============================================================================
// de10_lite_sdram_demo_tb.sv
//
// Board-level simulation of the SDRAM demonstration, against this project's
// own SDRAM device model - the one with a row open per bank.
//
// WHAT THIS DOES AND DOES NOT PROVE
// ---------------------------------
// The device model is functional, not timing-accurate: it decodes the command
// set, tracks a row per bank and pipelines read data by the CAS latency, but it
// does not model tRCD, tRP, tRFC, tWR, the refresh interval, or data retention.
// So on its own it proves the controller drives the right commands to the right
// addresses and returns the right data, and that the sequencer and its checker
// behave.
//
// sdram_timing_check is bound alongside it and closes the timing half: it
// checks tRC, tRAS, tRP, tRCD, tRRD, tWR and tMRD against the same nanosecond
// figures the preset carries, and has its own threshold self-test. What remains
// unproven here is data RETENTION, which no functional model can show - only
// hardware does that, and run_on_board.sh is what does it.
//
// Scenario 6 (refresh retention) therefore passes here for free. That is
// called out as a check with a comment rather than quietly counted as a win.
//
// The scenario sizes are shrunk through parameters - see MARCH_WORDS - because
// scenario 7 marches over the whole 64 MB chip on hardware, which is 67
// million simulated cycles.
//
// Run with: simulation/verilator/run_sim.sh   (no licence, no Quartus)
// =============================================================================

module de10_lite_sdram_demo_tb;

    localparam int AW = 25, DW = 16;

    // Shrunk for simulation. The RTL defaults are the real ones.
    localparam int unsigned TB_MARCH_WORDS  = 32'd4096;
    localparam int unsigned TB_REFRESH_IDLE = 32'd20_000;
    localparam int unsigned TB_INIT_WAIT    = 32'd1024;
    // The RTL default is 1.5 billion cycles - a wedge detector sized for
    // hardware. Phase 9 has to actually reach it, so it is shortened here to
    // comfortably more than the longest simulated scenario (scenario 6, about
    // 25,000 cycles with the shortened refresh idle).
    localparam int unsigned TB_WATCHDOG     = 32'd200_000;

    // Must match the sequencer's own fixed addresses.
    localparam logic [AW-1:0] BE_ADDR = 25'h0005678;

    logic clk = 1'b0, resetn = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz, as on the board

    int checks_passed = 0, checks_failed = 0;

    task automatic check(input string what, input bit ok);
        if (ok) begin checks_passed++; $display("  PASS  %s", what); end
        else    begin checks_failed++; $display("  FAIL  %s", what); end
    endtask

    // ---- controls --------------------------------------------------------
    logic [3:0] select = '0;
    logic       auto_mode = 1'b0, freeze = 1'b0, start_pulse = 1'b0, seq_reset = 1'b0;

    // ---- sequencer status -------------------------------------------------
    logic        running, result_valid, result_pass;
    logic [3:0]  cur_scenario, done_count;
    logic [7:0]  pass_bitmap;
    logic [2:0]  err_code;
    logic [AW-1:0] fail_addr;
    logic [DW-1:0] fail_expected, fail_actual;
    logic [31:0] perf_wr_cycles, perf_rd_cycles, perf_words;

    // ---- sequencer <-> master --------------------------------------------
    logic cmd_valid, cmd_ready, cmd_write, rsp_valid;
    logic [AW-1:0] cmd_addr;
    logic [DW-1:0] cmd_wdata, rsp_data;
    logic [1:0]    cmd_be;

    // ---- master <-> controller -------------------------------------------
    logic [AW-1:0] avm_address;
    logic [1:0]    avm_byteenable_n;
    logic          avm_chipselect, avm_read_n, avm_write_n;
    logic [DW-1:0] avm_writedata, avm_readdata;
    logic          avm_readdatavalid, avm_waitrequest;

    // ---- SDRAM pins -------------------------------------------------------
    wire [12:0] DRAM_ADDR;
    wire [1:0]  DRAM_BA, DRAM_DQM;
    wire        DRAM_CAS_N, DRAM_CKE, DRAM_CS_N, DRAM_RAS_N, DRAM_WE_N;
    wire [15:0] DRAM_DQ;

    demo_sdram_seq #(
        .INIT_WAIT_CYCLES    (TB_INIT_WAIT),
        .REFRESH_IDLE_CYCLES (TB_REFRESH_IDLE),
        .WATCHDOG_CYCLES     (TB_WATCHDOG),
        .MARCH_WORDS         (TB_MARCH_WORDS)
    ) u_seq (
        .clk(clk), .resetn(resetn),
        .select(select), .auto_mode(auto_mode), .freeze(freeze),
        .start_pulse(start_pulse), .seq_reset(seq_reset),
        .running(running), .cur_scenario(cur_scenario),
        .result_valid(result_valid), .result_pass(result_pass),
        .pass_bitmap(pass_bitmap), .done_count(done_count), .err_code(err_code),
        .fail_addr(fail_addr), .fail_expected(fail_expected), .fail_actual(fail_actual),
        .perf_wr_cycles(perf_wr_cycles), .perf_rd_cycles(perf_rd_cycles),
        .perf_words(perf_words),
        .cmd_valid(cmd_valid), .cmd_write(cmd_write), .cmd_addr(cmd_addr),
        .cmd_wdata(cmd_wdata), .cmd_be(cmd_be), .cmd_ready(cmd_ready),
        .rsp_valid(rsp_valid), .rsp_data(rsp_data));

    demo_avl_mm_master #(.ADDR_WIDTH(AW), .DATA_WIDTH(DW)) u_master (
        .clk(clk), .resetn(resetn),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_write(cmd_write),
        .cmd_addr(cmd_addr), .cmd_wdata(cmd_wdata), .cmd_be(cmd_be),
        .rsp_valid(rsp_valid), .rsp_data(rsp_data),
        .avm_address(avm_address), .avm_byteenable_n(avm_byteenable_n),
        .avm_chipselect(avm_chipselect), .avm_writedata(avm_writedata),
        .avm_read_n(avm_read_n), .avm_write_n(avm_write_n),
        .avm_readdata(avm_readdata), .avm_readdatavalid(avm_readdatavalid),
        .avm_waitrequest(avm_waitrequest));

    sdram_perbank_sys u_sys (
        .clk_in_clk(clk), .reset_in_reset_n(resetn),
        .sdram_s1_address(avm_address), .sdram_s1_byteenable_n(avm_byteenable_n),
        .sdram_s1_chipselect(avm_chipselect), .sdram_s1_writedata(avm_writedata),
        .sdram_s1_read_n(avm_read_n), .sdram_s1_write_n(avm_write_n),
        .sdram_s1_readdata(avm_readdata), .sdram_s1_readdatavalid(avm_readdatavalid),
        .sdram_s1_waitrequest(avm_waitrequest),
        .sdram_wire_addr(DRAM_ADDR), .sdram_wire_ba(DRAM_BA),
        .sdram_wire_cas_n(DRAM_CAS_N), .sdram_wire_cke(DRAM_CKE),
        .sdram_wire_cs_n(DRAM_CS_N), .sdram_wire_dq(DRAM_DQ),
        .sdram_wire_dqm(DRAM_DQM), .sdram_wire_ras_n(DRAM_RAS_N),
        .sdram_wire_we_n(DRAM_WE_N));

    // THE DEVICE MODEL HAS TO BE OURS, NOT INTEL'S GENERATED ONE.
    //
    // Intel's model keeps a single open-row register for the whole device, so
    // any ACTIVATE clobbers every bank's row. Against a controller that holds a
    // row open per bank - which is the entire point of this one - it services
    // column commands from whichever row was activated last and reports data
    // corruption for a completely legal command stream. See
    // ../../benchmark/README.md.
    //
    // This one has a row register per bank, like the part on the board. It also
    // means the example simulates with no Quartus installation at all.
    sdram_device_model #(
        .DATA_BITS(16), .ROW_BITS(13), .COL_BITS(10), .BANK_BITS(2), .SA_BITS(13)
    ) u_mem (
        .clk(clk), .zs_addr(DRAM_ADDR), .zs_ba(DRAM_BA), .zs_cas_n(DRAM_CAS_N),
        .zs_cke(DRAM_CKE), .zs_cs_n(DRAM_CS_N), .zs_dq(DRAM_DQ),
        .zs_dqm(DRAM_DQM), .zs_ras_n(DRAM_RAS_N), .zs_we_n(DRAM_WE_N));

    // Neither device model enforces timing, so the command stream is checked
    // separately, against the same nanosecond figures the preset carries. The
    // demonstration this replaces had no equivalent: it could have driven the
    // part illegally and still passed every scenario.
    sdram_timing_check #(.CLK_KHZ(100_000)) u_tchk (
        .clk(clk), .reset_n(resetn), .cke(DRAM_CKE), .cs_n(DRAM_CS_N),
        .ras_n(DRAM_RAS_N), .cas_n(DRAM_CAS_N), .we_n(DRAM_WE_N),
        .ba(DRAM_BA), .addr(DRAM_ADDR));

    // ----------------------------------------------------------------------
    // Reaching into the device model.
    //
    // The model is addressed the way a device is - bank, row, column - so
    // getting at an Avalon address means applying the controller's address map
    // here, in the testbench, where it is visible. That is deliberate: Phase 5
    // below claims the decode is bank = {a[24], a[10]}, row = a[23:11],
    // col = a[9:0], and these two functions are the same claim written as code.
    // If the controller's map and this one ever disagree, Phase 3 fails.
    // ----------------------------------------------------------------------
    function automatic logic [15:0] mem_peek(input logic [24:0] a);
        return u_mem.peek({a[24], a[10]}, a[23:11], a[9:0]);
    endfunction

    task automatic mem_poke(input logic [24:0] a, input logic [15:0] d);
        u_mem.poke({a[24], a[10]}, a[23:11], a[9:0], d);
    endtask

    // ----------------------------------------------------------------------
    // ACTIVATE monitor.
    //
    // This exists to prove the address decode documented in demo_sdram_seq.sv
    // and the README: bank = {addr[24], addr[10]}, row = addr[23:11]. Watching
    // which bank and row the controller ACTIVATEs during a known address walk
    // is direct evidence, rather than taking the generated RTL's word for it.
    // ----------------------------------------------------------------------
    logic [3:0]  act_banks_seen;
    logic [12:0] act_rows_seen_or;
    logic        act_any;
    always_ff @(posedge clk) begin
        if (!resetn) begin
            act_banks_seen   <= '0;
            act_rows_seen_or <= '0;
            act_any          <= 1'b0;
        end else if (!DRAM_CS_N && !DRAM_RAS_N && DRAM_CAS_N && DRAM_WE_N) begin
            act_banks_seen   <= act_banks_seen | (4'd1 << DRAM_BA);
            act_rows_seen_or <= act_rows_seen_or | DRAM_ADDR;
            act_any          <= 1'b1;
        end
    end
    task automatic act_clear();
        @(posedge clk);
        force act_banks_seen = '0; force act_rows_seen_or = '0; force act_any = 1'b0;
        @(posedge clk);
        release act_banks_seen; release act_rows_seen_or; release act_any;
    endtask

    // ----------------------------------------------------------------------
    // The expected word at an address - the sequencer's pattern, written out
    // independently here so a bug in it cannot agree with itself.
    // ----------------------------------------------------------------------
    function automatic logic [15:0] patt(input logic [AW-1:0] a);
        patt = a[15:0] ^ a[24:9] ^ 16'hA5A5;
    endfunction

    // ----------------------------------------------------------------------
    task automatic run_scenario(input logic [3:0] s, output bit finished);
        int unsigned guard;
        logic [3:0] done_before;
        @(posedge clk);
        done_before = done_count;
        select <= s; auto_mode <= 1'b0;
        @(posedge clk);
        start_pulse <= 1'b1; @(posedge clk); start_pulse <= 1'b0;
        guard = 0; finished = 0;
        while (guard < 40_000_000) begin
            @(posedge clk); guard++;
            if (!running && done_count != done_before) begin finished = 1; break; end
        end
    endtask

    // ----------------------------------------------------------------------
    initial begin
        bit fin;
        logic [15:0] got;
        logic [3:0]  d0;

        $display("\n=============================================================");
        $display(" SDRAM demo (per-bank controller) vs this project's device model");
        $display("=============================================================");

        repeat (10) @(posedge clk);
        resetn = 1'b1;
        repeat (20) @(posedge clk);

        // --- Phase 1: every scenario, run on its own --------------------
        $display("\n--- Phase 1: each scenario individually ---");
        for (int s = 0; s <= 7; s++) begin
            d0 = done_count;
            run_scenario(s[3:0], fin);
            check($sformatf("scenario %0d finished", s), fin);
            check($sformatf("scenario %0d passed", s), result_pass === 1'b1);
            check($sformatf("scenario %0d reported itself as scenario %0d", s, s),
                  cur_scenario === s[3:0]);
            check($sformatf("scenario %0d incremented done_count once", s),
                  done_count === ((d0 + 4'd1) & 4'hF));
        end
        $display("  (scenario 6 passes for free here: the model does not model");
        $display("   refresh at all. Only hardware proves retention.)");

        // --- Phase 2: the word counts the block scenarios report ---------
        $display("\n--- Phase 2: reported word counts ---");
        run_scenario(4'd3, fin);
        check("scenario 3 reports 1024 words", perf_words === 32'd1024);
        check("scenario 3 spent a sane number of write cycles",
              perf_wr_cycles > 32'd1024 && perf_wr_cycles < 32'd4000);
        run_scenario(4'd5, fin);
        check("scenario 5 reports 256 words", perf_words === 32'd256);
        check("scenario 5 is much slower per word than scenario 3 (row misses)",
              (perf_wr_cycles / 32'd256) > (32'd1046 / 32'd1024) * 4);
        run_scenario(4'd7, fin);
        check("scenario 7 reports MARCH_WORDS words", perf_words === TB_MARCH_WORDS);

        // --- Phase 3: the data really is in the memory -------------------
        // Reading the model's array directly, at the address the sequencer
        // used. This is what proves the controller's address decode and the
        // model's reconstruction of it agree end to end.
        $display("\n--- Phase 3: contents of the memory model ---");
        run_scenario(4'd3, fin);
        got = mem_peek(25'd0);
        check("word 0 in the model matches the pattern", got === patt(25'd0));
        got = mem_peek(25'd1023);
        check("word 1023 in the model matches the pattern", got === patt(25'd1023));
        run_scenario(4'd4, fin);
        got = mem_peek(25'd1024);
        check("word 1024 (other bank) matches the pattern", got === patt(25'd1024));
        got = mem_peek(25'd2047);
        check("word 2047 matches the pattern", got === patt(25'd2047));

        // --- Phase 4: byte enables reached the chip ----------------------
        $display("\n--- Phase 4: byte enables ---");
        run_scenario(4'd2, fin);
        got = mem_peek(BE_ADDR);
        check("byte-enable scenario left 0x1234 in the memory", got === 16'h1234);

        // --- Phase 5: the documented address decode ----------------------
        // Scenario 4 walks 0..2047. If bank really is {addr[24], addr[10]}
        // and row really is addr[23:11], then crossing word 1024 changes the
        // BANK and not the row: ACTIVATE should be seen for banks 0 and 1
        // only, and always with row 0.
        $display("\n--- Phase 5: bank = {addr[24], addr[10]}, row = addr[23:11] ---");
        act_clear();
        run_scenario(4'd4, fin);
        check("ACTIVATE was issued during the walk", act_any === 1'b1);
        check("ACTIVATE used banks 0 and 1 only, as the decode predicts",
              act_banks_seen === 4'b0011);
        check("every ACTIVATE used row 0 - crossing 1024 changed bank, not row",
              act_rows_seen_or === 13'd0);

        // --- Phase 6: the checker actually detects a fault ---------------
        // Without this, "all scenarios passed" could mean the comparison is
        // broken and everything passes vacuously.
        $display("\n--- Phase 6: fault injection ---");
        // The corruption has to land BETWEEN scenario 3's write pass and its
        // read pass. Corrupting before the run is pointless - the write pass
        // simply puts the right value back, which is what a first attempt at
        // this test did, and it passed vacuously.
        //
        // PH_RBLK is 3, so waiting for p_kind to reach it is waiting for the
        // write pass to finish.
        fork
            run_scenario(4'd3, fin);
            begin
                wait (u_seq.p_kind === 3'd2);           // PH_RBLK
                mem_poke(25'd700, ~patt(25'd700));
            end
        join
        check("a corrupted word makes scenario 3 fail", result_pass === 1'b0);
        check("the failure reports the corrupted address", fail_addr === 25'd700);
        check("the failure reports the expected word", fail_expected === patt(25'd700));
        check("the failure reports the word actually read", fail_actual === ~patt(25'd700));
        check("the failure is reported as a data mismatch", err_code === 3'd1);
        // Re-writing repairs it, so later phases start clean.
        run_scenario(4'd3, fin);
        check("re-running scenario 3 passes again once the word is rewritten",
              result_pass === 1'b1);

        // --- Phase 7: auto sweep ------------------------------------------
        $display("\n--- Phase 7: auto sweep ---");
        @(posedge clk); select <= 4'd0; auto_mode <= 1'b1;
        @(posedge clk); start_pulse <= 1'b1; @(posedge clk); start_pulse <= 1'b0;
        begin
            int unsigned guard = 0;
            @(posedge clk);
            while (guard < 60_000_000) begin
                @(posedge clk); guard++;
                if (!running && pass_bitmap === 8'hFF) break;
            end
        end
        check("the sweep set every bit of the pass bitmap", pass_bitmap === 8'hFF);
        check("the sweep ended on scenario 7", cur_scenario === 4'd7);
        auto_mode <= 1'b0;

        // --- Phase 8: controls -------------------------------------------
        $display("\n--- Phase 8: controls ---");
        // select is masked to the 8 scenarios that exist, so SW[3] is a
        // don't-care rather than a way to run an empty phase table.
        run_scenario(4'd12, fin);       // 12 & 7 = 4
        check("select 12 is masked to scenario 4", cur_scenario === 4'd4);

        // seq_reset must return the machine to idle from anywhere.
        @(posedge clk); select <= 4'd7; auto_mode <= 1'b0;
        @(posedge clk); start_pulse <= 1'b1; @(posedge clk); start_pulse <= 1'b0;
        wait (running === 1'b1);
        repeat (50) @(posedge clk);
        seq_reset <= 1'b1; repeat (4) @(posedge clk); seq_reset <= 1'b0;
        repeat (4) @(posedge clk);
        check("seq_reset returned the sequencer to idle mid-run", running === 1'b0);

        // --- Phase 9: the watchdog ----------------------------------------
        // Hold waitrequest so no command is ever accepted. `running` must not
        // stick: the watchdog has to fail the scenario and return to idle.
        $display("\n--- Phase 9: watchdog ---");
        begin
            int unsigned guard = 0;
            bit escaped = 0;
            @(posedge clk); select <= 4'd3; auto_mode <= 1'b0;
            @(posedge clk); start_pulse <= 1'b1; @(posedge clk); start_pulse <= 1'b0;
            wait (running === 1'b1);
            force avm_waitrequest = 1'b1;
            while (guard < 400_000) begin
                @(posedge clk); guard++;
                if (!running) begin escaped = 1; break; end
            end
            release avm_waitrequest;
            check("the watchdog returned a stalled scenario to idle", escaped);
            check("the watchdog reported a timeout", err_code === 3'd2);
            check("the watchdog failed the scenario rather than passing it",
                  result_pass === 1'b0);
        end

        // ------------------------------------------------------------------
        // The two bound checkers have been watching throughout. Reporting
        // their counts here is not decoration: a checker whose result nobody
        // reads is a checker that cannot fail, and this demonstration would
        // otherwise print ALL TESTS PASSED over a command stream that violated
        // every timing parameter on the part.
        $display("\n=============================================================");
        $display("  checks passed          : %0d", checks_passed);
        $display("  checks failed          : %0d", checks_failed);
        $display("  timing violations      : %0d", u_tchk.errs);
        $display("  illegal device accesses: %0d", u_mem.bad_access);
        if (checks_failed == 0 && u_tchk.errs == 0 && u_mem.bad_access == 0)
             $display("  *** ALL TESTS PASSED ***");
        else $display("  *** THERE ARE FAILURES ***");
        $display("=============================================================\n");
        $finish;
    end

    // Global safety net so a hang shows up as a failure, not a stuck run.
    initial begin
        #200ms;
        $display("\n  *** TESTBENCH TIMEOUT ***\n");
        $finish;
    end

endmodule
