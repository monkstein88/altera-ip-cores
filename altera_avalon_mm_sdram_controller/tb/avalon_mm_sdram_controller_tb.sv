`timescale 1ns/1ps
// =============================================================================
// avalon_mm_sdram_controller_tb.sv
//
// Self-checking testbench for avalon_mm_sdram_controller.
//
// WHAT MAKES THIS DIFFERENT FROM THE BENCHMARK
// --------------------------------------------
// benchmark/ measures throughput and checks that data survives a round trip.
// It is deliberately blind to *how* the controller got the answer: a design
// that closed and reopened a row before every single access would score badly
// but still pass every integrity check.
//
// This testbench watches the command bus and asserts on the commands
// themselves. "Four banks, one row each, sixteen accesses" is not just
// expected to return the right data - it is expected to cost exactly four
// ACTIVATEs and zero PRECHARGEs. That is the difference between testing the
// output and testing the design, and it is the only way a per-bank controller
// can be distinguished from a correct-but-ordinary one.
//
// Three checkers run alongside:
//   sdram_device_model.sv   - a device with one open row per bank; refuses a
//                             column command to a closed bank
//   sdram_timing_check.sv   - JEDEC timing, with its own threshold self-test
//   *_sva.sv                - Avalon protocol, command legality, and the
//                             controller's row bookkeeping against the wire
//
// A test that passes here and fails on hardware should be a surprise. A test
// that passes here while the controller is quietly doing something stupid
// should not be possible.
// =============================================================================

module avalon_mm_sdram_controller_tb #(
    // Overridable from the command line (-G) so the regression can sweep
    // configurations. Everything else is fixed to the DE10-Lite part.
    parameter int CAS_LAT    = 3,
    parameter int FIFO_DEPTH = 8,
    parameter int LOOKAHEAD  = 1,
    parameter int ADDR_MAP   = 0
);

    // ---------------- configuration ----------------
    // The DE10-Lite geometry, so what is tested is what ships. T_INIT_US is
    // cut to 2 us: the power-up wait is a counter, it is exercised by
    // t_initialisation below, and 100 us of NOPs in every other test is
    // simulation time spent proving nothing.
    localparam int  CLK_KHZ   = 100_000;
    localparam real CLK_NS    = 1_000_000.0 / real'(CLK_KHZ);
    localparam int  DATA_BITS = 16;
    localparam int  ROW_BITS  = 13;
    localparam int  COL_BITS  = 10;
    localparam int  BANK_BITS = 2;
    localparam int  SA_BITS   = 13;
    localparam int  ADDR_W    = ROW_BITS + COL_BITS + BANK_BITS;   // 25
    localparam int  BANKS     = 1 << BANK_BITS;

    logic clk = 0, reset_n = 0;
    always #(CLK_NS/2.0) clk = ~clk;

    // ---------------- Avalon-MM slave ----------------
    logic [ADDR_W-1:0]      az_addr;
    logic [DATA_BITS/8-1:0] az_be_n;
    logic                   az_cs, az_rd_n, az_wr_n;
    logic [DATA_BITS-1:0]   az_data;
    logic [DATA_BITS-1:0]   za_data;
    logic                   za_valid, za_waitrequest;

    // ---------------- SDRAM ----------------
    logic [SA_BITS-1:0]     zs_addr;
    logic [BANK_BITS-1:0]   zs_ba;
    logic                   zs_cas_n, zs_cke, zs_cs_n, zs_ras_n, zs_we_n;
    logic [DATA_BITS/8-1:0] zs_dqm;
    wire  [DATA_BITS-1:0]   zs_dq;

    avalon_mm_sdram_controller #(
        .DATA_BITS(DATA_BITS), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
        .BANK_BITS(BANK_BITS), .SA_BITS(SA_BITS), .CAS_LAT(CAS_LAT),
        .FIFO_DEPTH(FIFO_DEPTH), .CLK_KHZ(CLK_KHZ), .T_INIT_US(2),
        .LOOKAHEAD(LOOKAHEAD), .ADDR_MAP(ADDR_MAP)
    ) dut (
        .clk(clk), .reset_n(reset_n),
        .az_addr(az_addr), .az_be_n(az_be_n), .az_cs(az_cs), .az_data(az_data),
        .az_rd_n(az_rd_n), .az_wr_n(az_wr_n),
        .za_data(za_data), .za_valid(za_valid), .za_waitrequest(za_waitrequest),
        .zs_addr(zs_addr), .zs_ba(zs_ba), .zs_cas_n(zs_cas_n), .zs_cke(zs_cke),
        .zs_cs_n(zs_cs_n), .zs_dq(zs_dq), .zs_dqm(zs_dqm),
        .zs_ras_n(zs_ras_n), .zs_we_n(zs_we_n));

    sdram_device_model #(
        .DATA_BITS(DATA_BITS), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
        .BANK_BITS(BANK_BITS), .SA_BITS(SA_BITS)
    ) mem (
        .clk(clk),
        .zs_addr(zs_addr), .zs_ba(zs_ba), .zs_cas_n(zs_cas_n), .zs_cke(zs_cke),
        .zs_cs_n(zs_cs_n), .zs_dq(zs_dq), .zs_dqm(zs_dqm),
        .zs_ras_n(zs_ras_n), .zs_we_n(zs_we_n));

    sdram_timing_check #(.CLK_KHZ(CLK_KHZ)) tchk (
        .clk(clk), .reset_n(reset_n), .cke(zs_cke), .cs_n(zs_cs_n),
        .ras_n(zs_ras_n), .cas_n(zs_cas_n), .we_n(zs_we_n),
        .ba(zs_ba), .addr(zs_addr));

`ifndef ICARUS
    bind avalon_mm_sdram_controller avalon_mm_sdram_controller_sva #(
        .DATA_BITS(DATA_BITS), .ROW_BITS(ROW_BITS), .BANK_BITS(BANK_BITS),
        .SA_BITS(SA_BITS), .ADDR_W(ADDR_W), .CAS_LAT(CAS_LAT),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) sva_i (
        .clk(clk), .reset_n(reset_n),
        .az_addr(az_addr), .az_cs(az_cs), .az_rd_n(az_rd_n), .az_wr_n(az_wr_n),
        .za_valid(za_valid), .za_waitrequest(za_waitrequest),
        .zs_addr(zs_addr), .zs_ba(zs_ba), .zs_cas_n(zs_cas_n), .zs_cke(zs_cke),
        .zs_cs_n(zs_cs_n), .zs_ras_n(zs_ras_n), .zs_we_n(zs_we_n),
        .dq_oe(dq_oe), .ref_pend(ref_pend), .init_done(init_done),
        .row_open(row_open), .open_row(open_row));
