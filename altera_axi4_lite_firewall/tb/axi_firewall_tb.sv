`timescale 1ns/1ps

// =============================================================================
// axi_firewall_tb.sv
//
// Self-checking testbench for axi_firewall_top. Runs under Questa (with the
// SVA bind and coverage), Verilator (--timing --assert), and Icarus Verilog
// with -g2012.
//
// CONVERSION HAZARD - `wire x = expr;` is NOT `logic x = expr;`
// -------------------------------------------------------------
// The first is a continuous assignment; the second is a variable declaration
// with an initialiser, evaluated once at time 0 and never again. A blind
// wire->logic sweep froze `slave_rst` at its time-0 value during the
// SystemVerilog conversion, holding the downstream slave model in reset for
// the whole run - every transaction timed out and 27 checks failed. Use
// `logic x; assign x = expr;`.
//
// TIMING DISCIPLINE - read before editing the BFM tasks.
// ------------------------------------------------------
// Every task samples and drives at `@(posedge clk); #1;` - one delta after the
// edge - and holds each *VALID through the edge at which the handshake is
// actually sampled, dropping it only on the following edge.
//
// This is not cosmetic. The previous revision did:
//
//     while (!(s_axi_awready && s_axi_wready)) @(posedge clk);
//     s_axi_awvalid = 0; s_axi_wvalid = 0;      // blocking, AT the edge
//
// which deasserts VALID with a blocking assignment in the same active region
// in which the DUT's always block samples it. Whether the DUT sees 1 or 0 is
// scheduler-dependent. Questa and Icarus happened to evaluate the DUT first
// and the suite passed; Verilator evaluates the testbench first, the write is
// never committed, and the run deadlocks on the very first ctrl_write.
//
// Note that switching the drives to `<=` does NOT fix this: Verilator
// downgrades non-blocking assignments inside initial blocks to blocking
// (warning INITIALDLY). The `#1` settle is the portable fix.
// =============================================================================

module axi_firewall_tb;

    localparam int ADDR_WIDTH      = 32;
    localparam int DATA_WIDTH      = 32;
    localparam int CTRL_ADDR_WIDTH = 12;
    localparam int NUM_RULES       = 8;
    localparam int TIMEOUT_WIDTH   = 20;

    logic clk = 0;
    logic resetn = 0;
    always #5 clk = ~clk;

    // ---------------- s_axi (drive as the "Nios II side") -----------------
    logic  [ADDR_WIDTH-1:0]   s_axi_awaddr;
    logic  [2:0]              s_axi_awprot = 0;
    logic                     s_axi_awvalid = 0;
    logic                    s_axi_awready;
    logic  [DATA_WIDTH-1:0]   s_axi_wdata;
    logic  [DATA_WIDTH/8-1:0] s_axi_wstrb;
    logic                     s_axi_wvalid = 0;
    logic                    s_axi_wready;
    logic [1:0]              s_axi_bresp;
    logic                    s_axi_bvalid;
    logic                     s_axi_bready = 0;
    logic  [ADDR_WIDTH-1:0]   s_axi_araddr;
    logic  [2:0]              s_axi_arprot = 0;
    logic                     s_axi_arvalid = 0;
    logic                    s_axi_arready;
    logic [DATA_WIDTH-1:0]   s_axi_rdata;
    logic [1:0]              s_axi_rresp;
    logic                    s_axi_rvalid;
    logic                     s_axi_rready = 0;

    // ---------------- m_axi (behavioral downstream slave model) -----------
    logic [ADDR_WIDTH-1:0]   m_axi_awaddr;
    logic [2:0]              m_axi_awprot;
    logic                    m_axi_awvalid;
    logic                     m_axi_awready = 0;
    logic [DATA_WIDTH-1:0]   m_axi_wdata;
    logic [DATA_WIDTH/8-1:0] m_axi_wstrb;
    logic                    m_axi_wvalid;
    logic                     m_axi_wready = 0;
    logic  [1:0]              m_axi_bresp = 0;
    logic                     m_axi_bvalid = 0;
    logic                    m_axi_bready;
    logic [ADDR_WIDTH-1:0]   m_axi_araddr;
    logic [2:0]              m_axi_arprot;
    logic                    m_axi_arvalid;
    logic                     m_axi_arready = 0;
    logic  [DATA_WIDTH-1:0]   m_axi_rdata = 0;
    logic  [1:0]              m_axi_rresp = 0;
    logic                     m_axi_rvalid = 0;
    logic                    m_axi_rready;

    // ---------------- s_axi_ctrl (drive as "management software") ----------
    logic  [CTRL_ADDR_WIDTH-1:0] s_axi_ctrl_awaddr;
    logic  [2:0]                 s_axi_ctrl_awprot = 0;
    logic                        s_axi_ctrl_awvalid = 0;
    logic                       s_axi_ctrl_awready;
    logic  [31:0]                s_axi_ctrl_wdata;
    logic  [3:0]                 s_axi_ctrl_wstrb;
    logic                        s_axi_ctrl_wvalid = 0;
    logic                       s_axi_ctrl_wready;
    logic [1:0]                 s_axi_ctrl_bresp;
    logic                       s_axi_ctrl_bvalid;
    logic                        s_axi_ctrl_bready = 0;
    logic  [CTRL_ADDR_WIDTH-1:0] s_axi_ctrl_araddr;
    logic  [2:0]                 s_axi_ctrl_arprot = 0;
    logic                        s_axi_ctrl_arvalid = 0;
    logic                       s_axi_ctrl_arready;
    logic [31:0]                s_axi_ctrl_rdata;
    logic [1:0]                 s_axi_ctrl_rresp;
    logic                       s_axi_ctrl_rvalid;
    logic                        s_axi_ctrl_rready = 0;

    logic irq;

    // v2.0: the core no longer drives a peripheral reset. The testbench owns
    // one, exactly as a system integrator now must - see periph_rst below.

    int pass_count = 0;
    int fail_count = 0;

    axi_firewall_top #(
        .ADDR_WIDTH      (ADDR_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .CTRL_ADDR_WIDTH (CTRL_ADDR_WIDTH),
        .NUM_RULES       (NUM_RULES),
        .TIMEOUT_WIDTH   (TIMEOUT_WIDTH)
    ) dut (
        .clk (clk), .resetn (resetn),

        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),

        .m_axi_awaddr(m_axi_awaddr), .m_axi_awprot(m_axi_awprot), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arprot(m_axi_arprot), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),

        .s_axi_ctrl_awaddr(s_axi_ctrl_awaddr), .s_axi_ctrl_awprot(s_axi_ctrl_awprot), .s_axi_ctrl_awvalid(s_axi_ctrl_awvalid), .s_axi_ctrl_awready(s_axi_ctrl_awready),
        .s_axi_ctrl_wdata(s_axi_ctrl_wdata), .s_axi_ctrl_wstrb(s_axi_ctrl_wstrb), .s_axi_ctrl_wvalid(s_axi_ctrl_wvalid), .s_axi_ctrl_wready(s_axi_ctrl_wready),
        .s_axi_ctrl_bresp(s_axi_ctrl_bresp), .s_axi_ctrl_bvalid(s_axi_ctrl_bvalid), .s_axi_ctrl_bready(s_axi_ctrl_bready),
        .s_axi_ctrl_araddr(s_axi_ctrl_araddr), .s_axi_ctrl_arprot(s_axi_ctrl_arprot), .s_axi_ctrl_arvalid(s_axi_ctrl_arvalid), .s_axi_ctrl_arready(s_axi_ctrl_arready),
        .s_axi_ctrl_rdata(s_axi_ctrl_rdata), .s_axi_ctrl_rresp(s_axi_ctrl_rresp), .s_axi_ctrl_rvalid(s_axi_ctrl_rvalid), .s_axi_ctrl_rready(s_axi_ctrl_rready),

        .irq(irq)
    );


