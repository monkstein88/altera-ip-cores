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

        .irq(irq)
    );

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

    // register offsets
    localparam OFF_CTRL   = 'h00, OFF_STATUS = 'h04, OFF_IRQEN = 'h08,
               OFF_TMOUT  = 'h0C, OFF_FADDR  = 'h10, OFF_FINFO = 'h14,
               OFF_INFO   = 'h18;
    function [11:0] rule_off; input integer idx; input integer sub; begin
        rule_off = 'h40 + idx*16 + sub; end
    endfunction

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

        $display("=== RESULTS: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count != 0) begin
            $display("*** TEST BENCH FAILED ***");
            $finish(1);
        end else begin
            $display("*** ALL TESTS PASSED ***");
            $finish(0);
        end
    end

    // watchdog
    initial begin
        #100000;
        $display("FAIL: global watchdog timeout - simulation hung");
        $finish(1);
    end

endmodule
