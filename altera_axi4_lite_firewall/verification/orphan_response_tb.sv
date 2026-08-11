`timescale 1ns/1ps
// =============================================================================
// orphan_response_tb.sv
//
// Does a LATE response from an abandoned (timed-out) transaction get
// mis-attributed to a subsequent, legitimate transaction?
//
// The firewall abandons a transaction on timeout but leaves m_axi_bready tied
// high and keeps no record of how many responses are still owed, so a stale
// BVALID arriving later is indistinguishable from the current transaction's
// own response. m_axi_resetn is the entire defence: it flushes the peripheral
// before any new transaction is forwarded.
//
// (v1.2 note: earlier revisions also carried a wr_discard_pending one-shot
// flag. It was dead code - the timeout that armed it also dropped
// m_axi_resetn, which cleared it before the FSM could ever test it - and has
// been removed. This testbench measures what actually provides the
// protection, which is why it is kept.)
//
// Method: run a clean, permitted write that the slave answers OKAY. Inject one
// extra BVALID (SLVERR) at offset K cycles after the write begins, modelling
// the abandoned transaction's late reply. Sweep K. If the master ever sees
// SLVERR, the stale response was mis-attributed.
//
// Timing discipline is the same as tb/axi_firewall_tb.sv: sample and drive one
// delta after each clock edge, and hold every *VALID through the edge at which
// its handshake is sampled. Driving at the edge itself races the DUT's own
// always blocks and deadlocks under Verilator.
// =============================================================================

module orphan_tb;
    localparam int AW=32, DW=32, CAW=12, NR=8, TW=20;
    logic clk=0, resetn=0; always #5 clk=~clk;

    logic [AW-1:0] s_awaddr; logic s_awvalid=0; logic s_awready;
    logic [DW-1:0] s_wdata; logic [DW/8-1:0] s_wstrb; logic s_wvalid=0; logic s_wready;
    logic [1:0] s_bresp; logic s_bvalid; logic s_bready=0;
    logic [AW-1:0] s_araddr; logic s_arvalid=0; logic s_arready;
    logic [DW-1:0] s_rdata; logic [1:0] s_rresp; logic s_rvalid; logic s_rready=0;

    logic [AW-1:0] m_awaddr; logic m_awvalid; logic m_awready=0;
    logic [DW-1:0] m_wdata; logic [DW/8-1:0] m_wstrb; logic m_wvalid; logic m_wready=0;
    logic [1:0] m_bresp=0; logic m_bvalid=0; logic m_bready;
    logic [AW-1:0] m_araddr; logic m_arvalid; logic m_arready=0;
    logic [DW-1:0] m_rdata=0; logic [1:0] m_rresp=0; logic m_rvalid=0; logic m_rready;

    logic [CAW-1:0] c_awaddr; logic c_awvalid=0; logic c_awready;
    logic [31:0] c_wdata; logic [3:0] c_wstrb; logic c_wvalid=0; logic c_wready;
    logic [1:0] c_bresp; logic c_bvalid; logic c_bready=0;
    logic [CAW-1:0] c_araddr=0; logic c_arvalid=0; logic c_arready;
    logic [31:0] c_rdata; logic [1:0] c_rresp; logic c_rvalid; logic c_rready=0;
    logic irq; logic m_resetn;

    axi_firewall_top #(.ADDR_WIDTH(AW),.DATA_WIDTH(DW),.CTRL_ADDR_WIDTH(CAW),.NUM_RULES(NR),.TIMEOUT_WIDTH(TW)) dut (
      .clk(clk),.resetn(resetn),
      .s_axi_awaddr(s_awaddr),.s_axi_awprot(3'b0),.s_axi_awvalid(s_awvalid),.s_axi_awready(s_awready),
      .s_axi_wdata(s_wdata),.s_axi_wstrb(s_wstrb),.s_axi_wvalid(s_wvalid),.s_axi_wready(s_wready),
      .s_axi_bresp(s_bresp),.s_axi_bvalid(s_bvalid),.s_axi_bready(s_bready),
      .s_axi_araddr(s_araddr),.s_axi_arprot(3'b0),.s_axi_arvalid(s_arvalid),.s_axi_arready(s_arready),
      .s_axi_rdata(s_rdata),.s_axi_rresp(s_rresp),.s_axi_rvalid(s_rvalid),.s_axi_rready(s_rready),
      .m_axi_awaddr(m_awaddr),.m_axi_awprot(),.m_axi_awvalid(m_awvalid),.m_axi_awready(m_awready),
      .m_axi_wdata(m_wdata),.m_axi_wstrb(m_wstrb),.m_axi_wvalid(m_wvalid),.m_axi_wready(m_wready),
      .m_axi_bresp(m_bresp),.m_axi_bvalid(m_bvalid),.m_axi_bready(m_bready),
      .m_axi_araddr(m_araddr),.m_axi_arprot(),.m_axi_arvalid(m_arvalid),.m_axi_arready(m_arready),
      .m_axi_rdata(m_rdata),.m_axi_rresp(m_rresp),.m_axi_rvalid(m_rvalid),.m_axi_rready(m_rready),
      .s_axi_ctrl_awaddr(c_awaddr),.s_axi_ctrl_awprot(3'b0),.s_axi_ctrl_awvalid(c_awvalid),.s_axi_ctrl_awready(c_awready),
      .s_axi_ctrl_wdata(c_wdata),.s_axi_ctrl_wstrb(c_wstrb),.s_axi_ctrl_wvalid(c_wvalid),.s_axi_ctrl_wready(c_wready),
      .s_axi_ctrl_bresp(c_bresp),.s_axi_ctrl_bvalid(c_bvalid),.s_axi_ctrl_bready(c_bready),
      .s_axi_ctrl_araddr(c_araddr),.s_axi_ctrl_arprot(3'b0),.s_axi_ctrl_arvalid(c_arvalid),.s_axi_ctrl_arready(c_arready),
      .s_axi_ctrl_rdata(c_rdata),.s_axi_ctrl_rresp(c_rresp),.s_axi_ctrl_rvalid(c_rvalid),.s_axi_ctrl_rready(c_rready),
      .irq(irq),.m_axi_resetn(m_resetn));

    // Slave model with explicit "owes a response" state.
    //   HONOUR_RESET=1 : peripheral obeys m_axi_resetn (the mandatory wiring).
    //   HONOUR_RESET=0 : peripheral ignores it (unsupported wiring), kept to
    //                    show exactly what protection is lost.
    // In hang mode the slave latches the request WITHOUT handshaking - a
    // deliberately non-compliant peripheral, the nastiest orphan source.
    parameter bit HONOUR_RESET = 1;
    logic hang; logic fire_orphan; logic owes;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            m_awready<=0; m_wready<=0; m_bvalid<=0; owes<=0;
        end else if (HONOUR_RESET && !m_resetn) begin
            m_awready<=0; m_wready<=0; m_bvalid<=0; owes<=0;   // flushed
        end else begin
            if (!hang) begin
                m_awready <= m_awvalid && !m_awready;
                m_wready  <= m_wvalid  && !m_wready;
            end else begin
                m_awready <= 0; m_wready <= 0;
                if (m_awvalid) owes <= 1'b1;    // latched without handshake
            end
            if (!hang && m_awvalid && m_awready && m_wvalid && m_wready) begin
                m_bvalid <= 1; m_bresp <= 2'b00;
            end else if (m_bvalid && m_bready) begin
                m_bvalid <= 0;
            end
            if (fire_orphan && owes) begin
                m_bvalid <= 1; m_bresp <= 2'b10; owes <= 1'b0;
            end
        end
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic wait_cycles(input int n);
        for (int w = 0; w < n; w++) tick;
    endtask

    task automatic ctrl_write(input [CAW-1:0] a, input [31:0] d);
        begin
            tick;
            c_awaddr=a; c_awvalid=1; c_wdata=d; c_wstrb=4'hF; c_wvalid=1; c_bready=1;
            while (!(c_awready && c_wready)) tick;
            tick;                                  // hold through the handshake edge
            c_awvalid=0; c_wvalid=0;
            while (!c_bvalid) tick;
            tick; c_bready=0;
        end
    endtask

    int k, bad;
    logic [1:0] observed;

    initial begin
        bad = 0;
        for (k = 1; k <= 25; k++) begin
            resetn=0; hang=0; fire_orphan=0; owes=0;
            s_awvalid=0; s_wvalid=0; s_bready=0;
            wait_cycles(4);
            resetn=1; wait_cycles(2);

            ctrl_write('h40, 32'h0000_1000);
            ctrl_write('h44, 32'h0000_1FFF);
            ctrl_write('h48, 32'b111);
            ctrl_write('h0C, 32'd10);      // short timeout

            // ---- phase 1: hung slave -> firewall times out and abandons ----
            hang = 1;
            tick;
            s_awaddr=32'h0000_1000; s_awvalid=1;
            s_wdata=32'h1111_1111; s_wstrb=4'hF; s_wvalid=1; s_bready=1;
            while (!(s_awready && s_wready)) tick;
            tick;
            s_awvalid=0; s_wvalid=0;
            while (!s_bvalid) tick;
            tick; s_bready=0;

            // ---- recovery: acknowledge the fault, wait out the reset pulse
            ctrl_write('h04, 32'h4);
            hang = 0;
            wait_cycles(40);

            // ---- phase 2: legitimate write, orphan lands at offset k ------
            tick;
            s_awaddr=32'h0000_1004; s_awvalid=1;
            s_wdata=32'hAAAA_BBBB; s_wstrb=4'hF; s_wvalid=1; s_bready=1;
            fork
                begin : inj
                    wait_cycles(k);
                    fire_orphan = 1; tick; fire_orphan = 0;
                end
                begin : drv
                    while (!(s_awready && s_wready)) tick;
                    tick;
                    s_awvalid=0; s_wvalid=0;
                    while (!s_bvalid) tick;
                    observed = s_bresp;
                    tick; s_bready=0;
                end
            join
            if (observed !== 2'b00) begin
                bad++;
                $display("  k=%0d: BRESP=%b - orphan MIS-ATTRIBUTED to the new write", k, observed);
            end
        end
        $display("=== orphan mis-attribution [HONOUR_RESET=%0d]: %0d of 25 offsets affected ===",
                 HONOUR_RESET, bad);
        $display(" ");
        $finish;
    end

    initial begin #500000; $display("watchdog: orphan_tb hung"); $finish; end
endmodule
