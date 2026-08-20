`timescale 1ns/1ps

// =============================================================================
// avl_mm_firewall_tb.sv
//
// Self-checking testbench for avl_mm_firewall_top. Runs under Questa (with the
// SVA bind and coverage), Verilator (--timing --assert) and Icarus (-g2012,
// -DICARUS to skip the bind).
//
// The bench is parameterised on USE_WRITE_RESPONSE and the run scripts execute
// it BOTH WAYS, because the write-completion rule differs between them: with
// write responses off a write is done when its last beat is accepted, with
// them on it is done when the peripheral says so. Those are different timeout
// scopes and different recovery paths, and testing only the default would
// leave half of the write channel unexercised.
//
// -----------------------------------------------------------------------------
// TIMING DISCIPLINE - read before editing the BFM tasks.
// -----------------------------------------------------------------------------
// Two rules, both learned the hard way.
//
// RULE 1: drive one delta AFTER an edge, never at it. Everything goes through
// `tick`, which is `@(posedge clk); #1;`. Driving DUT inputs with blocking
// assignments AT the edge puts the bench and the DUT's own always blocks in
// the same active region, and which one wins is scheduler-dependent. The
// AXI4-Lite sibling of this core learned that one: its pre-v1.2 bench passed
// under Questa and Icarus, and deadlocked on the first control write under
// the third simulator. Switching the drives to `<=` does not help either -
// non-blocking assignments inside initial blocks get downgraded to blocking.
//
// RULE 2: NEVER read a combinational DUT output in the same timestep in which
// you drove its input. This is the Avalon-specific one, and it is subtle
// enough to be worth spelling out.
//
// s0_waitrequest is combinational from s0_read/s0_write - the Avalon spec
// permits it and this core relies on it for its zero-latency pass-through. So
// the obvious BFM looks like:
//
//     s0_write = 1'b1;                 // drive
//     while (s0_waitrequest) tick;     // wait to be accepted   <-- WRONG
//     tick;
//
// The netlist is not re-evaluated after a blocking assignment; it settles at
// scheduled evaluation points only. So that read of
// s0_waitrequest returns the value computed while s0_write was still 0 - which
// is 0, because an idle slave does not stall. The loop falls straight through,
// the following `tick` crosses an edge at which the port was actually
// stalling, and the beat is silently lost.
//
// The symptom was one beat missing from every burst, but ONLY once the
// downstream model started inserting wait states - with a zero-wait-state
// slave the first beat is accepted anyway and the bug hides completely. The
// visible failure was a write burst that never finished, which left the core
// expecting beats forever and stalled every subsequent read on the port.
//
// The fix is to sample handshakes through REGISTERED flags (wr_hs / rd_hs
// below). Those are updated by a clocked block, which sees properly settled
// combinational values, and reading a register after a time advance is always
// safe. The BFM therefore never asks "is the port ready?" - it asks "was my
// beat taken at the edge I just crossed?", which is the same question a real
// master's state machine asks.
//
// -----------------------------------------------------------------------------
// CONVERSION HAZARD, inherited note
// -----------------------------------------------------------------------------
// `wire x = expr;` is a continuous assignment; `logic x = expr;` is a variable
// declaration with an initialiser, evaluated once at time 0 and never again. A
// blind wire->logic sweep silently freezes such signals at their power-on
// value. Write `logic x; assign x = expr;`.
// =============================================================================

module avl_mm_firewall_tb #(
    parameter int USE_WRITE_RESPONSE = 0
);

    localparam int ADDR_WIDTH        = 32;
    localparam int DATA_WIDTH        = 32;
    localparam int BURST_WIDTH       = 8;     // max 128 beats
    localparam int MAX_PENDING_READS = 4;
    localparam int NUM_RULES         = 8;
    localparam int TIMEOUT_WIDTH     = 20;
    localparam int CSR_ADDR_WIDTH    = 8;

    localparam int BYTES      = DATA_WIDTH/8;
    localparam int BEAT_SHIFT = $clog2(BYTES);

    // ---- CSR word offsets (byte offset / 4) ----
    localparam int W_CTRL       = 'h0;
    localparam int W_STATUS     = 'h1;
    localparam int W_IRQ_ENABLE = 'h2;
    localparam int W_TIMEOUT    = 'h3;
    localparam int W_FAULT_ADDR = 'h4;
    localparam int W_FAULT_INFO = 'h5;
    localparam int W_CORE_INFO  = 'h6;
    localparam int W_RECOVERY   = 'h7;
    localparam int W_RULE_BASE  = 'h10;

    // ---- STATUS bits ----
    localparam int ST_ADDR    = 0, ST_PERM  = 1, ST_TMO   = 2, ST_BURST = 3;
    localparam int ST_ISOL    = 4, ST_BLOCK = 5, ST_WRBSY = 6, ST_RDBSY = 7;
    localparam int ST_WRSTUCK = 8, ST_RDSTUCK = 9;

    // ---- RULE_PERM bits ----
    localparam int P_RD = 1, P_WR = 2, P_VALID = 4, P_BURST = 8;

    // ---- Avalon responses ----
    localparam logic [1:0] R_OKAY = 2'b00, R_SLVERR = 2'b10, R_DECERR = 2'b11;

    // ---- fault type codes (fw_code_e) ----
    localparam int F_ADDR = 1, F_PERM = 2, F_TMO = 3, F_RANGE = 4, F_BDENY = 5;

    // ---- test address map, programmed into the rule table below ----
    localparam logic [31:0] A_RW      = 32'h0000_1000;  // rule 0: R/W, bursts OK
    localparam logic [31:0] A_RO      = 32'h0000_2000;  // rule 1: read-only
    localparam logic [31:0] A_NOBURST = 32'h0000_3000;  // rule 2: R/W, no bursts
    localparam logic [31:0] A_TINY    = 32'h0000_4000;  // rule 3: 16 bytes = 4 beats
    localparam logic [31:0] A_WO      = 32'h0000_6000;  // rule 4: write-only
    localparam logic [31:0] A_UNMAP   = 32'h0000_9000;  // in no rule at all

    // ==================================================================
    // Clock, reset, bookkeeping
    // ==================================================================
    logic clk = 0;
    logic reset_n = 0;
    always #5 clk = ~clk;

    int pass_count = 0;
    int fail_count = 0;
    int cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    task automatic tick; @(posedge clk); #1; endtask
    task automatic ticks(input int n); for (int i = 0; i < n; i++) tick; endtask

    task automatic check(input logic cond, input string what);
        if (cond) begin pass_count++; $display("  PASS: %s", what); end
        else      begin fail_count++; $display("  FAIL: %s", what); end
    endtask

    task automatic check_eq(input logic [63:0] got, input logic [63:0] exp,
                            input string what);
        if (got === exp) begin
            pass_count++; $display("  PASS: %s (0x%0h)", what, got);
        end else begin
            fail_count++;
            $display("  FAIL: %s - got 0x%0h expected 0x%0h", what, got, exp);
        end
    endtask

    // ==================================================================
    // DUT ports
    // ==================================================================
    logic [ADDR_WIDTH-1:0]  s0_address    = '0;
    logic                   s0_read       = 1'b0;
    logic                   s0_write      = 1'b0;
    logic [DATA_WIDTH-1:0]  s0_writedata  = '0;
    logic [BYTES-1:0]       s0_byteenable = '1;
    logic [BURST_WIDTH-1:0] s0_burstcount = 8'd1;
    logic                   s0_waitrequest;
    logic [DATA_WIDTH-1:0]  s0_readdata;
    logic                   s0_readdatavalid;
    logic [1:0]             s0_response;
    logic                   s0_writeresponsevalid;

    logic [ADDR_WIDTH-1:0]  m0_address;
    logic                   m0_read;
    logic                   m0_write;
    logic [DATA_WIDTH-1:0]  m0_writedata;
    logic [BYTES-1:0]       m0_byteenable;
    logic [BURST_WIDTH-1:0] m0_burstcount;
    logic                   m0_waitrequest;
    logic [DATA_WIDTH-1:0]  m0_readdata           = '0;
    logic                   m0_readdatavalid      = 1'b0;
    // No initialiser: this one is continuously assigned below, and `logic x =
    // expr;` is a declaration with an initialiser rather than a continuous
    // assignment. See the header note.
    logic [1:0]             m0_response;
    logic                   m0_writeresponsevalid = 1'b0;

    logic [CSR_ADDR_WIDTH-1:0] csr_address    = '0;
    logic                      csr_read       = 1'b0;
    logic                      csr_write      = 1'b0;
    logic [31:0]               csr_writedata  = '0;
    logic [3:0]                csr_byteenable = 4'hF;
    logic [31:0]               csr_readdata;

    logic irq;

    avl_mm_firewall_top #(
        .ADDR_WIDTH        (ADDR_WIDTH),
        .DATA_WIDTH        (DATA_WIDTH),
        .BURST_WIDTH       (BURST_WIDTH),
        .MAX_PENDING_READS (MAX_PENDING_READS),
        .NUM_RULES         (NUM_RULES),
        .TIMEOUT_WIDTH     (TIMEOUT_WIDTH),
        .CSR_ADDR_WIDTH    (CSR_ADDR_WIDTH),
        .USE_WRITE_RESPONSE(USE_WRITE_RESPONSE)
    ) dut (
        .clk(clk), .reset_n(reset_n),

        .s0_address(s0_address), .s0_read(s0_read), .s0_write(s0_write),
        .s0_writedata(s0_writedata), .s0_byteenable(s0_byteenable),
        .s0_burstcount(s0_burstcount), .s0_waitrequest(s0_waitrequest),
        .s0_readdata(s0_readdata), .s0_readdatavalid(s0_readdatavalid),
        .s0_response(s0_response), .s0_writeresponsevalid(s0_writeresponsevalid),

        .m0_address(m0_address), .m0_read(m0_read), .m0_write(m0_write),
        .m0_writedata(m0_writedata), .m0_byteenable(m0_byteenable),
        .m0_burstcount(m0_burstcount), .m0_waitrequest(m0_waitrequest),
        .m0_readdata(m0_readdata), .m0_readdatavalid(m0_readdatavalid),
        .m0_response(m0_response), .m0_writeresponsevalid(m0_writeresponsevalid),

        .csr_address(csr_address), .csr_read(csr_read), .csr_write(csr_write),
        .csr_writedata(csr_writedata), .csr_byteenable(csr_byteenable),
        .csr_readdata(csr_readdata),

        .irq(irq)
    );