`endif

    // =====================================================================
    // Command monitor - what the controller actually did
    // =====================================================================
    int n_act, n_pre, n_pre_all, n_rd, n_wr, n_ref, n_mrs;
    logic m_sel, m_act, m_rd, m_wr, m_pre, m_ref, m_mrs;
    assign m_sel = zs_cke && !zs_cs_n;
    assign m_act = m_sel && !zs_ras_n &&  zs_cas_n &&  zs_we_n;
    assign m_rd  = m_sel &&  zs_ras_n && !zs_cas_n &&  zs_we_n;
    assign m_wr  = m_sel &&  zs_ras_n && !zs_cas_n && !zs_we_n;
    assign m_pre = m_sel && !zs_ras_n &&  zs_cas_n && !zs_we_n;
    assign m_ref = m_sel && !zs_ras_n && !zs_cas_n &&  zs_we_n;
    assign m_mrs = m_sel && !zs_ras_n && !zs_cas_n && !zs_we_n;

    logic [SA_BITS-1:0] mrs_addr;
    logic [BANK_BITS-1:0] mrs_ba;

    always_ff @(posedge clk) if (reset_n) begin
        if (m_mrs) begin mrs_addr <= zs_addr; mrs_ba <= zs_ba; end
        if (m_act) n_act++;
        if (m_pre) begin n_pre++; if (zs_addr[10]) n_pre_all++; end
        if (m_rd)  n_rd++;
        if (m_wr)  n_wr++;
        if (m_ref) n_ref++;
        if (m_mrs) n_mrs++;
    end

    task automatic zero_counts;
        begin n_act = 0; n_pre = 0; n_pre_all = 0;
              n_rd = 0; n_wr = 0; n_ref = 0; n_mrs = 0; end
    endtask

    // ---- read-data collector ----------------------------------------------
    logic [DATA_BITS-1:0] rd_q [$];
    always_ff @(posedge clk)
        if (reset_n && za_valid) rd_q.push_back(za_data);

    // =====================================================================
    // Scoreboard
    // =====================================================================
    int pass_n = 0, fail_n = 0;
    string cur_test;

    // Announce each test, so a failure inside the SVA (which reports a time,
    // not a test name) can be placed immediately.
    task automatic start_test(input string name);
        begin
            cur_test = name;
            $display("  [%8t] %s", $time, name);
        end
    endtask

    task automatic chk(input bit cond, input string what);
        begin
            if (cond) begin
                pass_n++;
            end else begin
                fail_n++;
                $display("  FAIL  [%s] %s", cur_test, what);
            end
        end
    endtask

    task automatic chk_eq(input int got, input int want, input string what);
        begin
            chk(got == want, $sformatf("%s: got %0d, expected %0d",
                                       what, got, want));
        end
    endtask

    // =====================================================================
    // Avalon-MM master
    //
    // TIMING DISCIPLINE: every task both starts and ends at (clock edge +
    // 0.1 ns), and drives with blocking assignments at that point. So stimulus
    // is never changed at the instant the DUT samples it, and waitrequest is
    // always read just before the edge it gates.
    //
    // The obvious alternative - non-blocking drives, sampled straight after
    // @(posedge clk) - looks right and is not, because it silently depends on
    // HOW the task was entered. Resuming from `wait (...)` lands mid-timestep,
    // after the non-blocking update region has already run, and the drive is
    // then a cycle late. That cost a whole write: the transfer was reported as
    // accepted by the testbench and never appeared on the bus at all.
    // =====================================================================
    // One clock, ending at edge + 0.1 ns. Every wait in this testbench goes
    // through here so the phase invariant cannot be broken by accident.
    task automatic tick;
        begin @(posedge clk); #0.1; end
    endtask

    task automatic settle(input int n = 24);
        begin repeat (n) tick(); end
    endtask

    // A command-count test is a claim about row commands, and a refresh
    // precharges every bank - so a refresh landing inside the measured window
    // makes the count describe the refresh instead of the scheduler. Waiting
    // for one to happen solves both halves at once: every bank is left closed,
    // which is a known starting state, and a full refresh interval (782 cycles
    // at 100 MHz) is then clear before the next one can intrude.
    task automatic quiesce;
        int r0;
        begin
            r0 = n_ref;
            while (n_ref == r0) tick();     // idle until a refresh is issued
            settle(12);                     // and let tRFC elapse
        end
    endtask

    task automatic avm_idle;
        begin az_cs = 1'b0; az_rd_n = 1'b1; az_wr_n = 1'b1; end
    endtask

    // Presents a command and returns once it has been accepted, leaving the
    // bus idle and the phase intact.
    task automatic avm_cmd(input logic [ADDR_W-1:0] a,
                           input logic [DATA_BITS-1:0] d,
                           input logic [DATA_BITS/8-1:0] ben,
                           input bit is_read);
        bit accepted;
        begin
            az_addr = a; az_data = d; az_be_n = ben;
            az_cs   = 1'b1;
            az_rd_n = ~is_read ? 1'b1 : 1'b0;
            az_wr_n =  is_read ? 1'b1 : 1'b0;
            accepted = 1'b0;
            while (!accepted) begin
                #(CLK_NS - 0.2);        // just before the edge that samples us
                accepted = !za_waitrequest;
                #0.2;                   // now just after it
            end
            avm_idle();
        end
    endtask

    task automatic avm_write(input logic [ADDR_W-1:0] a,
                             input logic [DATA_BITS-1:0] d,
                             input logic [DATA_BITS/8-1:0] ben = '0);
        begin avm_cmd(a, d, ben, 1'b0); end
    endtask

    // Issues a read; the data arrives later and is collected into rd_q.
    task automatic avm_read_issue(input logic [ADDR_W-1:0] a);
        begin avm_cmd(a, '0, '0, 1'b1); end
    endtask

    // Issue one read and wait for its data.
    task automatic avm_read(input logic [ADDR_W-1:0] a,
                            output logic [DATA_BITS-1:0] d);
        begin
            rd_q.delete();
            avm_read_issue(a);
            while (rd_q.size() == 0) tick();
            d = rd_q.pop_front();
        end
    endtask

    // ---- address construction, ADDR_MAP 0: {ba[1], row, ba[0], col} -------
    // Mirrors the DUT's map. The command-count expectations below are claims
    // about banks and rows, so an address builder that disagreed with the
    // controller would make every one of them meaningless.
    function automatic logic [ADDR_W-1:0] mk_addr(input int bank,
                                                  input int row,
                                                  input int col);
        logic [ADDR_W-1:0] a;
        a = '0;
        a[COL_BITS-1:0] = COL_BITS'(col);
        if (ADDR_MAP == 0) begin
            a[COL_BITS]               = bank[0];
            a[COL_BITS+1 +: ROW_BITS] = ROW_BITS'(row);
            a[COL_BITS+1+ROW_BITS]    = bank[1];
        end else begin
            a[COL_BITS +: BANK_BITS]            = BANK_BITS'(bank);
            a[COL_BITS+BANK_BITS +: ROW_BITS]   = ROW_BITS'(row);
        end
        return a;
    endfunction

    // A value that depends on the whole address, so a read from the wrong
    // bank, row or column cannot coincidentally match.
    function automatic logic [DATA_BITS-1:0] pat(input logic [ADDR_W-1:0] a);
        return DATA_BITS'((a[15:0] ^ DATA_BITS'(a >> 9) ^ 16'h5A3C) | 16'h0001);
    endfunction

    // =====================================================================
    // Tests
    // =====================================================================

    // 1. The device must be initialised in the JEDEC order, and the master
    //    must be held off until it is. Accepting a command early would let a
    //    write reach a part whose mode register has not been written.
    task automatic t_initialisation;
        begin
            start_test("initialisation");
            chk(za_waitrequest, "waitrequest is not held during initialisation");
            // With chipselect low the only thing that can raise waitrequest is
            // initialisation, so this is "ready" observed from the port side.
            while (za_waitrequest) tick();
            chk_eq(n_pre_all, 1, "PRECHARGE ALL commands during init");
            chk(n_ref >= 8, $sformatf("init refreshes: got %0d, expected >= 8", n_ref));
            chk_eq(n_mrs, 1, "LOAD MODE REGISTER commands during init");
            chk_eq(n_rd + n_wr, 0, "column commands before the device is ready");
            // mode register: burst length 1, sequential, CAS as configured
            // Read back off the wire, as the device saw it.
            chk_eq(int'(mrs_addr[2:0]), 0, "mode register burst length field");
            chk_eq(int'(mrs_addr[3]),   0, "mode register burst type field");
            chk_eq(int'(mrs_addr[6:4]), CAS_LAT, "mode register CAS field");
            chk_eq(int'(mrs_addr[9]),   0, "mode register write-burst-mode field");
            chk_eq(int'(mrs_ba),        0, "bank address during LOAD MODE REGISTER");
        end
    endtask

    // 2. The simplest thing a memory must do.
    task automatic t_single_access;
        logic [ADDR_W-1:0] a;
        logic [DATA_BITS-1:0] d;
        begin
            start_test("single write and read back");
            a = mk_addr(0, 5, 17);
            avm_write(a, pat(a));
            settle();
            avm_read(a, d);
            chk(d == pat(a), $sformatf("read %h from %h, expected %h", d, a, pat(a)));
        end
    endtask

    // 3. Byte enables must mask, not be ignored. A controller that drives DQM
    //    low unconditionally passes every full-word test and silently
    //    corrupts every sub-word write a CPU makes.
    task automatic t_byte_enables;
        logic [ADDR_W-1:0] a;
        logic [DATA_BITS-1:0] d;
        begin
            start_test("byte enables");
            a = mk_addr(1, 9, 3);
            avm_write(a, 16'hFFFF);              // both bytes
            settle();
            avm_write(a, 16'h1234, 2'b10);       // upper byte masked off
            settle();
            avm_read(a, d);
            chk(d == 16'hFF34,
                $sformatf("masked write gave %h, expected FF34", d));
            avm_write(a, 16'hABCD, 2'b01);       // lower byte masked off
            settle();
            avm_read(a, d);
            chk(d == 16'hAB34,
                $sformatf("masked write gave %h, expected AB34", d));
        end
    endtask

    // 4. THE FEATURE. Reads and writes alternating inside one open row must
    //    cost no row commands at all after the row is opened. This is exactly
    //    what the core being replaced could not do.
    task automatic t_turnaround_in_row;
        logic [ADDR_W-1:0] a;
        int i;
        begin
            start_test("read/write turnaround inside one row");
            quiesce();
            // open the row and leave it open
            a = mk_addr(2, 40, 0);
            avm_write(a, pat(a));
            settle();
            zero_counts();
            for (i = 0; i < 8; i++) begin
                a = mk_addr(2, 40, i);
                avm_write(a, pat(a));
                avm_read_issue(a);
            end
            settle(64);
            chk_eq(n_ref, 0, "refreshes inside the measured window");
            chk_eq(n_act, 0, "ACTIVATEs while staying in one open row");
            chk_eq(n_pre, 0, "PRECHARGEs while staying in one open row");
            chk_eq(n_wr, 8, "WRITE commands issued");
            chk_eq(n_rd, 8, "READ commands issued");
            chk_eq(rd_q.size(), 8, "read data words returned");
            for (i = 0; i < 8; i++) begin
                a = mk_addr(2, 40, i);
                chk(rd_q[i] == pat(a),
                    $sformatf("word %0d read %h, expected %h", i, rd_q[i], pat(a)));
            end
            rd_q.delete();
        end
    endtask

    // 5. THE OTHER FEATURE. Four banks, one row each: four ACTIVATEs total,
    //    and never a PRECHARGE. A single-open-row controller needs a full row
    //    cycle for every access here.
    task automatic t_four_banks_one_row;
        logic [ADDR_W-1:0] a;
        int i, b;
        begin
            start_test("four banks, one row each");
            quiesce();                      // every bank closed, interval clear
            zero_counts();
            for (i = 0; i < 16; i++) begin
                b = i % BANKS;
                a = mk_addr(b, 100 + b, i / BANKS);
                avm_write(a, pat(a));
            end
            settle(64);
            chk_eq(n_ref, 0,     "refreshes inside the measured window");
            chk_eq(n_act, BANKS, "ACTIVATEs for a four-bank same-row walk");
            chk_eq(n_pre, 0,     "PRECHARGEs for a four-bank same-row walk");
            chk_eq(n_wr, 16,     "WRITE commands issued");

            zero_counts();
            rd_q.delete();
            for (i = 0; i < 16; i++) begin
                b = i % BANKS;
                avm_read_issue(mk_addr(b, 100 + b, i / BANKS));
            end
            settle(96);
            chk_eq(n_act, 0, "ACTIVATEs on re-reading rows already open");
            chk_eq(n_pre, 0, "PRECHARGEs on re-reading rows already open");
            chk_eq(rd_q.size(), 16, "read data words returned");
            for (i = 0; i < 16; i++) begin
                b = i % BANKS;
                a = mk_addr(b, 100 + b, i / BANKS);
                chk(rd_q[i] == pat(a),
                    $sformatf("bank %0d word %0d read %h, expected %h",
                              b, i, rd_q[i], pat(a)));
            end
            rd_q.delete();
        end
    endtask

    // 6. Changing row within a bank is the case that DOES need row commands.
    //    One precharge, one activate, in that order, and the data must be
    //    right on both sides of it.
    task automatic t_row_change;
        logic [ADDR_W-1:0] a0, a1;
        logic [DATA_BITS-1:0] d;
        begin
            start_test("row change within a bank");
            quiesce();
            a0 = mk_addr(3, 200, 1);
            a1 = mk_addr(3, 201, 1);          // same bank, next row
            avm_write(a0, pat(a0));
            settle();
            zero_counts();
            avm_write(a1, pat(a1));
            settle(64);
            chk_eq(n_ref, 0, "refreshes inside the measured window");
            chk_eq(n_pre, 1, "PRECHARGEs for a row change");
            chk_eq(n_act, 1, "ACTIVATEs for a row change");
            avm_read(a0, d);
            chk(d == pat(a0), $sformatf("old row read %h, expected %h", d, pat(a0)));
            avm_read(a1, d);
            chk(d == pat(a1), $sformatf("new row read %h, expected %h", d, pat(a1)));
        end
    endtask

    // 7. Full-rate streaming, with the master never deasserting. Exercises the
    //    command buffer to full and the waitrequest path out of it.
    task automatic t_streaming_backpressure;
        int i;
        logic [ADDR_W-1:0] a;
        begin
            start_test("streaming with backpressure");
            settle();
            zero_counts();
            for (i = 0; i < 64; i++) begin
                a = mk_addr(0, 300, i);
                avm_write(a, pat(a));
            end
            settle(64);
            chk_eq(n_wr, 64, "WRITE commands for 64 streamed writes");
            rd_q.delete();
            for (i = 0; i < 64; i++) avm_read_issue(mk_addr(0, 300, i));
            settle(128);
            chk_eq(rd_q.size(), 64, "read data words returned");
            for (i = 0; i < 64; i++) begin
                a = mk_addr(0, 300, i);
                chk(rd_q[i] == pat(a),
                    $sformatf("streamed word %0d read %h, expected %h",
                              i, rd_q[i], pat(a)));
            end
            rd_q.delete();
        end
    endtask

    // 8. Read data must come back in the order the reads were issued, even
    //    when they cross banks and rows. Out-of-order return would corrupt
    //    every master that does not tag its transfers - which, on Avalon-MM,
    //    is all of them.
    task automatic t_read_ordering;
        int i;
        logic [ADDR_W-1:0] a [16];
        begin
            start_test("read ordering across banks and rows");
            for (i = 0; i < 16; i++) begin
                a[i] = mk_addr(i % BANKS, 400 + (i * 7), i * 3);
                avm_write(a[i], pat(a[i]));
            end
            settle(64);
            rd_q.delete();
            for (i = 0; i < 16; i++) avm_read_issue(a[i]);
            settle(256);
            chk_eq(rd_q.size(), 16, "read data words returned");
            for (i = 0; i < 16; i++)
                chk(rd_q[i] == pat(a[i]),
                    $sformatf("out-of-order at %0d: read %h, expected %h",
                              i, rd_q[i], pat(a[i])));
            rd_q.delete();
        end
    endtask

    // 9. Refresh must keep happening, and must not be starved by traffic.
    //    A controller that only refreshes when idle loses data under load,
    //    months later, on a warm board.
    task automatic t_refresh_under_load;
        int i, refs;
        begin
            start_test("refresh postponement and catch-up");
            settle();
            zero_counts();
            // Under continuous traffic the controller deliberately postpones,
            // so a short burst legitimately contains NO refreshes - the first
            // version of this test asserted the opposite and was simply wrong
            // about the design. What must hold is that postponement is bounded:
            // once REF_MAX_PEND have piled up, refresh is forced through even
            // though the bus is still busy. tREFI is 782 cycles at 100 MHz, so
            // 8 of them is about 6300 cycles of solid traffic.
            for (i = 0; i < 9000; i++) avm_write(mk_addr(i % BANKS, 500, i % 512),
                                                 16'hA5A5);
            refs = n_ref;
            chk(refs >= 1, $sformatf("forced refreshes during 9000 loaded accesses: got %0d, expected >= 1", refs));

            // And once the bus goes quiet the backlog is spent rather than
            // carried indefinitely.
            zero_counts();
            settle(400);
            chk(n_ref >= 1, $sformatf("refreshes issued after the load stopped: got %0d, expected >= 1", n_ref));

            // Idle refresh rate: over a long quiet period the controller must
            // keep up with tREFI, which is what actually preserves the data.
            zero_counts();
            settle(4000);
            chk(n_ref >= 4, $sformatf("refreshes over 4000 idle cycles: got %0d, expected >= 4 (tREFI = 782)", n_ref));
            // The JEDEC allowance itself is asserted continuously by the SVA
            // (a_ref_pend_bounded), which can see the counter; from out here
            // only the consequence is observable.
        end
    endtask

    // 10. Reset must return the controller to the beginning, not to a state
    //     that thinks rows are still open.
    task automatic t_reset_recovery;
        logic [ADDR_W-1:0] a;
        logic [DATA_BITS-1:0] d;
        begin
            start_test("reset recovery");
            a = mk_addr(1, 600, 7);
            avm_write(a, pat(a));
            settle();
            reset_n = 1'b0;
            avm_idle();
            settle(4);
            reset_n = 1'b1;
            zero_counts();
            rd_q.delete();
            while (za_waitrequest) tick();
            chk_eq(n_pre_all, 1, "PRECHARGE ALL after reset");
            chk_eq(n_mrs, 1, "LOAD MODE REGISTER after reset");
            // memory contents survive a controller reset; the array is not
            // touched by initialisation
            avm_read(a, d);
            chk(d == pat(a),
                $sformatf("after reset read %h from %h, expected %h", d, a, pat(a)));
        end
    endtask

    // =====================================================================
    initial begin
        avm_idle();
        az_addr = '0; az_data = '0; az_be_n = '0;
        @(posedge clk); #0.1;            // establish the phase invariant
        settle(8);
        reset_n = 1'b1;

        $display("");
        $display("=========================================================================");
        $display(" avalon_mm_sdram_controller testbench   %0d MHz   %0d-bit   CAS %0d",
                 CLK_KHZ/1000, DATA_BITS, CAS_LAT);
        $display(" FIFO_DEPTH=%0d  LOOKAHEAD=%0d  ADDR_MAP=%0d",
                 FIFO_DEPTH, LOOKAHEAD, ADDR_MAP);
        $display("=========================================================================");

        t_initialisation();
        settle();
        t_single_access();
        t_byte_enables();
        t_turnaround_in_row();
        t_four_banks_one_row();
        t_row_change();
        t_streaming_backpressure();
        t_read_ordering();
        t_refresh_under_load();
        t_reset_recovery();

        settle(32);
        $display("-------------------------------------------------------------------------");
        $display("  %0d checks passed, %0d failed", pass_n, fail_n);
        $display("  timing violations: %0d      illegal device accesses: %0d",
                 tchk.errs, mem.bad_access);
        $display("=========================================================================");
        $display("");

        if (fail_n != 0 || tchk.errs != 0 || mem.bad_access != 0) begin
            $display(" *** TESTBENCH FAILED ***");
            $fatal(1);
        end
        $display(" all tests passed");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("watchdog: testbench did not finish");
        $fatal(1);
    end

endmodule