`ifndef ICARUS
    bind axi_firewall_top axi_firewall_sva #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_axi_firewall_sva (
        .clk(clk),
        .resetn(resetn),

        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),

        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),

        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),

        // internal names, visible because bind port expressions resolve in
        // the scope of the bound-to instance
        .unblock(unblock),
        .blocked(downstream_broken),

        // per-direction pulses, NOT the merged fault_*_violation wires
        .wr_violation(wr_fault_addr_violation | wr_fault_perm_violation),
        .rd_violation(rd_fault_addr_violation | rd_fault_perm_violation)
    );
`endif

    // ------------------------------------------------------------------
    // Behavioral downstream slave: 16 words of memory.
    //
    // hang_mode selects how it misbehaves:
    //   HANG_NONE  - well-behaved, zero wait states
    //   HANG_ADDR  - never raises AWREADY/ARREADY. The firewall times out
    //                with its *VALID still asserted (address-phase timeout).
    //   HANG_RESP  - accepts the address+data normally, then never answers.
    //                This is the response-phase timeout, which HANG_ADDR
    //                cannot reach: it is a different branch of both FSMs and
    //                had zero coverage before tests Q/R existed.
    //
    // `periph_rst` is driven by the testbench, standing in for the system
    // integrator resetting the protected peripheral - which in v2.0 is step 4
    // of the documented recovery sequence rather than something the core
    // does. verification/orphan_response_tb.sv measures what happens when
    // that step is skipped.
    // ------------------------------------------------------------------
    typedef enum logic [1:0] { HANG_NONE, HANG_ADDR, HANG_RESP } hang_mode_e;

    logic [31:0] mem [16];
    hang_mode_e  hang_mode  = HANG_NONE;
    logic        periph_rst = 1'b0;

    // NOTE: must be `logic` + `assign`, never `logic slave_rst = <expr>;`.
    // In Verilog, `wire x = expr;` is a continuous assignment. In
    // SystemVerilog, `logic x = expr;` is a variable declaration with an
    // *initialiser* - evaluated once at time 0 and never again. A blind
    // wire->logic conversion silently froze this at its time-0 value (resetn
    // low => slave permanently held in reset), so every downstream
    // transaction timed out and the whole suite returned SLVERR.
    logic slave_rst;
    assign slave_rst = !resetn || periph_rst;

    always_ff @(posedge clk) begin
        if (slave_rst) begin
            m_axi_awready <= 0; m_axi_wready <= 0; m_axi_bvalid <= 0;
            m_axi_arready <= 0; m_axi_rvalid <= 0;
        end else begin
            // write side
            if (hang_mode != HANG_ADDR) begin
                m_axi_awready <= m_axi_awvalid && !m_axi_awready;
                m_axi_wready  <= m_axi_wvalid  && !m_axi_wready;
            end else begin
                m_axi_awready <= 0;
                m_axi_wready  <= 0;
            end

            if (m_axi_awvalid && m_axi_awready && m_axi_wvalid && m_axi_wready) begin
                mem[m_axi_awaddr[5:2]] <= m_axi_wdata;
                if (hang_mode != HANG_RESP) begin
                    m_axi_bvalid <= 1;
                    m_axi_bresp  <= 2'b00;
                end
            end else if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 0;
            end

            // read side
            if (hang_mode != HANG_ADDR) begin
                m_axi_arready <= m_axi_arvalid && !m_axi_arready;
            end else begin
                m_axi_arready <= 0;
            end

            if (m_axi_arvalid && m_axi_arready) begin
                if (hang_mode != HANG_RESP) begin
                    m_axi_rdata  <= mem[m_axi_araddr[5:2]];
                    m_axi_rresp  <= 2'b00;
                    m_axi_rvalid <= 1;
                end
            end else if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 0;
            end
        end
    end

    // ==================================================================
    // AXI protocol checker on the MASTER (m_axi) side.
    // Rule: once *VALID is asserted it must stay asserted until the
    // matching *READY handshake. The one legitimate exception is the cycle
    // after RECOVERY.UNBLOCK, where software has declared the peripheral
    // reset and its AXI state discarded (v2.0; up to v1.2 the exception was
    // "while the core held the peripheral in reset").
    // ==================================================================
    int m_awvalid_drops = 0, m_wvalid_drops = 0, m_arvalid_drops = 0;
    logic m_awv_q, m_wv_q, m_arv_q, m_awr_q, m_wr_q, m_arr_q, m_unblk_q;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            m_awv_q<=0; m_wv_q<=0; m_arv_q<=0; m_awr_q<=0; m_wr_q<=0; m_arr_q<=0; m_unblk_q<=0;
        end else begin
            if (m_awv_q && !m_axi_awvalid && !m_awr_q && !m_unblk_q) begin
                m_awvalid_drops++;
                $display("  >> AXI VIOLATION t=%0t: m_axi_AWVALID dropped without AWREADY", $time);
            end
            if (m_wv_q && !m_axi_wvalid && !m_wr_q && !m_unblk_q) begin
                m_wvalid_drops++;
                $display("  >> AXI VIOLATION t=%0t: m_axi_WVALID dropped without WREADY", $time);
            end
            if (m_arv_q && !m_axi_arvalid && !m_arr_q && !m_unblk_q) begin
                m_arvalid_drops++;
                $display("  >> AXI VIOLATION t=%0t: m_axi_ARVALID dropped without ARREADY", $time);
            end
            m_awv_q<=m_axi_awvalid; m_awr_q<=m_axi_awready;
            m_wv_q <=m_axi_wvalid;  m_wr_q <=m_axi_wready;
            m_arv_q<=m_axi_arvalid; m_arr_q<=m_axi_arready;
            m_unblk_q<=dut.unblock;   // DUT-internal: the discard window
        end
    end

    // ------------------------------------------------------------------
    // BFM tasks
    // ------------------------------------------------------------------
    // One clock edge, then settle. See the TIMING DISCIPLINE note at the top:
    // every sample and every drive in this testbench happens here, never in
    // the same active region as the DUT's own edge-triggered logic.
    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic wait_cycles(input int n);
        for (int w = 0; w < n; w++) tick;
    endtask

    task automatic data_write(input [ADDR_WIDTH-1:0] addr, input [31:0] data, output [1:0] resp);
        begin
            tick;
            s_axi_awaddr  = addr; s_axi_awvalid = 1;
            s_axi_wdata   = data; s_axi_wstrb = 4'hF; s_axi_wvalid = 1;
            s_axi_bready  = 1;
            while (!(s_axi_awready && s_axi_wready)) tick;
            tick;                                   // hold through the handshake edge
            s_axi_awvalid = 0; s_axi_wvalid = 0;
            while (!s_axi_bvalid) tick;
            resp = s_axi_bresp;
            tick;
            s_axi_bready = 0;
        end
    endtask

    task automatic data_read(input [ADDR_WIDTH-1:0] addr, output [31:0] data, output [1:0] resp);
        begin
            tick;
            s_axi_araddr = addr; s_axi_arvalid = 1;
            s_axi_rready = 1;
            while (!s_axi_arready) tick;
            tick;
            s_axi_arvalid = 0;
            while (!s_axi_rvalid) tick;
            data = s_axi_rdata;
            resp = s_axi_rresp;
            tick;
            s_axi_rready = 0;
        end
    endtask

    task automatic ctrl_write(input [CTRL_ADDR_WIDTH-1:0] addr, input [31:0] data);
        logic [1:0] resp;
        begin
            tick;
            s_axi_ctrl_awaddr = addr; s_axi_ctrl_awvalid = 1;
            s_axi_ctrl_wdata  = data; s_axi_ctrl_wstrb = 4'hF; s_axi_ctrl_wvalid = 1;
            s_axi_ctrl_bready = 1;
            while (!(s_axi_ctrl_awready && s_axi_ctrl_wready)) tick;
            tick;
            s_axi_ctrl_awvalid = 0; s_axi_ctrl_wvalid = 0;
            while (!s_axi_ctrl_bvalid) tick;
            resp = s_axi_ctrl_bresp;
            tick;
            s_axi_ctrl_bready = 0;
        end
    endtask

    task automatic ctrl_read(input [CTRL_ADDR_WIDTH-1:0] addr, output [31:0] data);
        begin
            tick;
            s_axi_ctrl_araddr = addr; s_axi_ctrl_arvalid = 1;
            s_axi_ctrl_rready = 1;
            while (!s_axi_ctrl_arready) tick;
            tick;
            s_axi_ctrl_arvalid = 0;
            while (!s_axi_ctrl_rvalid) tick;
            data = s_axi_ctrl_rdata;
            tick;
            s_axi_ctrl_rready = 0;
        end
    endtask

    // `string` rather than the Verilog-2001 idiom of a 512-bit packed vector
    // holding ASCII. Names print without leading NULs and can be any length.
    task automatic check_eq(input logic [63:0] actual,
                            input logic [63:0] expected,
                            input string       name);
        if (actual === expected) begin
            pass_count++;
            $display("  PASS: %s (got 0x%0h)", name, actual);
        end else begin
            fail_count++;
            $display("  FAIL: %s  expected 0x%0h got 0x%0h", name, expected, actual);
        end
    endtask

    // ==================================================================
    // REGISTER OFFSETS (Moved above tasks so compiler sees them first)
    // ==================================================================
    localparam logic [CTRL_ADDR_WIDTH-1:0]
        OFF_CTRL  = 'h00, OFF_STATUS = 'h04, OFF_IRQEN = 'h08,
        OFF_TMOUT = 'h0C, OFF_FADDR  = 'h10, OFF_FINFO = 'h14,
        OFF_INFO  = 'h18, OFF_RECOV = 'h1C;

    // STATUS bit positions
    localparam int ST_ADDR_VIOL = 0, ST_PERM_VIOL = 1, ST_TIMEOUT = 2,
                   ST_ISOLATED  = 3, ST_BLOCKED   = 4,
                   ST_WR_BUSY   = 5, ST_RD_BUSY   = 6,
                   ST_WR_STUCK  = 7, ST_RD_STUCK  = 8;

    // The v2.0 recovery sequence, as a driver would implement it.
    //
    // The busy poll is BOUNDED, and that is not laziness. A peripheral that
    // accepted a command and then died owes a response that will never
    // arrive, so RESP_BUSY never clears - polling it unconditionally
    // deadlocks exactly when recovery matters most. The bits are advisory:
    // busy clear means no late response can still be in flight, so the reset
    // is unambiguously safe. Busy stuck means you reset anyway and accept
    // that UNBLOCK is what discards the owed response.
    //
    // Step 4 - resetting the peripheral - is the integrator's job in v2.0.
    // Skipping it is the hazard measured in verification/orphan_response_tb.sv.
    task automatic recover_downstream(input bit reset_peripheral = 1);
        logic [31:0] st;
        int          spins;
        begin
            // 1. acknowledge the fault. Clears the sticky bits and releases
            //    the auto-isolate latch - without this the core is still
            //    ISOLATED after the unblock and keeps answering SLVERR.
            ctrl_write(OFF_STATUS, 32'h7);

            // 2. wait for the downstream to go quiet, bounded
            spins = 0;
            ctrl_read(OFF_STATUS, st);
            while ((st[ST_WR_BUSY] || st[ST_RD_BUSY]) && spins < 20) begin
                ctrl_read(OFF_STATUS, st);
                spins++;
            end
            // 3. reset the protected peripheral - the integrator's job
            if (reset_peripheral) begin
                periph_rst = 1'b1;
                wait_cycles(16);          // AMD's PG293 suggests >= 16 clocks
                periph_rst = 1'b0;
                wait_cycles(2);
            end

            // 4. declare the downstream AXI state discarded and reopen
            ctrl_write(OFF_RECOV, 32'h1);
        end
    endtask

    function automatic logic [CTRL_ADDR_WIDTH-1:0] rule_off(input int idx, input int sub);
        return CTRL_ADDR_WIDTH'('h40 + idx*16 + sub);
    endfunction

    // ==================================================================
    // COVERAGE IMPROVEMENT TASKS
    // ==================================================================

    // Task 1: Sweep all register offsets including unmapped ones
    task automatic test_reg_sweep;
        logic [31:0] read_data;
        logic [CTRL_ADDR_WIDTH-1:0] addrs [8];
        begin
            $display("\n--- Coverage Test 1: Register Map Sweep ---");
            addrs[0] = OFF_CTRL;   // 0x00
            addrs[1] = OFF_STATUS; // 0x04
            addrs[2] = OFF_IRQEN;  // 0x08
            addrs[3] = OFF_TMOUT;  // 0x0C
            addrs[4] = OFF_FADDR;  // 0x10
            addrs[5] = OFF_FINFO;  // 0x14
            addrs[6] = OFF_INFO;   // 0x18
            addrs[7] = 12'h01C;    // Unmapped offset (triggers default branch)

            for (int i = 0; i < 8; i++) begin
                ctrl_write(addrs[i], 32'hA5A5_5A5A);
                ctrl_read(addrs[i], read_data);
            end

            // The sweep writes 0xA5A55A5A to CTRL, whose bit 0 is 0 - it
            // leaves the firewall in bypass mode. Put it back, or every test
            // after this one silently runs with access control disabled.
            ctrl_write(OFF_CTRL,  32'b011);   // enable + auto-isolate
            ctrl_write(OFF_TMOUT, 32'd15);    // sweep clobbered the timeout too
            ctrl_write(OFF_IRQEN, 32'h7);
            ctrl_write(OFF_STATUS, 32'h7);
        end
    endtask

    // Task 2: Assert and clear software manual isolation
    task automatic test_manual_isolation;
        logic [31:0] read_data;
        begin
            $display("\n--- Coverage Test 2: Manual Isolation ---");
            // Set Manual Isolate bit (Bit 2) + Enable bit (Bit 0) -> 32'b101 (0x5)
            ctrl_write(OFF_CTRL, 32'b101);
            ctrl_read(OFF_STATUS, read_data);
            check_eq(read_data[3], 1'b1, "Manual Isolate -> STATUS.ISOLATED set");

            // Clear manual isolate -> 32'b001 (0x1)
            ctrl_write(OFF_CTRL, 32'b001);
            ctrl_read(OFF_STATUS, read_data);
            check_eq(read_data[3], 1'b0, "Clear Isolate -> STATUS.ISOLATED cleared");
        end
    endtask

    // Task 3: Disable interrupts and trigger a fault to test masking logic
    task automatic test_irq_masking;
        logic [31:0] read_data;
        logic [1:0] dummy_resp;
        begin
            $display("\n--- Coverage Test 3: IRQ Masking ---");
            // Mask all IRQs
            ctrl_write(OFF_IRQEN, 32'h0000_0000);

            // Cause an address violation on unmapped space
            data_write(32'h0000_9000, 32'h1234_5678, dummy_resp);

            // Verify top-level IRQ line stays LOW while status logs violation
            check_eq(irq, 1'b0, "IRQ Masked -> top irq stays LOW");
            ctrl_read(OFF_STATUS, read_data);
            check_eq(read_data[0], 1'b1, "IRQ Masked -> ADDR_VIOLATION recorded");

            // Re-enable IRQs and clear status
            ctrl_write(OFF_IRQEN, 32'h0000_000F);
            ctrl_write(OFF_STATUS, 32'h1);
        end
    endtask

    // Task 4: Stagger AWVALID and WVALID on control bus
    task automatic ctrl_write_staggered;
        input [CTRL_ADDR_WIDTH-1:0] addr;
        input [31:0] data;
        logic [31:0] read_data;
        begin
            $display("\n--- Coverage Test 4: Staggered AXI-Lite Channels ---");
            tick;
            s_axi_ctrl_awaddr  = addr;
            s_axi_ctrl_awvalid = 1'b1;
            s_axi_ctrl_wvalid  = 1'b0;      // delay write data

            wait_cycles(2);
            s_axi_ctrl_wdata   = data;
            s_axi_ctrl_wstrb   = 4'hF;
            s_axi_ctrl_wvalid  = 1'b1;
            s_axi_ctrl_bready  = 1'b1;

            while (!(s_axi_ctrl_awready && s_axi_ctrl_wready)) tick;
            tick;
            s_axi_ctrl_awvalid = 1'b0;
            s_axi_ctrl_wvalid  = 1'b0;

            while (!s_axi_ctrl_bvalid) tick;
            tick;
            s_axi_ctrl_bready  = 1'b0;

            // It used to check nothing at all, so a staggered write that got
            // dropped would have looked identical to one that landed.
            ctrl_read(addr, read_data);
            check_eq(read_data[TIMEOUT_WIDTH-1:0], data[TIMEOUT_WIDTH-1:0],
                     "staggered AW/W write took effect");
        end
    endtask

    // ==================================================================
    // Control-port backpressure (regression for the v1.2 fix).
    //
    // This port is single-outstanding. Before v1.2 it asserted AWREADY /
    // ARREADY purely on VALID arriving, without checking whether the previous
    // response had been accepted. A master that pipelined a second access
    // while BVALID/RVALID was still unacknowledged got the handshake taken,
    // the access silently dropped, and no response - lost register writes and
    // a wedged channel. Correct behaviour is to withhold READY.
    //
    // Both tasks deliberately hold BREADY/RREADY low across the second
    // request, which no other test in this suite does.
    // ==================================================================
    task automatic test_write_backpressure;
        logic [31:0] read_data;
        begin
            $display("\n--- Coverage Test 5: Control-port write backpressure ---");
            // Post write #1 to RULE3_BASE and leave its B response unacked.
            tick;
            s_axi_ctrl_bready  = 1'b0;
            s_axi_ctrl_awaddr  = rule_off(3,0); s_axi_ctrl_awvalid = 1'b1;
            s_axi_ctrl_wdata   = 32'hAAAA_AAAA; s_axi_ctrl_wstrb = 4'hF;
            s_axi_ctrl_wvalid  = 1'b1;
            while (!(s_axi_ctrl_awready && s_axi_ctrl_wready)) tick;
            tick;
            s_axi_ctrl_awvalid = 1'b0; s_axi_ctrl_wvalid = 1'b0;
            while (!s_axi_ctrl_bvalid) tick;
            check_eq(s_axi_ctrl_bvalid, 1'b1, "backpressure: write #1 BVALID pending");

            // Post write #2 while BVALID is still outstanding. READY must NOT
            // be granted; hold for a bounded window and confirm.
            s_axi_ctrl_awaddr  = rule_off(3,0); s_axi_ctrl_awvalid = 1'b1;
            s_axi_ctrl_wdata   = 32'h1234_5678; s_axi_ctrl_wstrb = 4'hF;
            s_axi_ctrl_wvalid  = 1'b1;
            for (int guard = 0; guard < 8; guard++) begin
                tick;
                if (s_axi_ctrl_awready || s_axi_ctrl_wready) begin
                    fail_count++;
                    $display("  FAIL: backpressure: READY granted while BVALID outstanding");
                end
            end
            check_eq(s_axi_ctrl_awready, 1'b0,
                     "backpressure: AWREADY withheld while BVALID outstanding");

            // Release the first response; write #2 must then complete.
            s_axi_ctrl_bready = 1'b1;
            while (!(s_axi_ctrl_awready && s_axi_ctrl_wready)) tick;
            tick;
            s_axi_ctrl_awvalid = 1'b0; s_axi_ctrl_wvalid = 1'b0;
            while (!s_axi_ctrl_bvalid) tick;
            tick;
            s_axi_ctrl_bready = 1'b0;

            ctrl_read(rule_off(3,0), read_data);
            check_eq(read_data, 32'h1234_5678,
                     "backpressure: write #2 landed once BREADY was granted");
        end
    endtask

    task automatic test_read_backpressure;
        logic [31:0] read_data;
        begin
            $display("\n--- Coverage Test 6: Control-port read backpressure ---");
            // Read #1 (CORE_INFO), leave RVALID unacked.
            tick;
            s_axi_ctrl_rready = 1'b0;
            s_axi_ctrl_araddr = OFF_INFO; s_axi_ctrl_arvalid = 1'b1;
            while (!s_axi_ctrl_arready) tick;
            tick;
            s_axi_ctrl_arvalid = 1'b0;
            while (!s_axi_ctrl_rvalid) tick;
            check_eq(s_axi_ctrl_rvalid, 1'b1, "backpressure: read #1 RVALID pending");

            // Read #2 while RVALID is outstanding: ARREADY must be withheld.
            s_axi_ctrl_araddr = OFF_IRQEN; s_axi_ctrl_arvalid = 1'b1;
            for (int guard = 0; guard < 8; guard++) begin
                tick;
                if (s_axi_ctrl_arready) begin
                    fail_count++;
                    $display("  FAIL: backpressure: ARREADY granted while RVALID outstanding");
                end
            end
            check_eq(s_axi_ctrl_arready, 1'b0,
                     "backpressure: ARREADY withheld while RVALID outstanding");

            // Accept read #1; read #2 must then be answered.
            s_axi_ctrl_rready = 1'b1;
            while (!s_axi_ctrl_arready) tick;
            tick;
            s_axi_ctrl_arvalid = 1'b0;
            while (!s_axi_ctrl_rvalid) tick;
            read_data = s_axi_ctrl_rdata;
            tick;
            s_axi_ctrl_rready = 1'b0;
            check_eq(read_data[2:0], 3'h7,
                     "backpressure: read #2 answered once RREADY was granted");
        end
    endtask

    // ==================================================================
    // Data-path response backpressure (s_axi B and R channels).
    //
    // Questa reported a_bvalid_stability and a_rvalid_stability with 845
    // vacuous attempts and a pass count of ZERO. Their antecedent is
    // (BVALID && !BREADY), and every BFM task above raises BREADY/RREADY
    // together with the request, so a response never once had to wait -
    // two assertions that had verified precisely nothing while looking
    // green. This holds each response channel off for several cycles so
    // they fire, and checks what AXI actually requires meanwhile: VALID
    // stays asserted and the payload stays stable until READY.
    // ==================================================================
    task automatic test_response_backpressure;
        logic [1:0]  held_resp;
        logic [31:0] held_data;
        begin
            $display("\n--- Coverage Test 7: s_axi response backpressure ---");
            hang_mode = HANG_NONE;

            // ---- write: complete the request, then stall BREADY ----
            tick;
            s_axi_awaddr = 32'h0000_1004; s_axi_awvalid = 1;
            s_axi_wdata  = 32'hB0B0_CAFE; s_axi_wstrb = 4'hF; s_axi_wvalid = 1;
            s_axi_bready = 0;
            while (!(s_axi_awready && s_axi_wready)) tick;
            tick;
            s_axi_awvalid = 0; s_axi_wvalid = 0;
            while (!s_axi_bvalid) tick;
            held_resp = s_axi_bresp;

            for (int i = 0; i < 6; i++) begin
                tick;
                if (!s_axi_bvalid) begin
                    fail_count++;
                    $display("  FAIL: BVALID dropped before BREADY");
                end
                if (s_axi_bresp !== held_resp) begin
                    fail_count++;
                    $display("  FAIL: BRESP changed while waiting for BREADY");
                end
            end
            check_eq(s_axi_bvalid, 1'b1, "response backpressure: BVALID held until BREADY");
            check_eq(held_resp,   2'b00, "response backpressure: BRESP is OKAY");

            s_axi_bready = 1; tick; tick;
            s_axi_bready = 0;
            check_eq(s_axi_bvalid, 1'b0, "response backpressure: BVALID cleared after BREADY");

            // ---- read: same on the R channel ----
            tick;
            s_axi_araddr = 32'h0000_1004; s_axi_arvalid = 1;
            s_axi_rready = 0;
            while (!s_axi_arready) tick;
            tick;
            s_axi_arvalid = 0;
            while (!s_axi_rvalid) tick;
            held_data = s_axi_rdata;

            for (int i = 0; i < 6; i++) begin
                tick;
                if (!s_axi_rvalid) begin
                    fail_count++;
                    $display("  FAIL: RVALID dropped before RREADY");
                end
                if (s_axi_rdata !== held_data) begin
                    fail_count++;
                    $display("  FAIL: RDATA changed while waiting for RREADY");
                end
            end
            check_eq(s_axi_rvalid, 1'b1,          "response backpressure: RVALID held until RREADY");
            check_eq(held_data, 32'hB0B0_CAFE,    "response backpressure: RDATA stable and correct");

            s_axi_rready = 1; tick; tick;
            s_axi_rready = 0;
            check_eq(s_axi_rvalid, 1'b0, "response backpressure: RVALID cleared after RREADY");
        end
    endtask

    // ==================================================================
    // Coverage Test 8: UNBLOCK semantics (v2.0).
    //
    // The three things a driver can get wrong, made explicit:
    //   - UNBLOCK on a healthy core must be a no-op, not a disruption
    //   - a stuck VALID is withdrawn by UNBLOCK and by nothing else
    //   - a global reset also clears the block, as a last resort
    // ==================================================================
    task automatic test_unblock_semantics;
        logic [31:0] st;
        logic [1:0]  rsp;
        begin
            $display("\n--- Coverage Test 8: UNBLOCK semantics ---");
            hang_mode = HANG_NONE;

            // harmless when nothing is blocked
            ctrl_write(OFF_RECOV, 32'h1);
            wait_cycles(2);
            data_write(32'h0000_1004, 32'h1234_ABCD, rsp);
            check_eq(rsp, 2'b00, "unblock: no-op when the core is not blocked");

            // provoke an address-phase timeout, then confirm the stuck VALID
            // is held right up until the unblock
            hang_mode = HANG_ADDR;
            data_write(32'h0000_1004, 32'hDEAD_0001, rsp);
            check_eq(rsp, 2'b10, "unblock: timeout gives SLVERR");
            hang_mode = HANG_NONE;

            check_eq(m_axi_awvalid, 1'b1, "unblock: AWVALID still asserted while blocked");
            wait_cycles(20);
            check_eq(m_axi_awvalid, 1'b1,
                     "unblock: AWVALID stays asserted - nothing else drops it");
            ctrl_read(OFF_STATUS, st);
            check_eq(st[ST_WR_STUCK], 1'b1, "unblock: WR_CMD_STUCK reports it");

            recover_downstream();
            check_eq(m_axi_awvalid, 1'b0, "unblock: AWVALID withdrawn by UNBLOCK");
            check_eq(m_axi_wvalid,  1'b0, "unblock: WVALID withdrawn by UNBLOCK");
            ctrl_read(OFF_STATUS, st);
            check_eq(st[ST_BLOCKED],  1'b0, "unblock: BLOCKED cleared");
            check_eq(st[ST_WR_STUCK], 1'b0, "unblock: WR_CMD_STUCK cleared");

            data_write(32'h0000_1004, 32'h600D_0002, rsp);
            check_eq(rsp, 2'b00, "unblock: traffic resumes");
            ctrl_write(OFF_STATUS, 32'h7);
        end
    endtask

    // ==================================================================
    // Reset asserted mid-transaction.
    //
    // Closes the four FSM transitions Questa reported as uncovered:
    // WR_EVAL->WR_IDLE, WR_FWD->WR_IDLE, RD_EVAL->RD_IDLE, RD_FWD->RD_IDLE.
    // Drives the raw signals rather than the BFM tasks, because a task
    // waiting on a response that reset just cancelled would never return.
    // ==================================================================
    // A blocked downstream survives across a global reset? No - global reset
    // clears everything, including downstream_broken. That is the escape
    // hatch of last resort for a peripheral that never recovers.
    task automatic test_reset_mid_transaction(input int delay, input hang_mode_e mode);
        begin
            hang_mode = mode;

            // launch a write and a read together so both FSMs are in flight
            tick;
            s_axi_awaddr  = 32'h0000_1000; s_axi_awvalid = 1;
            s_axi_wdata   = 32'hFEED_FACE; s_axi_wstrb = 4'hF; s_axi_wvalid = 1;
            s_axi_bready  = 1;
            s_axi_araddr  = 32'h0000_1000; s_axi_arvalid = 1;
            s_axi_rready  = 1;

            wait_cycles(delay);

            resetn = 0;
            s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_arvalid = 0;
            s_axi_bready  = 0; s_axi_rready = 0;
            wait_cycles(4);
            resetn = 1;
            wait_cycles(4);

            hang_mode = HANG_NONE;

            // Reset wipes the rule table, so reprogram before checking.
            ctrl_write(OFF_TMOUT, 32'd15);
            ctrl_write(rule_off(0,0), 32'h0000_1000);
            ctrl_write(rule_off(0,4), 32'h0000_1FFF);
            ctrl_write(rule_off(0,8), 32'b111);
        end
    endtask

    // ==================================================================
    // Latency benchmark. The README quotes best-case cycle counts; this is
    // what measures them, against the zero-wait-state slave model.
    // ==================================================================
    task automatic measure_latency;
        int wr_cycles, rd_cycles;
        logic [31:0] ldata;
        begin
            $display("\n--- Latency benchmark (zero-wait-state downstream) ---");
            hang_mode = HANG_NONE;

            // Count clock edges rather than differencing $time: the units
            // $time reports vary between simulators, edge counts do not.
            //
            // The handshake is driven exactly as in data_write/data_read.
            // Holding *VALID asserted past its READY to simplify the counting
            // is not an option: it violates the VALID-stability rule and the
            // SVA bind will (correctly) fail the run.
            tick;
            s_axi_awaddr = 32'h0000_100C; s_axi_awvalid = 1;
            s_axi_wdata  = 32'h0BAD_F00D; s_axi_wstrb = 4'hF; s_axi_wvalid = 1;
            s_axi_bready = 1;
            wr_cycles = 0;
            while (!(s_axi_awready && s_axi_wready)) begin tick; wr_cycles = wr_cycles + 1; end
            tick; wr_cycles = wr_cycles + 1;
            s_axi_awvalid = 0; s_axi_wvalid = 0;
            while (!s_axi_bvalid) begin tick; wr_cycles = wr_cycles + 1; end
            tick; s_axi_bready = 0;
            wait_cycles(2);

            tick;
            s_axi_araddr = 32'h0000_100C; s_axi_arvalid = 1;
            s_axi_rready = 1;
            rd_cycles = 0;
            while (!s_axi_arready) begin tick; rd_cycles = rd_cycles + 1; end
            tick; rd_cycles = rd_cycles + 1;
            s_axi_arvalid = 0;
            while (!s_axi_rvalid) begin tick; rd_cycles = rd_cycles + 1; end
            ldata = s_axi_rdata;
            tick; s_axi_rready = 0;

            $display("  LATENCY: write request -> BVALID = %0d cycles", wr_cycles);
            $display("  LATENCY: read  request -> RVALID = %0d cycles", rd_cycles);
            check_eq(ldata, 32'h0BAD_F00D, "latency benchmark: data integrity");
            // A regression guard, not a golden value - tighten if the design
            // is ever pipelined.
            if (wr_cycles > 8 || rd_cycles > 8) begin
                fail_count++;
                $display("  FAIL: latency regressed beyond 8 cycles");
            end
            wait_cycles(2);
        end
    endtask

    logic [31:0] rdata;
    logic [1:0]  resp;

    initial begin
        resetn = 0;
        wait_cycles(5);
        resetn = 1;
        wait_cycles(2);

        $display("=== axi_firewall self-check ===");

        // Speed up simulation: small timeout window (cycles)
        ctrl_write(OFF_TMOUT, 32'd15);

        // Rule 0: 0x1000-0x1FFF, read+write allowed
        ctrl_write(rule_off(0,0), 32'h0000_1000);
        ctrl_write(rule_off(0,4), 32'h0000_1FFF);
        ctrl_write(rule_off(0,8), 32'b111); // valid|write|read

        // Rule 1: 0x2000-0x2FFF, read-only
        ctrl_write(rule_off(1,0), 32'h0000_2000);
        ctrl_write(rule_off(1,4), 32'h0000_2FFF);
        ctrl_write(rule_off(1,8), 32'b101); // valid|read, no write

        // --- Test A: allowed write inside rule 0 ---
        data_write(32'h0000_1004, 32'hCAFEBABE, resp);
        check_eq(resp, 2'b00, "A: allowed write -> OKAY");

        // --- Test B: allowed read-back inside rule 0 ---
        data_read(32'h0000_1004, rdata, resp);
        check_eq(resp,  2'b00,        "B: allowed read -> OKAY");
        check_eq(rdata, 32'hCAFEBABE, "B: read-back data matches");

        // --- Test C: write to read-only rule 1 -> SLVERR + PERM_VIOLATION ---
        data_write(32'h0000_2004, 32'hDEADBEEF, resp);
        check_eq(resp, 2'b10, "C: write to RO region -> SLVERR");
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[1], 1'b1, "C: STATUS.PERM_VIOLATION set");
        check_eq(irq,      1'b1, "C: irq asserted");
        ctrl_read(OFF_FADDR, rdata);
        check_eq(rdata, 32'h0000_2004, "C: FAULT_ADDR captured");

        // clear it
        ctrl_write(OFF_STATUS, 32'h2);
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[1], 1'b0, "C: STATUS.PERM_VIOLATION cleared by W1C");
        check_eq(irq,      1'b0, "C: irq deasserted after clear");

        // --- Test D: read from rule 1 (allowed) ---
        data_read(32'h0000_2004, rdata, resp);
        check_eq(resp, 2'b00, "D: read RO region -> OKAY");

        // --- Test E: unmapped address -> DECERR + ADDR_VIOLATION ---
        data_write(32'h0000_5000, 32'h1111_1111, resp);
        check_eq(resp, 2'b11, "E: unmapped write -> DECERR");
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[0], 1'b1, "E: STATUS.ADDR_VIOLATION set");
        ctrl_write(OFF_STATUS, 32'h1); // clear

        // --- Test F: downstream hang -> timeout -> isolate ---
        hang_mode = HANG_ADDR;
        data_write(32'h0000_1008, 32'hAAAA_AAAA, resp);
        check_eq(resp, 2'b10, "F: hung slave -> SLVERR from timeout");
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[2], 1'b1, "F: STATUS.TIMEOUT_ERROR set");
        check_eq(rdata[3], 1'b1, "F: STATUS.ISOLATED set (auto-isolate)");
        hang_mode = HANG_NONE;

        // --- Test G: while isolated, even a normally-valid access is blocked
        //     immediately, and must never reach m_axi ---
        fork
            begin: g_watch
                @(posedge m_axi_awvalid);
                fail_count++;
                $display("  FAIL: G: m_axi_awvalid asserted while ISOLATED");
            end
            begin
                data_write(32'h0000_1000, 32'h5555_5555, resp);
                check_eq(resp, 2'b10, "G: access while ISOLATED -> SLVERR");
                disable g_watch;
            end
        join

        // --- clear timeout status -> releases auto-isolate ---
        //
        // v2.0: this clears the sticky bit and the ISOLATED latch, but the
        // downstream stays blocked until RECOVERY.UNBLOCK. A v1.x driver
        // stopped here and resumed traffic; that is exactly the behaviour
        // change this version is about.
        ctrl_write(OFF_STATUS, 32'h4);
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[ST_ISOLATED], 1'b0, "clearing TIMEOUT_ERROR releases ISOLATED");
        check_eq(rdata[ST_BLOCKED],  1'b1, "but the downstream stays blocked");
        recover_downstream();

        // --- Test H: normal access now succeeds again ---
        data_write(32'h0000_1000, 32'h5A5A_5A5A, resp);
        check_eq(resp, 2'b00, "H: write succeeds after recovery");
        data_read(32'h0000_1000, rdata, resp);
        check_eq(rdata, 32'h5A5A_5A5A, "H: read-back after recovery matches");

        // --- Test I: global bypass mode lets an unmapped address through ---
        ctrl_write(OFF_CTRL, 32'b000); // global_enable=0
        data_write(32'h0000_5000, 32'h9999_9999, resp);
        check_eq(resp, 2'b00, "I: bypass mode forwards unmapped write -> OKAY");
        ctrl_write(OFF_CTRL, 32'b001); // re-enable
        data_write(32'h0000_5004, 32'h1234_5678, resp);
        check_eq(resp, 2'b11, "I: re-enabled, unmapped write -> DECERR again");

        // ==================================================================
        // Tests J-M: READ-DENIAL PATH
        // Coverage showed RD_EVAL -> RD_RESP was never taken: every denial
        // test above is a WRITE. The read path has its own FSM, its own rule
        // lookup port (chk_r_*), and its own fault signals, so none of it was
        // exercised. These close that gap.
        // ==================================================================

        // Rule 2: 0x3000-0x3FFF, WRITE-ONLY (no read) - needed to provoke a
        // read permission denial, which no existing rule can do.
        ctrl_write(rule_off(2,0), 32'h0000_3000);
        ctrl_write(rule_off(2,4), 32'h0000_3FFF);
        ctrl_write(rule_off(2,8), 32'b110); // valid|write, read NOT allowed
        ctrl_write(OFF_STATUS, 32'h7);      // clear any residue

        // --- Test J: read from a write-only region -> SLVERR + PERM_VIOLATION
        data_read(32'h0000_3004, rdata, resp);
        check_eq(resp, 2'b10, "J: read from write-only region -> SLVERR");
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[1], 1'b1, "J: STATUS.PERM_VIOLATION set by a READ");
        ctrl_read(OFF_FADDR, rdata);
        check_eq(rdata, 32'h0000_3004, "J: FAULT_ADDR captured from read path");
        ctrl_read(OFF_FINFO, rdata);
        check_eq(rdata[0], 1'b0, "J: FAULT_INFO.WAS_WRITE = 0 for a read fault");
        check_eq(rdata[3:1], 3'd2, "J: FAULT_INFO type = PERM(2)");
        ctrl_write(OFF_STATUS, 32'h7);

        // --- Test K: read from an unmapped address -> DECERR + ADDR_VIOLATION
        data_read(32'h0000_7000, rdata, resp);
        check_eq(resp, 2'b11, "K: unmapped read -> DECERR");
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[0], 1'b1, "K: STATUS.ADDR_VIOLATION set by a READ");
        ctrl_read(OFF_FADDR, rdata);
        check_eq(rdata, 32'h0000_7000, "K: FAULT_ADDR is the read address");
        ctrl_read(OFF_FINFO, rdata);
        check_eq(rdata[0], 1'b0, "K: FAULT_INFO.WAS_WRITE = 0 for unmapped read");
        check_eq(rdata[3:1], 3'd1, "K: FAULT_INFO type = ADDR(1)");
        ctrl_write(OFF_STATUS, 32'h7);

        // --- Test L: denied read returns zeroed RDATA (no stale/leaked data)
        //
        // The preload must be a successful READ, not a write. Writing the
        // value only puts it in the slave model; s_axi_rdata is untouched, so
        // if the DECERR path stopped zeroing RDATA the register would still
        // hold whatever the last read left there - which happened to be zero,
        // and the check passed against deliberately broken RTL. Reading it
        // back first puts a non-zero value in s_axi_rdata, so the following
        // denied read has something real to leak.
        data_write(32'h0000_1000, 32'hDEADC0DE, resp);
        data_read (32'h0000_1000, rdata, resp);
        check_eq(rdata, 32'hDEADC0DE, "L: preload - RDATA holds a non-zero value");

        data_read(32'h0000_7004, rdata, resp);
        check_eq(resp,  2'b11,         "L: second unmapped read -> DECERR");
        check_eq(rdata, 32'h0000_0000, "L: denied read returns zeros, not stale data");

        // Same again for the permission-denied path, which is a different
        // branch of the read FSM and was never checked for leakage at all.
        data_read (32'h0000_1000, rdata, resp);
        check_eq(rdata, 32'hDEADC0DE, "L: preload before permission denial");
        data_read(32'h0000_3004, rdata, resp);   // rule 2 is write-only
        check_eq(resp,  2'b10,         "L: permission-denied read -> SLVERR");
        check_eq(rdata, 32'h0000_0000, "L: permission-denied read returns zeros");
        ctrl_write(OFF_STATUS, 32'h7);

        // --- Test M: read while ISOLATED is blocked without reaching m_axi
        ctrl_write(OFF_CTRL, 32'b101); // global_enable=1, manual_isolate=1
        fork
            begin: m_watch
                @(posedge m_axi_arvalid);
                fail_count++;
                $display("  FAIL: M: m_axi_arvalid asserted while ISOLATED");
            end
            begin
                data_read(32'h0000_1000, rdata, resp);
                check_eq(resp, 2'b10, "M: read while ISOLATED -> SLVERR");
                disable m_watch;
            end
        join
        ctrl_write(OFF_CTRL, 32'b001); // release manual isolate
        ctrl_write(OFF_STATUS, 32'h7);

        // --- sanity: reads still work normally after all the denials
        data_read(32'h0000_1000, rdata, resp);
        check_eq(resp,  2'b00,       "M: read works again after isolate released");
        check_eq(rdata, 32'hDEADC0DE, "M: correct data after recovery");

        // ==================================================================
        // Tests N-P: READ-SIDE TIMEOUT and DOWNSTREAM RECOVERY
        //
        // v2.0: recovery is now the documented software sequence - poll the
        // busy bits, reset the peripheral, write RECOVERY.UNBLOCK - instead
        // of a peripheral reset the core drove itself.
        // ==================================================================
        ctrl_write(OFF_STATUS, 32'h7);
        ctrl_write(OFF_CTRL,   32'b011);   // enable + auto-isolate

        // --- Test N: hung slave on a READ -> SLVERR + TIMEOUT + isolate
        hang_mode = HANG_ADDR;
        data_read(32'h0000_1000, rdata, resp);
        check_eq(resp, 2'b10, "N: hung slave on read -> SLVERR");
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[2], 1'b1, "N: STATUS.TIMEOUT_ERROR set by a read timeout");
        ctrl_read(OFF_FINFO, rdata);
        check_eq(rdata[0], 1'b0, "N: FAULT_INFO.WAS_WRITE = 0 for read timeout");
        check_eq(rdata[3:1], 3'd3, "N: FAULT_INFO type = TIMEOUT(3)");

        // --- Test O: the downstream is blocked, and says so in STATUS
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[ST_BLOCKED],  1'b1, "O: STATUS.BLOCKED set after timeout");
        check_eq(rdata[ST_RD_STUCK], 1'b1,
                 "O: STATUS.RD_CMD_STUCK set - ARVALID never accepted");
        check_eq(rdata[ST_RD_BUSY],  1'b0,
                 "O: STATUS.RD_RESP_BUSY clear - no response was ever owed");

        // forwarding must stay blocked even though AUTO_ISOLATE only governs
        // the visible ISOLATED bit
        fork
            begin: o_watch
                @(posedge m_axi_arvalid);
                fail_count++;
                $display("  FAIL: O: m_axi_arvalid asserted while downstream broken");
            end
            begin
                data_read(32'h0000_1000, rdata, resp);
                check_eq(resp, 2'b10, "O: read blocked while downstream broken -> SLVERR");
                disable o_watch;
            end
        join

        // Acknowledging the fault must NOT resume forwarding on its own -
        // that changed in v2.0, and a driver written against v1.x would
        // otherwise restart traffic toward an unreset peripheral.
        ctrl_write(OFF_STATUS, 32'h4);
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[ST_TIMEOUT], 1'b0, "O: W1C clears TIMEOUT_ERROR");
        check_eq(rdata[ST_BLOCKED], 1'b1,
                 "O: W1C alone does NOT unblock the downstream");
        hang_mode = HANG_NONE;

        // --- Test P: full recovery sequence -> traffic resumes
        check_eq(m_axi_arvalid, 1'b1,
                 "P: ARVALID still asserted before unblock (AXI requires it)");
        recover_downstream();
        check_eq(m_axi_arvalid, 1'b0, "P: UNBLOCK withdrew the stuck ARVALID");
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[ST_BLOCKED], 1'b0, "P: STATUS.BLOCKED clear after UNBLOCK");

        data_write(32'h0000_1000, 32'h600D_600D, resp);
        check_eq(resp, 2'b00, "P: write works after downstream recovery");
        data_read(32'h0000_1000, rdata, resp);
        check_eq(resp,  2'b00,        "P: read works after downstream recovery");
        check_eq(rdata, 32'h600D_600D, "P: correct data after downstream recovery");
        ctrl_write(OFF_STATUS, 32'h7);

        // ==================================================================
        // Tests Q-R: RESPONSE-PHASE TIMEOUT  (v1.2)
        //
        // Every timeout test above uses HANG_ADDR, where the peripheral never
        // raises AWREADY/ARREADY. That exercises only the address-phase
        // timeout branch. HANG_RESP accepts the address and data normally and
        // then goes quiet, which is the other branch of both FSMs - the one
        // Questa reported at 0% (top.v lines 403-419 / 544-557). It is also
        // the realistic failure: a peripheral that acknowledges and then
        // wedges, rather than one that never acknowledges at all.
        // ==================================================================
        ctrl_write(OFF_CTRL, 32'b011);     // enable + auto-isolate

        // --- Test Q: peripheral accepts a WRITE then never answers
        hang_mode = HANG_RESP;
        data_write(32'h0000_1010, 32'hBEEF_0001, resp);
        check_eq(resp, 2'b10, "Q: accepted-then-silent write -> SLVERR");
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[2], 1'b1, "Q: TIMEOUT_ERROR set on response-phase timeout");
        ctrl_read(OFF_FINFO, rdata);
        check_eq(rdata[0],   1'b1, "Q: FAULT_INFO.WAS_WRITE = 1");
        check_eq(rdata[3:1], 3'd3, "Q: FAULT_INFO type = TIMEOUT(3)");
        // The distinguishing bit: HANG_RESP accepted the command, so a
        // response really is owed - unlike test O, where nothing was.
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[ST_WR_BUSY],  1'b1,
                 "Q: STATUS.WR_RESP_BUSY set - peripheral owes a response");
        check_eq(rdata[ST_WR_STUCK], 1'b0,
                 "Q: STATUS.WR_CMD_STUCK clear - the command was accepted");
        hang_mode = HANG_NONE;
        // A driver polling busy would spin forever here: the owed response
        // never arrives. Resetting the peripheral is what clears it, and the
        // model's reset is what makes the busy bit drop.
        recover_downstream();
        data_write(32'h0000_1010, 32'hBEEF_0002, resp);
        check_eq(resp, 2'b00, "Q: write works after response-phase recovery");
        ctrl_write(OFF_STATUS, 32'h7);

        // --- Test R: peripheral accepts a READ then never answers
        hang_mode = HANG_RESP;
        data_read(32'h0000_1010, rdata, resp);
        check_eq(resp,  2'b10,         "R: accepted-then-silent read -> SLVERR");
        check_eq(rdata, 32'h0000_0000, "R: timed-out read returns zeros");
        ctrl_read(OFF_FINFO, rdata);
        check_eq(rdata[0],   1'b0, "R: FAULT_INFO.WAS_WRITE = 0");
        check_eq(rdata[3:1], 3'd3, "R: FAULT_INFO type = TIMEOUT(3)");
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[ST_RD_BUSY], 1'b1,
                 "R: STATUS.RD_RESP_BUSY set - peripheral owes a read response");
        hang_mode = HANG_NONE;
        ctrl_write(OFF_STATUS, 32'h4);
        recover_downstream();
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[ST_RD_BUSY], 1'b0, "R: RD_RESP_BUSY cleared by UNBLOCK");
        data_read(32'h0000_1010, rdata, resp);
        check_eq(resp,  2'b00,         "R: read works after response-phase recovery");
        check_eq(rdata, 32'hBEEF_0002, "R: correct data after recovery");
        ctrl_write(OFF_STATUS, 32'h7);

        // ==================================================================
        // Test S: RESET ASSERTED MID-TRANSACTION  (v1.2)
        // Sweeps the reset point across the *_EVAL and *_FWD states to close
        // the four FSM transitions that were previously uncovered.
        // ==================================================================
        $display("\n--- Test S: reset asserted mid-transaction ---");
        test_reset_mid_transaction(1, HANG_NONE);   // in *_EVAL
        test_reset_mid_transaction(2, HANG_ADDR);   // in *_FWD, address phase
        test_reset_mid_transaction(3, HANG_RESP);   // in *_FWD, response phase
        test_reset_mid_transaction(4, HANG_ADDR);

        data_write(32'h0000_1000, 32'h5EED_5EED, resp);
        check_eq(resp, 2'b00, "S: write works after reset mid-transaction");
        data_read(32'h0000_1000, rdata, resp);
        check_eq(resp,  2'b00,        "S: read works after reset mid-transaction");
        check_eq(rdata, 32'h5EED_5EED, "S: correct data after reset mid-transaction");
        ctrl_write(OFF_STATUS, 32'h7);

        // ==================================================================
        // EXECUTE COVERAGE TASKS
        // ==================================================================
        test_reg_sweep();
        test_manual_isolation();
        test_irq_masking();
        ctrl_write_staggered(OFF_TMOUT, 32'd20);
        test_write_backpressure();
        test_read_backpressure();
        test_response_backpressure();
        test_unblock_semantics();
        measure_latency();

        $display("=== RESULTS: %0d passed, %0d failed ===", pass_count, fail_count);
        $display("=== m_axi VALID-drop violations: AW=%0d W=%0d AR=%0d ===",
                 m_awvalid_drops, m_wvalid_drops, m_arvalid_drops);
        if (m_awvalid_drops || m_wvalid_drops || m_arvalid_drops) begin
            fail_count++;
            $display("*** m_axi PROTOCOL VIOLATIONS DETECTED ***");
        end
        finish_run;
    end

    // ------------------------------------------------------------------
    // Termination.
    //
    // $finish's argument is a diagnostic verbosity level, NOT a process exit
    // code - $finish(1) exits 0 just like $finish(0), so any CI job checking
    // $? would pass a failing run. $fatal does set a non-zero status (and
    // makes vsim exit non-zero in batch mode), so use it where available;
    // Icarus in -g2005 mode has no $fatal, hence the guard. Either way the
    // run scripts also grep for the PASSED/FAILED marker, which is the
    // portable check.
    // ------------------------------------------------------------------
    task automatic finish_run;
        begin
            if (fail_count != 0) begin
                $display("*** TEST BENCH FAILED (%0d checks failed) ***", fail_count);
`ifdef ICARUS
                $finish;
`else
                $fatal(1, "axi_firewall_tb: %0d checks failed", fail_count);
`endif
            end else begin
                $display("*** ALL TESTS PASSED ***");
                $finish;
            end
        end
    endtask

    // watchdog
    initial begin
        #200000;
        $display("FAIL: global watchdog timeout - simulation hung");
        fail_count++;
        finish_run;
    end

endmodule