`ifndef ICARUS
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
        .wr_allow(wr_allow), .rd_allow(rd_allow)
    );
`endif

    // ==================================================================
    // DOWNSTREAM SLAVE MODEL
    //
    // A well-behaved bursting Avalon-MM slave with three failure modes. The
    // modes matter as much as the good path: a firewall is mostly untested
    // until the thing behind it misbehaves.
    //
    //   SM_NORMAL    accepts and answers everything
    //   SM_HANG_WAIT waitrequest stuck high - the command is never accepted.
    //                Exercises the *_CMD_STUCK path, where the core is left
    //                holding a command it may not withdraw.
    //   SM_HANG_DATA commands accepted normally, then silence. Exercises the
    //                accepted-then-wedged path, which is the more realistic
    //                failure and a completely different branch: here the
    //                peripheral genuinely owes a response.
    // ==================================================================
    localparam int SM_NORMAL = 0, SM_HANG_WAIT = 1, SM_HANG_DATA = 2;

    localparam int MEMW = 8192;
    localparam int RQD  = 64;     // slave's own read-command queue depth

    int   slave_mode    = SM_NORMAL;
    int   slave_ws      = 0;      // wait states inserted per beat
    int   slave_rd_lat  = 1;      // cycles from command accept to first beat
    logic slave_rst_n   = 1'b1;   // the peripheral reset the integrator owns

    logic [DATA_WIDTH-1:0] mem [MEMW];

    function automatic int midx(input logic [ADDR_WIDTH-1:0] a);
        return int'((a >> BEAT_SHIFT) % MEMW);
    endfunction

    // ---- wait-state generator ----
    //
    // A FREE-RUNNING phase, deliberately independent of m0_read/m0_write.
    //
    // The obvious model - count down while a command is presented, open when
    // the count hits zero - makes waitrequest combinational from a counter
    // that is itself updated by the command in the same cycle. That is a
    // simulator-ordering trap, not a design: whether the DUT samples
    // waitrequest before or after that counter's update decides whether the
    // beat is taken, and it cost a full debugging round here. The first
    // version of this bench dropped exactly one beat per burst, which showed
    // up as a write burst that never finished and therefore a port that
    // stalled every subsequent read.
    //
    // (Do not start a comment line with the word "Verilator" either - the
    // lexer reads a comment whose first word is the tool name as a pragma and
    // rejects the sentence that follows. That one cost a build too.)
    //
    // sm_stall is registered, so it is stable across the edge at which the
    // handshake is sampled and every simulator has to agree about it.
    int   ws_phase = 0;
    logic sm_stall = 1'b0;

    always_ff @(posedge clk) begin
        if (slave_ws == 0)             ws_phase <= 0;
        else if (ws_phase >= slave_ws) ws_phase <= 0;
        else                           ws_phase <= ws_phase + 1;
        // stall unless the phase we are about to enter is the open one
        sm_stall <= (slave_ws != 0) && (ws_phase < slave_ws);
    end

    // ---- read command queue ----
    logic [ADDR_WIDTH-1:0] rq_addr [RQD];
    logic [BURST_WIDTH:0]  rq_cnt  [RQD];
    int rq_head = 0, rq_tail = 0, rq_num = 0;
    int rd_lat  = 0;

    // Registered for the same reason as sm_stall - see above.
    logic rq_full = 1'b0;
    always_ff @(posedge clk) rq_full <= (rq_num >= RQD-2);

    always_comb begin
        if (!slave_rst_n)                    m0_waitrequest = 1'b1;
        else if (slave_mode == SM_HANG_WAIT) m0_waitrequest = 1'b1;
        else if (sm_stall)                   m0_waitrequest = 1'b1;
        else if (m0_read && rq_full)         m0_waitrequest = 1'b1;
        else                                 m0_waitrequest = 1'b0;
    end

    // ---- write side ----
    logic [ADDR_WIDTH-1:0] sm_wr_addr = '0;
    logic [BURST_WIDTH:0]  sm_wr_left = '0;
    logic [ADDR_WIDTH-1:0] sm_wr_cur;
    logic                  sm_wr_last;

    assign sm_wr_cur  = (sm_wr_left == 0) ? m0_address : sm_wr_addr;
    assign sm_wr_last = (sm_wr_left == 0) ? (m0_burstcount == 1) : (sm_wr_left == 1);

    always_ff @(posedge clk) begin
        if (!slave_rst_n) begin
            sm_wr_addr            <= '0;
            sm_wr_left            <= '0;
            m0_writeresponsevalid <= 1'b0;
        end else begin
            m0_writeresponsevalid <= 1'b0;
            if (m0_write && !m0_waitrequest) begin
                for (int b = 0; b < BYTES; b++)
                    if (m0_byteenable[b])
                        mem[midx(sm_wr_cur)][b*8 +: 8] <= m0_writedata[b*8 +: 8];

                if (sm_wr_left == 0) sm_wr_left <= {1'b0, m0_burstcount} - 1;
                else                 sm_wr_left <= sm_wr_left - 1;
                sm_wr_addr <= sm_wr_cur + ADDR_WIDTH'(BYTES);

                if (sm_wr_last && slave_mode != SM_HANG_DATA)
                    m0_writeresponsevalid <= 1'b1;
            end
        end
    end

    // ---- read side ----
    always_ff @(posedge clk) begin
        if (!slave_rst_n) begin
            rq_head <= 0; rq_tail <= 0; rq_num <= 0; rd_lat <= 0;
            m0_readdatavalid <= 1'b0;
            m0_readdata      <= '0;
        end else begin
            m0_readdatavalid <= 1'b0;

            if (m0_read && !m0_waitrequest) begin
                rq_addr[rq_tail] <= m0_address;
                rq_cnt[rq_tail]  <= {1'b0, m0_burstcount};
                rq_tail          <= (rq_tail + 1) % RQD;
                rq_num           <= rq_num + 1;
                if (rq_num == 0) rd_lat <= slave_rd_lat;
            end else if (rq_num > 0 && slave_mode != SM_HANG_DATA) begin
                if (rd_lat != 0) begin
                    rd_lat <= rd_lat - 1;
                end else begin
                    m0_readdatavalid <= 1'b1;
                    m0_readdata      <= mem[midx(rq_addr[rq_head])];
                    rq_addr[rq_head] <= rq_addr[rq_head] + ADDR_WIDTH'(BYTES);
                    rq_cnt[rq_head]  <= rq_cnt[rq_head] - 1;
                    if (rq_cnt[rq_head] == 1) begin
                        rq_head <= (rq_head + 1) % RQD;
                        rq_num  <= rq_num - 1;
                        rd_lat  <= slave_rd_lat;
                    end
                end
            end
        end
    end

    assign m0_response = R_OKAY;

    task automatic slave_reset_pulse;
        slave_rst_n = 1'b0;
        ticks(20);                       // >= 16 clocks, the usual advice
        slave_rst_n = 1'b1;
        ticks(2);
    endtask

    // ==================================================================
    // UPSTREAM RESPONSE COLLECTOR
    //
    // Read data is captured by a monitor rather than inline in the read task,
    // because pipelined reads mean beats for burst N+1 can be arriving while
    // the bench is still deciding what to do about burst N.
    // ==================================================================
    logic [DATA_WIDTH-1:0] rd_data_q [$];
    logic [1:0]            rd_resp_q [$];
    int                    wresp_count = 0;
    logic [1:0]            wresp_last  = 2'b00;

    always @(posedge clk) begin
        if (reset_n) begin
            if (s0_readdatavalid) begin
                rd_data_q.push_back(s0_readdata);
                rd_resp_q.push_back(s0_response);
            end
            if (s0_writeresponsevalid) begin
                wresp_count++;
                wresp_last <= s0_response;
            end
        end
    end

    task automatic clear_collector;
        rd_data_q.delete();
        rd_resp_q.delete();
        wresp_count = 0;
    endtask

    // Wait for n beats, bounded. An unbounded wait here would turn "the core
    // failed to complete a denied burst" - the single most important failure
    // this bench can detect - into a hung run with no diagnosis.
    task automatic await_beats(input int n, input string what);
        int guard;
        guard = 0;
        while (rd_data_q.size() < n && guard < 5000) begin tick; guard++; end
        if (rd_data_q.size() < n) begin
            fail_count++;
            $display("  FAIL: %s - only %0d of %0d beats returned (MASTER WOULD HANG)",
                     what, rd_data_q.size(), n);
            // Dump the state that explains WHICH way it hung. "Beats missing"
            // has several very different causes - a command that never went
            // out, one that went out and was never answered, a drain that
            // stalled - and they are indistinguishable from the count alone.
            $display("        dut: fwd=%0d deny=%0d wr_left=%0d blocked=%b wr_stuck=%b rd_stuck=%b isol=%b",
                     dut.rd_fwd_beats, dut.rd_deny_beats, dut.wr_beats_left,
                     dut.downstream_broken, dut.wr_stuck, dut.rd_stuck,
                     dut.isolate_effective);
            $display("        bus: s0_wait=%b m0_rd=%b m0_wr=%b m0_wait=%b m0_rdv=%b slaveq=%0d mode=%0d",
                     s0_waitrequest, m0_read, m0_write, m0_waitrequest,
                     m0_readdatavalid, rq_num, slave_mode);
        end else begin
            pass_count++;
            $display("  PASS: %s (%0d beats)", what, n);
        end
    endtask

    // ==================================================================
    // m0 PROTOCOL CHECKER
    //
    // Runs regardless of the SVA bind, so the Icarus flow is covered too.
    // Counts every command dropped without waitrequest having fallen, outside
    // the one cycle where RECOVERY.UNBLOCK authorises it.
    // ==================================================================
    int   proto_viol = 0;
    logic m0_read_q = 0, m0_write_q = 0, m0_wait_q = 0, unblock_q = 0;

    always @(posedge clk) begin
        if (reset_n) begin
            if (m0_read_q && m0_wait_q && !m0_read && !unblock_q) begin
                proto_viol++;
                $display("  PROTOCOL VIOLATION @%0t: m0_read dropped unacknowledged", $time);
            end
            if (m0_write_q && m0_wait_q && !m0_write && !unblock_q) begin
                proto_viol++;
                $display("  PROTOCOL VIOLATION @%0t: m0_write dropped unacknowledged", $time);
            end
            if (m0_read && m0_write) begin
                proto_viol++;
                $display("  PROTOCOL VIOLATION @%0t: m0_read and m0_write together", $time);
            end
        end
        m0_read_q  <= m0_read;
        m0_write_q <= m0_write;
        m0_wait_q  <= m0_waitrequest;
        unblock_q  <= dut.unblock;
    end

    // A watcher that fails the run if m0 is touched at all during a window in
    // which the core has promised not to touch it.
    logic watch_m0 = 0;
    int   watch_hits = 0;
    always @(posedge clk)
        if (watch_m0 && (m0_read || m0_write) && !dut.wr_stuck && !dut.rd_stuck)
            watch_hits++;

    // ==================================================================
    // BFM
    // ==================================================================
    task automatic csr_wr(input int waddr, input logic [31:0] data);
        tick;
        csr_address    = CSR_ADDR_WIDTH'(waddr);
        csr_writedata  = data;
        csr_byteenable = 4'hF;
        csr_write      = 1'b1;
        tick;                            // committed at this edge
        csr_write      = 1'b0;
    endtask

    task automatic csr_rd(input int waddr, output logic [31:0] data);
        tick;
        csr_address = CSR_ADDR_WIDTH'(waddr);
        csr_read    = 1'b1;
        tick;                            // readLatency 1: data valid now
        csr_read    = 1'b0;
        data        = csr_readdata;
    endtask

    task automatic set_rule(input int idx, input logic [31:0] base,
                            input logic [31:0] limit, input logic [31:0] perm);
        csr_wr(W_RULE_BASE + idx*4 + 0, base);
        csr_wr(W_RULE_BASE + idx*4 + 1, limit);
        csr_wr(W_RULE_BASE + idx*4 + 2, perm);
    endtask

    // Avalon-MM write burst. Address and burstcount are presented with the
    // first beat; subsequent beats carry writedata only, which is exactly why
    // the core must latch its verdict rather than re-evaluate per beat.
    // Registered handshake flags - see RULE 2 in the header. After a `tick`,
    // wr_hs/rd_hs say whether the beat or command presented across the edge
    // just crossed was actually taken.
    logic wr_hs = 1'b0, rd_hs = 1'b0;
    int   wr_beats_seen = 0;

    always @(posedge clk) begin
        wr_hs <= reset_n && s0_write && !s0_waitrequest;
        rd_hs <= reset_n && s0_read  && !s0_waitrequest;
        if (reset_n && s0_write && !s0_waitrequest) wr_beats_seen <= wr_beats_seen + 1;
    end

    task automatic s0_wr(input logic [31:0] addr, input int n, input logic [31:0] seed);
        int beats_at_start, beats;
        beats_at_start = wr_beats_seen;
        tick;
        s0_address    = addr;
        s0_burstcount = BURST_WIDTH'(n);
        s0_byteenable = '1;
        s0_write      = 1'b1;
        s0_writedata  = seed;
        beats = 0;
        while (beats < n) begin
            tick;                        // cross an edge, then ask if it took
            if (wr_hs) begin
                beats++;
                s0_writedata = seed + beats;
            end
        end
        s0_write = 1'b0;

        // A burst that ends with the core still expecting beats leaves the
        // port permanently busy: every later read is held off by wr_active and
        // the master hangs. That is a silent, cascading failure, so it is
        // checked at the source rather than diagnosed twenty tests later.
        if (dut.wr_beats_left != 0 || (wr_beats_seen - beats_at_start) != n) begin
            fail_count++;
            $display("  FAIL: write burst to 0x%0h: drove %0d beats, port accepted %0d, core still expects %0d",
                     addr, n, wr_beats_seen - beats_at_start, dut.wr_beats_left);
        end
    endtask

    // Issue a read command and return as soon as it has been accepted. Beats
    // are collected by the monitor, so several of these can be in flight.
    task automatic s0_rd_issue(input logic [31:0] addr, input int n);
        tick;
        s0_address    = addr;
        s0_burstcount = BURST_WIDTH'(n);
        s0_read       = 1'b1;
        do tick; while (!rd_hs);         // cross edges until it is taken
        s0_read = 1'b0;
    endtask

    task automatic s0_rd(input logic [31:0] addr, input int n, input string what);
        clear_collector();
        s0_rd_issue(addr, n);
        await_beats(n, what);
    endtask

    task automatic expect_resp(input int n, input logic [1:0] want, input string what);
        int bad;
        bad = 0;
        for (int i = 0; i < n && i < rd_resp_q.size(); i++)
            if (rd_resp_q[i] !== want) bad++;
        check(bad == 0, $sformatf("%s (all %0d beats respond %b)", what, n, want));
    endtask

    task automatic expect_data(input int n, input logic [31:0] first, input string what);
        int bad;
        bad = 0;
        for (int i = 0; i < n && i < rd_data_q.size(); i++)
            if (rd_data_q[i] !== (first + i)) bad++;
        check(bad == 0, $sformatf("%s (%0d beats, data integrity)", what, n));
    endtask

    task automatic expect_zeros(input int n, input string what);
        int bad;
        bad = 0;
        for (int i = 0; i < n && i < rd_data_q.size(); i++)
            if (rd_data_q[i] !== '0) bad++;
        check(bad == 0, $sformatf("%s (denied beats read as zero, not stale data)", what));
    endtask

    task automatic ack_all_faults;
        csr_wr(W_STATUS, 32'h0000_000F);
    endtask

    // The documented recovery sequence, exactly as the driver performs it.
    //
    // Note the ordering: RECOVERY.UNBLOCK is written while the peripheral is
    // still HELD in reset, not after releasing it. UNBLOCK is what withdraws a
    // frozen m0 command, and a peripheral already out of reset can complete
    // that command's handshake before the write lands - latching a transaction
    // the core has already reported to the master as failed. Withdrawing it
    // while the peripheral cannot see the bus closes that window entirely.
    task automatic recover;
        logic [31:0] st;
        int spins;
        ack_all_faults();                        // step 2
        for (spins = 0; spins < 200; spins++) begin   // step 3, bounded
            csr_rd(W_STATUS, st);
            if (!(st[ST_WRBSY] || st[ST_RDBSY])) break;
        end
        slave_rst_n = 1'b0;                      // step 4 - NOT optional
        ticks(20);                               //          >= 16 clocks
        csr_wr(W_RECOVERY, 32'h1);               // step 5, while still in reset
        ticks(2);
        slave_rst_n = 1'b1;                      // step 6
        ticks(2);
    endtask

    // ==================================================================
    // TESTS
    // ==================================================================
    logic [31:0] d, st, info;
    int          t0, t1;

    initial begin
        $display("\n=========================================================");
        $display(" Avalon-MM Firewall regression  (USE_WRITE_RESPONSE=%0d)", USE_WRITE_RESPONSE);
        $display("=========================================================");

        for (int i = 0; i < MEMW; i++) mem[i] = '0;

        reset_n = 1'b0;
        ticks(5);
        reset_n = 1'b1;
        ticks(2);

        // ---------------------------------------------------------------
        $display("\n--- A. Reset state and CORE_INFO ---");
        csr_rd(W_CTRL, d);
        // CTRL reads {MANUAL_ISOLATE, AUTO_ISOLATE_EN, GLOBAL_ENABLE}. Both
        // GLOBAL_ENABLE and AUTO_ISOLATE_EN reset set: access control on, and
        // a timeout isolates without waiting to be told to.
        check_eq(d, 32'h3, "CTRL resets to GLOBAL_ENABLE|AUTO_ISOLATE (secure by default)");
        check_eq(d[2], 1'b0, "CTRL.MANUAL_ISOLATE resets clear");
        csr_rd(W_STATUS, d);
        check_eq(d, 32'h0, "STATUS clean out of reset");
        csr_rd(W_IRQ_ENABLE, d);
        check_eq(d, 32'hF, "IRQ_ENABLE resets to all four sources enabled");
        csr_rd(W_TIMEOUT, d);
        check_eq(d, (32'h1 << TIMEOUT_WIDTH) - 1, "TIMEOUT resets to all-ones");
        csr_rd(W_CORE_INFO, d);
        check_eq(d[7:0],   NUM_RULES,   "CORE_INFO.NUM_RULES");
        check_eq(d[12:8],  BURST_WIDTH, "CORE_INFO.BURST_WIDTH");
        check_eq(d[15:13], BEAT_SHIFT,  "CORE_INFO.log2(bytes per beat)");
        check_eq(d[31:16], 16'h0100,    "CORE_INFO.VERSION = v1.0");
        check(!irq, "irq low out of reset");

        // ---------------------------------------------------------------
        $display("\n--- B. Default-deny before any rule is programmed ---");
        clear_collector();
        s0_wr(A_RW, 1, 32'hDEAD_0000);
        ticks(2);
        csr_rd(W_STATUS, st);
        check(st[ST_ADDR], "write to an unprogrammed address sets ADDR_VIOLATION");
        check(irq, "irq asserted by the violation");
        ack_all_faults();
        ticks(2);
        csr_rd(W_STATUS, st);
        check_eq(st[3:0], 4'h0, "W1C clears the sticky bits");
        check(!irq, "irq deasserts once acknowledged");

        // ---------------------------------------------------------------
        $display("\n--- C. Programming the rule table ---");
        set_rule(0, A_RW,      A_RW      + 32'hFFF, P_VALID|P_RD|P_WR|P_BURST);
        set_rule(1, A_RO,      A_RO      + 32'hFFF, P_VALID|P_RD|P_BURST);
        set_rule(2, A_NOBURST, A_NOBURST + 32'h0FF, P_VALID|P_RD|P_WR);
        set_rule(3, A_TINY,    A_TINY    + 32'h00F, P_VALID|P_RD|P_WR|P_BURST);
        set_rule(4, A_WO,      A_WO      + 32'hFFF, P_VALID|P_WR|P_BURST);
        csr_wr(W_TIMEOUT, 32'd200);

        csr_rd(W_RULE_BASE + 0*4 + 0, d);
        check_eq(d, A_RW, "RULE_BASE[0] readback");
        csr_rd(W_RULE_BASE + 0*4 + 1, d);
        check_eq(d, A_RW + 32'hFFF, "RULE_LIMIT[0] readback");
        csr_rd(W_RULE_BASE + 2*4 + 2, d);
        check_eq(d, P_VALID|P_RD|P_WR, "RULE_PERM[2] readback (BURST_ALLOW clear)");
        csr_rd(W_TIMEOUT, d);
        check_eq(d, 32'd200, "TIMEOUT_VALUE readback");

        // ---------------------------------------------------------------
        $display("\n--- D. Allowed single write and read ---");
        s0_wr(A_RW, 1, 32'hA5A5_0001);
        ticks(3);
        s0_rd(A_RW, 1, "single read completes");
        expect_data(1, 32'hA5A5_0001, "single write/read round trip");
        expect_resp(1, R_OKAY, "single read responds OKAY");
        csr_rd(W_STATUS, st);
        check_eq(st[3:0], 4'h0, "no faults from legal traffic");

        // ---------------------------------------------------------------
        $display("\n--- E. Allowed 16-beat write burst and read burst ---");
        s0_wr(A_RW + 32'h100, 16, 32'h1000_0000);
        ticks(4);
        s0_rd(A_RW + 32'h100, 16, "16-beat read burst completes");
        expect_data(16, 32'h1000_0000, "16-beat burst round trip");
        expect_resp(16, R_OKAY, "burst beats respond OKAY");

        $display("\n--- E2. Maximum-length burst (128 beats) ---");
        s0_wr(A_RW + 32'h400, 128, 32'h2000_0000);
        ticks(4);
        s0_rd(A_RW + 32'h400, 128, "128-beat read burst completes");
        expect_data(128, 32'h2000_0000, "maximum burst round trip");

        // ---------------------------------------------------------------
        $display("\n--- F. Burst throughput (1 beat/cycle, zero added latency) ---");
        clear_collector();
        t0 = cyc;
        s0_wr(A_RW + 32'h800, 32, 32'h3000_0000);
        t1 = cyc;
        // 32 beats through a zero-wait-state slave. The pass-through has no
        // storage, so anything above ~34 means the core is inserting bubbles.
        check(t1 - t0 <= 36,
              $sformatf("32-beat write burst takes %0d cycles (<=36)", t1 - t0));

        clear_collector();
        t0 = cyc;
        s0_rd_issue(A_RW + 32'h800, 32);
        await_beats(32, "32-beat read burst completes");
        t1 = cyc;
        check(t1 - t0 <= 40,
              $sformatf("32-beat read burst takes %0d cycles (<=40)", t1 - t0));

        // ---------------------------------------------------------------
        $display("\n--- G. Permission denial: write into a read-only window ---");
        clear_collector();
        watch_m0 = 1; watch_hits = 0;
        s0_wr(A_RO, 4, 32'hBAD0_0000);
        ticks(4);
        watch_m0 = 0;
        check(watch_hits == 0, "denied write burst never reaches m0");
        csr_rd(W_STATUS, st);
        check(st[ST_PERM], "STATUS.PERM_VIOLATION set");
        check(!st[ST_ADDR], "ADDR_VIOLATION not set (the address is mapped)");
        csr_rd(W_FAULT_ADDR, d);
        check_eq(d, A_RO, "FAULT_ADDR is the burst start address");
        csr_rd(W_FAULT_INFO, info);
        check_eq(info[0],    1'b1,   "FAULT_INFO.WAS_WRITE set");
        check_eq(info[3:1],  F_PERM, "FAULT_INFO.TYPE = PERM");
        check_eq(info[15:8], 8'd4,   "FAULT_INFO.BURSTCOUNT records the burst length");
        if (USE_WRITE_RESPONSE) begin
            check(wresp_count == 1, "denied write burst still produces one write response");
            check_eq(wresp_last, R_SLVERR, "denied write response is SLAVEERROR");
        end
        ack_all_faults();

        // reading the same window is fine
        s0_wr(A_RW, 1, 32'h0);      // keep traffic legal
        s0_rd(A_RO, 4, "read from the read-only window is allowed");
        expect_resp(4, R_OKAY, "read-only window reads respond OKAY");

        $display("\n--- G2. Permission denial: read from a write-only window ---");
        // The mirror of G. Denying a READ is the harder direction on
        // Avalon-MM: the core cannot simply refuse, it has to synthesise the
        // whole burst's worth of beats itself.
        clear_collector();
        watch_m0 = 1; watch_hits = 0;
        s0_rd_issue(A_WO, 4);
        await_beats(4, "permission-denied read burst still returns all 4 beats");
        watch_m0 = 0;
        check(watch_hits == 0, "denied read burst never reaches m0");
        expect_resp(4, R_SLVERR, "permission-denied read responds SLAVEERROR");
        expect_zeros(4, "permission-denied read");
        csr_rd(W_STATUS, st);
        check(st[ST_PERM], "STATUS.PERM_VIOLATION set by the read");
        csr_rd(W_FAULT_INFO, info);
        check_eq(info[0],   1'b0,   "FAULT_INFO.WAS_WRITE clear for a denied read");
        check_eq(info[3:1], F_PERM, "FAULT_INFO.TYPE = PERM for a denied read");
        ack_all_faults();
        // writing the same window is fine
        s0_wr(A_WO, 4, 32'h3333_0000);
        ticks(3);
        csr_rd(W_STATUS, st);
        check_eq(st[3:0], 4'h0, "write to the write-only window is allowed");

        // ---------------------------------------------------------------
        $display("\n--- H. Unmapped address, read burst ---");
        clear_collector();
        watch_m0 = 1; watch_hits = 0;
        s0_rd_issue(A_UNMAP, 8);
        await_beats(8, "unmapped read burst still returns all 8 beats");
        watch_m0 = 0;
        check(watch_hits == 0, "unmapped read never reaches m0");
        expect_resp(8, R_DECERR, "unmapped read beats respond DECODEERROR");
        expect_zeros(8, "unmapped read");
        csr_rd(W_STATUS, st);
        check(st[ST_ADDR], "STATUS.ADDR_VIOLATION set by the read");
        csr_rd(W_FAULT_INFO, info);
        check_eq(info[0],   1'b0,   "FAULT_INFO.WAS_WRITE clear for a read fault");
        check_eq(info[3:1], F_ADDR, "FAULT_INFO.TYPE = ADDR");
        ack_all_faults();

        // ---------------------------------------------------------------
        $display("\n--- I. Burst straddle: starts inside a window, runs off the end ---");
        // Rule 3 covers 0x4000..0x400F, i.e. 4 beats. A 4-beat burst from
        // 0x4008 ends at 0x4017 - outside. This is the check that a
        // start-address-only firewall fails.
        clear_collector();
        watch_m0 = 1; watch_hits = 0;
        s0_rd_issue(A_TINY + 32'h8, 4);
        await_beats(4, "straddling read burst still returns all 4 beats");
        watch_m0 = 0;
        check(watch_hits == 0, "straddling read burst never reaches m0");
        expect_resp(4, R_DECERR, "straddling burst responds DECODEERROR");
        csr_rd(W_STATUS, st);
        check(st[ST_BURST], "STATUS.BURST_VIOLATION set");
        check(!st[ST_ADDR], "ADDR_VIOLATION not set - the start address did match");
        csr_rd(W_FAULT_INFO, info);
        check_eq(info[3:1], F_RANGE, "FAULT_INFO.TYPE = BURST_RANGE");
        ack_all_faults();

        // ...and a burst that fits exactly is allowed
        s0_wr(A_TINY, 4, 32'h4444_0000);
        ticks(3);
        clear_collector();
        s0_rd_issue(A_TINY, 4);
        await_beats(4, "burst filling the window exactly is allowed");
        expect_resp(4, R_OKAY, "exact-fit burst responds OKAY");
        expect_data(4, 32'h4444_0000, "exact-fit burst");
        csr_rd(W_STATUS, st);
        check_eq(st[3:0], 4'h0, "exact-fit burst raises no fault");

        $display("\n--- I3. Burst straddle on the write side ---");
        clear_collector();
        watch_m0 = 1; watch_hits = 0;
        s0_wr(A_TINY + 32'h8, 4, 32'hDEAD_0000);   // 0x4008..0x4017, window ends 0x400F
        ticks(3);
        watch_m0 = 0;
        check(watch_hits == 0, "straddling write burst never reaches m0");
        csr_rd(W_STATUS, st);
        check(st[ST_BURST], "STATUS.BURST_VIOLATION set by the straddling write");
        csr_rd(W_FAULT_INFO, info);
        check_eq(info[0],   1'b1,    "FAULT_INFO.WAS_WRITE set for the straddling write");
        check_eq(info[3:1], F_RANGE, "FAULT_INFO.TYPE = BURST_RANGE for the write");
        ack_all_faults();
        // and the window's contents are untouched
        clear_collector();
        s0_rd_issue(A_TINY, 4);
        await_beats(4, "window readable after a refused straddling write");
        expect_data(4, 32'h4444_0000, "straddling write wrote nothing");

        $display("\n--- I2. Adjacent windows do not merge ---");
        // Rule 0 ends at 0x1FFF and rule 1 begins at 0x2000, both readable.
        // A burst crossing the boundary is still a range violation.
        clear_collector();
        s0_rd_issue(A_RW + 32'hFF8, 4);      // 0x1FF8..0x2007
        await_beats(4, "burst across two abutting windows still completes");
        expect_resp(4, R_DECERR, "burst across abutting windows is refused");
        ack_all_faults();

        // ---------------------------------------------------------------
        $display("\n--- J. Per-rule burst capability ---");
        // Rule 2 permits reads and writes but not bursts.
        s0_wr(A_NOBURST, 1, 32'h7777_0000);
        ticks(3);
        clear_collector();
        s0_rd_issue(A_NOBURST, 1);
        await_beats(1, "single access to a no-burst window is allowed");
        expect_resp(1, R_OKAY, "single access to a no-burst window");
        csr_rd(W_STATUS, st);
        check_eq(st[3:0], 4'h0, "single access raises no fault");

        clear_collector();
        watch_m0 = 1; watch_hits = 0;
        s0_wr(A_NOBURST, 4, 32'h8888_0000);
        ticks(4);
        watch_m0 = 0;
        check(watch_hits == 0, "burst into a no-burst window never reaches m0");
        csr_rd(W_STATUS, st);
        check(st[ST_BURST], "STATUS.BURST_VIOLATION set by the refused burst");
        csr_rd(W_FAULT_INFO, info);
        check_eq(info[3:1], F_BDENY, "FAULT_INFO.TYPE = BURST_DENIED");
        ack_all_faults();

        // and the window's data survived - the refused burst wrote nothing
        clear_collector();
        s0_rd_issue(A_NOBURST, 1);
        await_beats(1, "no-burst window still readable after a refused burst");
        expect_data(1, 32'h7777_0000, "refused burst wrote nothing");

        // ---------------------------------------------------------------
        $display("\n--- K. Pipelined reads return in order ---");
        s0_wr(A_RW + 32'h000, 4, 32'hAAAA_0000);
        s0_wr(A_RW + 32'h010, 4, 32'hBBBB_0000);
        s0_wr(A_RW + 32'h020, 4, 32'hCCCC_0000);
        ticks(4);
        clear_collector();
        s0_rd_issue(A_RW + 32'h000, 4);
        s0_rd_issue(A_RW + 32'h010, 4);
        s0_rd_issue(A_RW + 32'h020, 4);
        await_beats(12, "three pipelined read bursts all complete");
        check(rd_data_q[0]  === 32'hAAAA_0000 &&
              rd_data_q[4]  === 32'hBBBB_0000 &&
              rd_data_q[8]  === 32'hCCCC_0000,
              "pipelined read bursts return in issue order");

        // ---------------------------------------------------------------
        $display("\n--- L. Wait states on the downstream peripheral ---");
        slave_ws = 2;
        s0_wr(A_RW + 32'h030, 8, 32'hEEEE_0000);
        ticks(4);
        clear_collector();
        s0_rd_issue(A_RW + 32'h030, 8);
        await_beats(8, "burst through a slave with wait states completes");
        expect_data(8, 32'hEEEE_0000, "wait-stated burst");
        slave_ws = 0;

        // ---------------------------------------------------------------
        $display("\n--- M. Read timeout, command never accepted (waitrequest stuck) ---");
        clear_collector();
        slave_mode = SM_HANG_WAIT;
        s0_rd_issue(A_RW, 8);
        await_beats(8, "read against a wedged peripheral still returns all 8 beats");
        expect_resp(8, R_SLVERR, "timed-out read beats respond SLAVEERROR");
        expect_zeros(8, "timed-out read");
        csr_rd(W_STATUS, st);
        check(st[ST_TMO],     "STATUS.TIMEOUT_ERROR set");
        check(st[ST_BLOCK],   "STATUS.BLOCKED set");
        check(st[ST_ISOL],    "STATUS.ISOLATED set (auto-isolate)");
        check(st[ST_RDSTUCK], "STATUS.RD_CMD_STUCK set - a command was never accepted");
        csr_rd(W_FAULT_INFO, info);
        check_eq(info[3:1], F_TMO, "FAULT_INFO.TYPE = TIMEOUT");
        check_eq(info[0],   1'b0,  "FAULT_INFO.WAS_WRITE clear for a read timeout");
        check(proto_viol == 0, "no m0 protocol violation from the timeout");

        $display("\n--- N. Traffic while blocked is refused, not stalled ---");
        clear_collector();
        s0_rd_issue(A_RW, 4);
        await_beats(4, "read while blocked is answered, not stalled");
        expect_resp(4, R_SLVERR, "blocked read responds SLAVEERROR");
        s0_wr(A_RW, 4, 32'h0);           // must not hang
        check(1'b1, "write while blocked is consumed, not stalled");

        $display("\n--- O. W1C alone does not unblock ---");
        ack_all_faults();
        ticks(2);
        csr_rd(W_STATUS, st);
        check_eq(st[3:0],   4'h0, "sticky bits cleared");
        check_eq(st[ST_ISOL], 1'b0, "auto-isolate released");
        check(st[ST_BLOCK], "BLOCKED still set - acknowledging is not recovering");

        $display("\n--- P. Full recovery sequence ---");
        slave_mode = SM_NORMAL;
        // Hold the peripheral in reset and confirm the frozen command is still
        // held - it is UNBLOCK that withdraws it, nothing else.
        slave_rst_n = 1'b0;
        ticks(20);
        csr_rd(W_STATUS, st);
        check(st[ST_RDSTUCK], "frozen command still held while the peripheral is in reset");
        csr_wr(W_RECOVERY, 32'h1);
        ticks(2);
        csr_rd(W_STATUS, st);
        check_eq(st[ST_RDSTUCK], 1'b0, "UNBLOCK withdrew the frozen command");
        slave_rst_n = 1'b1;
        ticks(4);
        csr_rd(W_STATUS, st);
        check_eq(st[ST_BLOCK],   1'b0, "BLOCKED cleared by RECOVERY.UNBLOCK");
        check_eq(st[ST_RDSTUCK], 1'b0, "RD_CMD_STUCK cleared");
        check(proto_viol == 0, "no protocol violation across the recovery");

        clear_collector();
        s0_wr(A_RW + 32'h040, 4, 32'h5150_0000);
        ticks(3);
        s0_rd_issue(A_RW + 32'h040, 4);
        await_beats(4, "traffic works again after recovery");
        expect_data(4, 32'h5150_0000, "post-recovery");
        expect_resp(4, R_OKAY, "post-recovery beats respond OKAY");

        // ---------------------------------------------------------------
        $display("\n--- Q. Read timeout, accepted then silent ---");
        // A different branch entirely: here the peripheral genuinely owes
        // beats, and the core has to convert what is owed into synthesised
        // error beats rather than simply refusing a command.
        clear_collector();
        slave_mode = SM_HANG_DATA;
        s0_rd_issue(A_RW, 8);
        await_beats(8, "accepted-then-silent read still returns all 8 beats");
        expect_resp(8, R_SLVERR, "abandoned read beats respond SLAVEERROR");
        csr_rd(W_STATUS, st);
        check(st[ST_TMO],       "TIMEOUT_ERROR set by the silent peripheral");
        check(!st[ST_RDSTUCK],  "RD_CMD_STUCK clear - the command WAS accepted");
        slave_mode = SM_NORMAL;
        recover();

        // late beats from the abandoned read must be discarded, not handed on
        clear_collector();
        ticks(40);
        check(rd_data_q.size() == 0, "orphan beats after recovery are discarded");

        // ---------------------------------------------------------------
        $display("\n--- R. Write timeout mid-burst ---");
        clear_collector();
        slave_mode = SM_HANG_WAIT;
        s0_wr(A_RW, 16, 32'h9999_0000);   // must return, not hang
        check(1'b1, "write burst against a wedged peripheral is consumed, not stalled");
        ticks(4);
        csr_rd(W_STATUS, st);
        check(st[ST_TMO],     "TIMEOUT_ERROR set by the write timeout");
        check(st[ST_BLOCK],   "BLOCKED set by the write timeout");
        check(st[ST_WRSTUCK], "WR_CMD_STUCK set - the beat was never accepted");
        csr_rd(W_FAULT_INFO, info);
        check_eq(info[0], 1'b1, "FAULT_INFO.WAS_WRITE set for a write timeout");
        if (USE_WRITE_RESPONSE)
            check(wresp_count >= 1, "abandoned write burst still produces a write response");
        check(proto_viol == 0, "no m0 protocol violation from the write timeout");
        slave_mode = SM_NORMAL;
        recover();
        csr_rd(W_STATUS, st);
        check_eq(st[ST_WRSTUCK], 1'b0, "WR_CMD_STUCK cleared by UNBLOCK");

        clear_collector();
        s0_wr(A_RW + 32'h050, 2, 32'h1111_2222);
        ticks(3);
        s0_rd_issue(A_RW + 32'h050, 2);
        await_beats(2, "writes work again after write-timeout recovery");
        expect_data(2, 32'h1111_2222, "post-write-recovery");

        // ---------------------------------------------------------------
        $display("\n--- S. Manual isolation ---");
        csr_wr(W_CTRL, 32'h7);                    // enable | auto | manual isolate
        ticks(2);
        csr_rd(W_STATUS, st);
        check(st[ST_ISOL], "STATUS.ISOLATED reflects MANUAL_ISOLATE");
        clear_collector();
        watch_m0 = 1; watch_hits = 0;
        s0_rd_issue(A_RW, 4);
        await_beats(4, "read while manually isolated is answered");
        watch_m0 = 0;
        check(watch_hits == 0, "manual isolation keeps m0 untouched");
        expect_resp(4, R_SLVERR, "isolated read responds SLAVEERROR");
        csr_rd(W_STATUS, st);
        check_eq(st[3:0], 4'h0, "isolation rejection raises no NEW sticky fault");
        csr_wr(W_CTRL, 32'h3);                    // release
        ticks(2);

        // ---------------------------------------------------------------
        $display("\n--- T. Bypass mode ---");
        csr_wr(W_CTRL, 32'h2);                    // GLOBAL_ENABLE = 0
        ticks(2);
        s0_wr(A_UNMAP, 4, 32'h6666_0000);         // no rule covers this
        ticks(3);
        clear_collector();
        s0_rd_issue(A_UNMAP, 4);
        await_beats(4, "bypass mode forwards an unmapped burst");
        expect_data(4, 32'h6666_0000, "bypass mode");
        csr_rd(W_STATUS, st);
        check_eq(st[3:0], 4'h0, "bypass mode raises no violation");

        $display("\n--- T2. Bypass does NOT override fault isolation ---");
        // Access control and fault isolation are separate jobs. A peripheral
        // that has already wedged the bus stays walled off even with the rule
        // check switched off.
        clear_collector();
        slave_mode = SM_HANG_WAIT;
        s0_rd_issue(A_UNMAP, 4);
        await_beats(4, "bypassed read against a wedged peripheral still completes");
        ticks(4);
        csr_rd(W_STATUS, st);
        check(st[ST_BLOCK], "downstream still BLOCKED in bypass mode");
        clear_collector();
        watch_m0 = 1; watch_hits = 0;
        s0_rd_issue(A_UNMAP, 4);
        await_beats(4, "next bypassed read is refused by the block");
        watch_m0 = 0;
        check(watch_hits == 0, "bypass mode does not reopen a broken downstream");
        slave_mode = SM_NORMAL;
        recover();
        csr_wr(W_CTRL, 32'h3);                    // re-enable access control
        ticks(2);

        // ---------------------------------------------------------------
        $display("\n--- U. Interrupt masking ---");
        csr_wr(W_IRQ_ENABLE, 32'h0);
        ticks(2);
        s0_wr(A_UNMAP, 1, 32'h0);
        ticks(3);
        csr_rd(W_STATUS, st);
        check(st[ST_ADDR], "violation still latched with the interrupt masked");
        check(!irq, "irq stays low when masked");
        csr_wr(W_IRQ_ENABLE, 32'h1);
        ticks(2);
        check(irq, "unmasking an already-latched fault raises irq");
        csr_wr(W_IRQ_ENABLE, 32'hF);
        ack_all_faults();
        ticks(2);
        check(!irq, "irq clears with the fault");

        // ---------------------------------------------------------------
        $display("\n--- V. Rule reprogramming and the retire-first idiom ---");
        // Base/limit/perm are three registers, so a live rule must be retired
        // before it is moved or there is a window where base is new and limit
        // is still old.
        csr_wr(W_RULE_BASE + 0*4 + 2, 32'h0);             // retire rule 0
        csr_wr(W_RULE_BASE + 0*4 + 0, 32'h0000_5000);
        csr_wr(W_RULE_BASE + 0*4 + 1, 32'h0000_5FFF);
        csr_wr(W_RULE_BASE + 0*4 + 2, P_VALID|P_RD|P_WR|P_BURST);
        ticks(2);
        clear_collector();
        s0_wr(32'h0000_5000, 4, 32'hFEED_0000);
        ticks(3);
        s0_rd_issue(32'h0000_5000, 4);
        await_beats(4, "traffic to the relocated window works");
        expect_data(4, 32'hFEED_0000, "relocated window");
        clear_collector();
        s0_rd_issue(A_RW, 4);                              // old location
        await_beats(4, "old window location now refused");
        expect_resp(4, R_DECERR, "the vacated address is unmapped again");
        ack_all_faults();
        set_rule(0, A_RW, A_RW + 32'hFFF, P_VALID|P_RD|P_WR|P_BURST);

        // ---------------------------------------------------------------
        $display("\n--- W. Byte enables and partial writes ---");
        s0_wr(A_RW + 32'h060, 1, 32'hFFFF_FFFF);
        ticks(2);
        tick;
        s0_address    = A_RW + 32'h060;
        s0_burstcount = 8'd1;
        s0_byteenable = 4'b0011;
        s0_writedata  = 32'h0000_1234;
        s0_write      = 1'b1;
        do tick; while (!wr_hs);
        s0_write      = 1'b0;
        s0_byteenable = '1;
        ticks(3);
        clear_collector();
        s0_rd_issue(A_RW + 32'h060, 1);
        await_beats(1, "partial write read back");
        expect_data(1, 32'hFFFF_1234, "byteenable merge passes through untouched");

        // ---------------------------------------------------------------
        $display("\n--- X. CSR byte enables ---");
        csr_wr(W_TIMEOUT, 32'h0000_FFFF);
        tick;
        csr_address    = W_TIMEOUT;
        csr_writedata  = 32'h0000_00AB;
        csr_byteenable = 4'b0001;
        csr_write      = 1'b1;
        tick;
        csr_write      = 1'b0;
        csr_byteenable = 4'hF;
        csr_rd(W_TIMEOUT, d);
        check_eq(d[15:0], 16'hFFAB, "CSR byteenable merges one byte only");
        csr_wr(W_TIMEOUT, 32'd200);

        // ---------------------------------------------------------------
        $display("\n--- Y. Unmapped CSR offsets and read-only registers ---");
        csr_wr(W_CORE_INFO, 32'hFFFF_FFFF);
        csr_rd(W_CORE_INFO, d);
        check_eq(d[31:16], 16'h0100, "CORE_INFO is read-only");
        csr_wr(W_FAULT_ADDR, 32'hFFFF_FFFF);
        csr_rd(W_FAULT_ADDR, d);
        check(d !== 32'hFFFF_FFFF, "FAULT_ADDR is read-only");
        csr_rd(W_RECOVERY, d);
        check_eq(d, 32'h0, "RECOVERY reads as zero (write-only, self-clearing)");
        csr_rd('hF, d);
        check_eq(d, 32'h0, "unmapped CSR offset reads zero");
        csr_rd(W_RULE_BASE + 0*4 + 3, d);
        check_eq(d, 32'h0, "reserved word inside a rule slot reads zero");

        // ---------------------------------------------------------------
        $display("\n--- Z. Reset asserted mid-burst ---");
        // Sweeps the reset point across a write burst, which is where the beat
        // counters would otherwise be left mid-count and wedge the port.
        for (int k = 1; k <= 4; k++) begin
            fork
                begin s0_wr(A_RW, 8, 32'hDEAD_BEEF); end
                begin ticks(k); reset_n = 1'b0; ticks(3); reset_n = 1'b1; end
            join_any
            disable fork;
            s0_write = 1'b0;
            s0_read  = 1'b0;
            ticks(4);
            reset_n  = 1'b1;
            ticks(4);
        end
        // The peripheral is now mid-burst: it was part way through receiving a
        // write burst that reset cut off, so its internal beat counter still
        // expects more. The NEXT burst would be absorbed as a continuation of
        // the dead one and land at the wrong address. That is not a bug in the
        // model - it is the same truncated-burst hazard that makes step 4 of
        // the recovery sequence mandatory, reproduced here by a reset rather
        // than by a timeout. Reset the peripheral, exactly as a driver must.
        slave_reset_pulse();

        // reprogram and prove the port still works
        set_rule(0, A_RW, A_RW + 32'hFFF, P_VALID|P_RD|P_WR|P_BURST);
        csr_wr(W_TIMEOUT, 32'd200);
        clear_collector();
        s0_wr(A_RW + 32'h070, 4, 32'hC0DE_0000);
        ticks(3);
        s0_rd_issue(A_RW + 32'h070, 4);
        await_beats(4, "port still works after reset mid-burst");
        expect_data(4, 32'hC0DE_0000, "post-reset traffic");

        // ---------------------------------------------------------------
        $display("\n--- AA. Final protocol audit ---");
        check(proto_viol == 0,
              $sformatf("no m0 protocol violations across the whole run (%0d)", proto_viol));

        // ---------------------------------------------------------------
        ticks(10);
        $display("\n=========================================================");
        $display(" RESULTS: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0 && proto_viol == 0)
            $display(" *** ALL TESTS PASSED ***");
        else
            $display(" *** %0d FAILURES ***", fail_count + proto_viol);
        $display("=========================================================\n");
        if (fail_count != 0 || proto_viol != 0) $fatal(1, "regression failed");
        $finish;
    end

    // Global watchdog. A firewall bug that hangs the master is the failure
    // this bench most needs to report clearly, and a silent timeout under CI
    // reports nothing at all.
    initial begin
        #4_000_000;
        $display("\n*** WATCHDOG: simulation did not finish - the master is hung ***");
        $display(" RESULTS: %0d passed, %0d failed", pass_count, fail_count);
        $fatal(1, "watchdog");
    end

endmodule
