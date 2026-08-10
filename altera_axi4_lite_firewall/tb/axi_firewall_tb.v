`timescale 1ns/1ps

module axi_firewall_tb;

    localparam ADDR_WIDTH      = 32;
    localparam DATA_WIDTH      = 32;
    localparam CTRL_ADDR_WIDTH = 12;
    localparam NUM_RULES       = 8;
    localparam TIMEOUT_WIDTH   = 20;

    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    // ---------------- s_axi (drive as the "Nios II side") -----------------
    reg  [ADDR_WIDTH-1:0]   s_axi_awaddr;
    reg  [2:0]              s_axi_awprot = 0;
    reg                     s_axi_awvalid = 0;
    wire                    s_axi_awready;
    reg  [DATA_WIDTH-1:0]   s_axi_wdata;
    reg  [DATA_WIDTH/8-1:0] s_axi_wstrb;
    reg                     s_axi_wvalid = 0;
    wire                    s_axi_wready;
    wire [1:0]              s_axi_bresp;
    wire                    s_axi_bvalid;
    reg                     s_axi_bready = 0;
    reg  [ADDR_WIDTH-1:0]   s_axi_araddr;
    reg  [2:0]              s_axi_arprot = 0;
    reg                     s_axi_arvalid = 0;
    wire                    s_axi_arready;
    wire [DATA_WIDTH-1:0]   s_axi_rdata;
    wire [1:0]              s_axi_rresp;
    wire                    s_axi_rvalid;
    reg                     s_axi_rready = 0;

    // ---------------- m_axi (behavioral downstream slave model) -----------
    wire [ADDR_WIDTH-1:0]   m_axi_awaddr;
    wire [2:0]              m_axi_awprot;
    wire                    m_axi_awvalid;
    reg                     m_axi_awready = 0;
    wire [DATA_WIDTH-1:0]   m_axi_wdata;
    wire [DATA_WIDTH/8-1:0] m_axi_wstrb;
    wire                    m_axi_wvalid;
    reg                     m_axi_wready = 0;
    reg  [1:0]              m_axi_bresp = 0;
    reg                     m_axi_bvalid = 0;
    wire                    m_axi_bready;
    wire [ADDR_WIDTH-1:0]   m_axi_araddr;
    wire [2:0]              m_axi_arprot;
    wire                    m_axi_arvalid;
    reg                     m_axi_arready = 0;
    reg  [DATA_WIDTH-1:0]   m_axi_rdata = 0;
    reg  [1:0]              m_axi_rresp = 0;
    reg                     m_axi_rvalid = 0;
    wire                    m_axi_rready;

    // ---------------- s_axi_ctrl (drive as "management software") ----------
    reg  [CTRL_ADDR_WIDTH-1:0] s_axi_ctrl_awaddr;
    reg  [2:0]                 s_axi_ctrl_awprot = 0;
    reg                        s_axi_ctrl_awvalid = 0;
    wire                       s_axi_ctrl_awready;
    reg  [31:0]                s_axi_ctrl_wdata;
    reg  [3:0]                 s_axi_ctrl_wstrb;
    reg                        s_axi_ctrl_wvalid = 0;
    wire                       s_axi_ctrl_wready;
    wire [1:0]                 s_axi_ctrl_bresp;
    wire                       s_axi_ctrl_bvalid;
    reg                        s_axi_ctrl_bready = 0;
    reg  [CTRL_ADDR_WIDTH-1:0] s_axi_ctrl_araddr;
    reg  [2:0]                 s_axi_ctrl_arprot = 0;
    reg                        s_axi_ctrl_arvalid = 0;
    wire                       s_axi_ctrl_arready;
    wire [31:0]                s_axi_ctrl_rdata;
    wire [1:0]                 s_axi_ctrl_rresp;
    wire                       s_axi_ctrl_rvalid;
    reg                        s_axi_ctrl_rready = 0;

    wire irq;
    wire m_axi_resetn;   // peripheral reset output (v1.1)

    integer pass_count = 0;
    integer fail_count = 0;

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

        .irq(irq),
        .m_axi_resetn(m_axi_resetn)
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
        .m_axi_resetn(m_axi_resetn),

        // per-direction pulses, NOT the merged fault_*_violation wires
        .wr_violation(wr_fault_addr_violation | wr_fault_perm_violation),
        .rd_violation(rd_fault_addr_violation | rd_fault_perm_violation)
    );
`endif

    // ------------------------------------------------------------------
    // Behavioral downstream slave: 16 words of memory, always-ready
    // unless `hang_next` is set, in which case it silently ignores the
    // next address phase entirely (models a wedged peripheral).
    // ------------------------------------------------------------------
    reg [31:0] mem [0:15];
    reg hang_next = 0;

    always @(posedge clk) begin
        if (!resetn) begin
            m_axi_awready <= 0; m_axi_wready <= 0; m_axi_bvalid <= 0;
            m_axi_arready <= 0; m_axi_rvalid <= 0;
        end else begin
            // write side
            if (!hang_next) begin
                m_axi_awready <= m_axi_awvalid && !m_axi_awready;
                m_axi_wready  <= m_axi_wvalid  && !m_axi_wready;
            end else begin
                m_axi_awready <= 0;
                m_axi_wready  <= 0;
            end

            if (m_axi_awvalid && m_axi_awready && m_axi_wvalid && m_axi_wready) begin
                mem[m_axi_awaddr[5:2]] <= m_axi_wdata;
                m_axi_bvalid <= 1;
                m_axi_bresp  <= 2'b00;
            end else if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 0;
            end

            // read side
            if (!hang_next) begin
                m_axi_arready <= m_axi_arvalid && !m_axi_arready;
            end else begin
                m_axi_arready <= 0;
            end

            if (m_axi_arvalid && m_axi_arready) begin
                m_axi_rdata  <= mem[m_axi_araddr[5:2]];
                m_axi_rresp  <= 2'b00;
                m_axi_rvalid <= 1;
            end else if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 0;
            end
        end
    end

    // ------------------------------------------------------------------
    // BFM tasks
    // ------------------------------------------------------------------
    task data_write(input [ADDR_WIDTH-1:0] addr, input [31:0] data, output [1:0] resp);
        begin
            @(posedge clk);
            s_axi_awaddr  = addr; s_axi_awvalid = 1;
            s_axi_wdata   = data; s_axi_wstrb = 4'hF; s_axi_wvalid = 1;
            s_axi_bready  = 1;
            @(posedge clk);
            while (!(s_axi_awready && s_axi_wready)) @(posedge clk);
            s_axi_awvalid = 0; s_axi_wvalid = 0;
            while (!s_axi_bvalid) @(posedge clk);
            resp = s_axi_bresp;
            @(posedge clk);
            s_axi_bready = 0;
        end
    endtask

    task data_read(input [ADDR_WIDTH-1:0] addr, output [31:0] data, output [1:0] resp);
        begin
            @(posedge clk);
            s_axi_araddr = addr; s_axi_arvalid = 1;
            s_axi_rready = 1;
            @(posedge clk);
            while (!s_axi_arready) @(posedge clk);
            s_axi_arvalid = 0;
            while (!s_axi_rvalid) @(posedge clk);
            data = s_axi_rdata;
            resp = s_axi_rresp;
            @(posedge clk);
            s_axi_rready = 0;
        end
    endtask

    task ctrl_write(input [CTRL_ADDR_WIDTH-1:0] addr, input [31:0] data);
        reg [1:0] resp;
        begin
            @(posedge clk);
            s_axi_ctrl_awaddr = addr; s_axi_ctrl_awvalid = 1;
            s_axi_ctrl_wdata  = data; s_axi_ctrl_wstrb = 4'hF; s_axi_ctrl_wvalid = 1;
            s_axi_ctrl_bready = 1;
            @(posedge clk);
            while (!(s_axi_ctrl_awready && s_axi_ctrl_wready)) @(posedge clk);
            s_axi_ctrl_awvalid = 0; s_axi_ctrl_wvalid = 0;
            while (!s_axi_ctrl_bvalid) @(posedge clk);
            resp = s_axi_ctrl_bresp;
            @(posedge clk);
            s_axi_ctrl_bready = 0;
        end
    endtask

    task ctrl_read(input [CTRL_ADDR_WIDTH-1:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            s_axi_ctrl_araddr = addr; s_axi_ctrl_arvalid = 1;
            s_axi_ctrl_rready = 1;
            @(posedge clk);
            while (!s_axi_ctrl_arready) @(posedge clk);
            s_axi_ctrl_arvalid = 0;
            while (!s_axi_ctrl_rvalid) @(posedge clk);
            data = s_axi_ctrl_rdata;
            @(posedge clk);
            s_axi_ctrl_rready = 0;
        end
    endtask

    task wait_cycles(input integer n);
        integer w;
        begin
            for (w = 0; w < n; w = w + 1) @(posedge clk);
        end
    endtask

    task check_eq(input [63:0] actual, input [63:0] expected, input [8*64-1:0] name);
        begin
            if (actual === expected) begin
                pass_count = pass_count + 1;
                $display("  PASS: %0s (got 0x%0h)", name, actual);
            end else begin
                fail_count = fail_count + 1;
                $display("  FAIL: %0s  expected 0x%0h got 0x%0h", name, expected, actual);
            end
        end
    endtask

    // ==================================================================
    // REGISTER OFFSETS (Moved above tasks so compiler sees them first)
    // ==================================================================
    localparam OFF_CTRL   = 'h00, OFF_STATUS = 'h04, OFF_IRQEN = 'h08,
               OFF_TMOUT  = 'h0C, OFF_FADDR  = 'h10, OFF_FINFO = 'h14,
               OFF_INFO   = 'h18;
               
    function [11:0] rule_off; input integer idx; input integer sub; begin
        rule_off = 'h40 + idx*16 + sub; end
    endfunction

    // ==================================================================
    // COVERAGE IMPROVEMENT TASKS
    // ==================================================================

    // Task 1: Sweep all register offsets including unmapped ones
    task test_reg_sweep;
        reg [31:0] read_data;
        reg [CTRL_ADDR_WIDTH-1:0] addrs [0:7];
        integer i;
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

            for (i = 0; i < 8; i = i + 1) begin
                ctrl_write(addrs[i], 32'hA5A5_5A5A);
                ctrl_read(addrs[i], read_data);
            end
        end
    endtask

    // Task 2: Assert and clear software manual isolation
    task test_manual_isolation;
        reg [31:0] read_data;
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
    task test_irq_masking;
        reg [31:0] read_data;
        reg [1:0] dummy_resp;
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
    task ctrl_write_staggered;
        input [CTRL_ADDR_WIDTH-1:0] addr;
        input [31:0] data;
        begin
            $display("\n--- Coverage Test 4: Staggered AXI-Lite Channels ---");
            @(posedge clk);
            s_axi_ctrl_awaddr  <= addr;
            s_axi_ctrl_awvalid <= 1'b1;
            s_axi_ctrl_wvalid  <= 1'b0; // Delay write data

            repeat (2) @(posedge clk);
            s_axi_ctrl_wdata   <= data;
            s_axi_ctrl_wstrb   <= 4'hF;
            s_axi_ctrl_wvalid  <= 1'b1;
            s_axi_ctrl_bready  <= 1'b1;

            while (!(s_axi_ctrl_awready && s_axi_ctrl_wready)) @(posedge clk);
            s_axi_ctrl_awvalid <= 1'b0;
            s_axi_ctrl_wvalid  <= 1'b0;

            while (!s_axi_ctrl_bvalid) @(posedge clk);
            @(posedge clk);
            s_axi_ctrl_bready  <= 1'b0;
        end
    endtask

    reg [31:0] rdata;
    reg [1:0]  resp;

    initial begin
        resetn = 0;
        repeat (5) @(posedge clk);
        resetn = 1;
        repeat (2) @(posedge clk);

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
        hang_next = 1;
        data_write(32'h0000_1008, 32'hAAAA_AAAA, resp);
        check_eq(resp, 2'b10, "F: hung slave -> SLVERR from timeout");
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[2], 1'b1, "F: STATUS.TIMEOUT_ERROR set");
        check_eq(rdata[3], 1'b1, "F: STATUS.ISOLATED set (auto-isolate)");
        hang_next = 0;

        // --- Test G: while isolated, even a normally-valid access is blocked
        //     immediately, and must never reach m_axi ---
        fork
            begin: g_watch
                @(posedge m_axi_awvalid);
                fail_count = fail_count + 1;
                $display("  FAIL: G: m_axi_awvalid asserted while ISOLATED");
            end
            begin
                data_write(32'h0000_1000, 32'h5555_5555, resp);
                check_eq(resp, 2'b10, "G: access while ISOLATED -> SLVERR");
                disable g_watch;
            end
        join

        // --- clear timeout status -> releases auto-isolate ---
        ctrl_write(OFF_STATUS, 32'h4);
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[3], 1'b0, "clearing TIMEOUT_ERROR releases ISOLATED");

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
        // Preload a known value at an allowed address first, then confirm a
        // denied read elsewhere does not return it.
        data_write(32'h0000_1000, 32'hDEADC0DE, resp);
        data_read(32'h0000_7004, rdata, resp);
        check_eq(resp,  2'b11,       "L: second unmapped read -> DECERR");
        check_eq(rdata, 32'h0000_0000, "L: denied read returns zeros, not stale data");
        ctrl_write(OFF_STATUS, 32'h7);

        // --- Test M: read while ISOLATED is blocked without reaching m_axi
        ctrl_write(OFF_CTRL, 32'b101); // global_enable=1, manual_isolate=1
        fork
            begin: m_watch
                @(posedge m_axi_arvalid);
                fail_count = fail_count + 1;
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
        // Tests N-P: READ-SIDE TIMEOUT and DOWNSTREAM RECOVERY  (v1.1)
        // The read path's timeout branch was never exercised, so its
        // protocol behaviour was untested. These also cover the new
        // m_axi_resetn recovery sequence.
        // ==================================================================
        ctrl_write(OFF_STATUS, 32'h7);
        ctrl_write(OFF_CTRL,   32'b011);   // enable + auto-isolate

        // --- Test N: hung slave on a READ -> SLVERR + TIMEOUT + isolate
        hang_next = 1;
        data_read(32'h0000_1000, rdata, resp);
        check_eq(resp, 2'b10, "N: hung slave on read -> SLVERR");
        ctrl_read(OFF_STATUS, rdata);
        check_eq(rdata[2], 1'b1, "N: STATUS.TIMEOUT_ERROR set by a read timeout");
        ctrl_read(OFF_FINFO, rdata);
        check_eq(rdata[0], 1'b0, "N: FAULT_INFO.WAS_WRITE = 0 for read timeout");
        check_eq(rdata[3:1], 3'd3, "N: FAULT_INFO type = TIMEOUT(3)");

        // --- Test O: peripheral reset is asserted while broken
        check_eq(m_axi_resetn, 1'b0, "O: m_axi_resetn asserted low while downstream broken");

        // forwarding must stay blocked even though AUTO_ISOLATE only governs
        // the visible ISOLATED bit
        fork
            begin: o_watch
                @(posedge m_axi_arvalid);
                fail_count = fail_count + 1;
                $display("  FAIL: O: m_axi_arvalid asserted while downstream broken");
            end
            begin
                data_read(32'h0000_1000, rdata, resp);
                check_eq(resp, 2'b10, "O: read blocked while downstream broken -> SLVERR");
                disable o_watch;
            end
        join
        hang_next = 0;

        // --- Test P: acknowledge the fault -> reset pulse -> traffic resumes
        ctrl_write(OFF_STATUS, 32'h4);     // W1C TIMEOUT_ERROR -> starts recovery
        // wait out the peripheral reset pulse
        wait_cycles(40);
        check_eq(m_axi_resetn, 1'b1, "P: m_axi_resetn released after recovery");

        data_write(32'h0000_1000, 32'h600D_600D, resp);
        check_eq(resp, 2'b00, "P: write works after downstream recovery");
        data_read(32'h0000_1000, rdata, resp);
        check_eq(resp,  2'b00,        "P: read works after downstream recovery");
        check_eq(rdata, 32'h600D_600D, "P: correct data after downstream recovery");
        ctrl_write(OFF_STATUS, 32'h7);

        // ==================================================================
        // EXECUTE COVERAGE TASKS
        // ==================================================================
        test_reg_sweep();
        test_manual_isolation();
        test_irq_masking();
        ctrl_write_staggered(OFF_TMOUT, 32'd20);

        $display("=== RESULTS: %0d passed, %0d failed ===", pass_count, fail_count);
        $display("=== m_axi VALID-drop violations: AW=%0d W=%0d AR=%0d ===",
                 m_awvalid_drops, m_wvalid_drops, m_arvalid_drops);
        if (m_awvalid_drops || m_wvalid_drops || m_arvalid_drops) begin
            fail_count = fail_count + 1;
            $display("*** m_axi PROTOCOL VIOLATIONS DETECTED ***");
        end
        if (fail_count != 0) begin
            $display("*** TEST BENCH FAILED ***");
            $finish(1);
        end else begin
            $display("*** ALL TESTS PASSED ***");
            $finish(0);
        end
    end


    // ==================================================================
    // AXI protocol checker on the MASTER (m_axi) side.
    // Rule: once *VALID is asserted it must stay asserted until the
    // matching *READY handshake. Dropping it while the peripheral is held
    // in reset (m_axi_resetn low) is the one legitimate exception.
    // ==================================================================
    integer m_awvalid_drops = 0, m_wvalid_drops = 0, m_arvalid_drops = 0;
    reg m_awv_q, m_wv_q, m_arv_q, m_awr_q, m_wr_q, m_arr_q, m_rstn_q;

    always @(posedge clk) begin
        if (!resetn) begin
            m_awv_q<=0; m_wv_q<=0; m_arv_q<=0; m_awr_q<=0; m_wr_q<=0; m_arr_q<=0; m_rstn_q<=0;
        end else begin
            if (m_awv_q && !m_axi_awvalid && !m_awr_q && m_rstn_q) begin
                m_awvalid_drops = m_awvalid_drops + 1;
                $display("  >> AXI VIOLATION t=%0t: m_axi_AWVALID dropped without AWREADY", $time);
            end
            if (m_wv_q && !m_axi_wvalid && !m_wr_q && m_rstn_q) begin
                m_wvalid_drops = m_wvalid_drops + 1;
                $display("  >> AXI VIOLATION t=%0t: m_axi_WVALID dropped without WREADY", $time);
            end
            if (m_arv_q && !m_axi_arvalid && !m_arr_q && m_rstn_q) begin
                m_arvalid_drops = m_arvalid_drops + 1;
                $display("  >> AXI VIOLATION t=%0t: m_axi_ARVALID dropped without ARREADY", $time);
            end
            m_awv_q<=m_axi_awvalid; m_awr_q<=m_axi_awready;
            m_wv_q <=m_axi_wvalid;  m_wr_q <=m_axi_wready;
            m_arv_q<=m_axi_arvalid; m_arr_q<=m_axi_arready;
            m_rstn_q<=m_axi_resetn;
        end
    end

    // watchdog
    initial begin
        #100000;
        $display("FAIL: global watchdog timeout - simulation hung");
        $finish(1);
    end

endmodule
