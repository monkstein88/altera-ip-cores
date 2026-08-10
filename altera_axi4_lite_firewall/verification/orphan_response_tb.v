`timescale 1ns/1ps
// Does a LATE response from an abandoned (timed-out) transaction get
// mis-attributed to a subsequent, legitimate transaction?
//
// The firewall abandons a transaction on timeout but leaves m_axi_bready
// tied high and keeps no record of how many responses are still owed. So a
// stale BVALID arriving later is indistinguishable from the current
// transaction's own response.
//
// Method: run a clean, permitted write that the slave answers OKAY. Inject
// one extra BVALID (SLVERR) at offset K cycles after the write begins,
// modelling the abandoned transaction's late reply. Sweep K. If the master
// ever sees SLVERR, the stale response was mis-attributed.

module orphan_tb;
    localparam AW=32, DW=32, CAW=12, NR=8, TW=20;
    reg clk=0, resetn=0; always #5 clk=~clk;

    reg [AW-1:0] s_awaddr; reg s_awvalid=0; wire s_awready;
    reg [DW-1:0] s_wdata; reg [DW/8-1:0] s_wstrb; reg s_wvalid=0; wire s_wready;
    wire [1:0] s_bresp; wire s_bvalid; reg s_bready=0;
    reg [AW-1:0] s_araddr; reg s_arvalid=0; wire s_arready;
    wire [DW-1:0] s_rdata; wire [1:0] s_rresp; wire s_rvalid; reg s_rready=0;

    wire [AW-1:0] m_awaddr; wire m_awvalid; reg m_awready=0;
    wire [DW-1:0] m_wdata; wire [DW/8-1:0] m_wstrb; wire m_wvalid; reg m_wready=0;
    reg [1:0] m_bresp=0; reg m_bvalid=0; wire m_bready;
    wire [AW-1:0] m_araddr; wire m_arvalid; reg m_arready=0;
    reg [DW-1:0] m_rdata=0; reg [1:0] m_rresp=0; reg m_rvalid=0; wire m_rready;

    reg [CAW-1:0] c_awaddr; reg c_awvalid=0; wire c_awready;
    reg [31:0] c_wdata; reg [3:0] c_wstrb; reg c_wvalid=0; wire c_wready;
    wire [1:0] c_bresp; wire c_bvalid; reg c_bready=0;
    reg [CAW-1:0] c_araddr=0; reg c_arvalid=0; wire c_arready;
    wire [31:0] c_rdata; wire [1:0] c_rresp; wire c_rvalid; reg c_rready=0;
    wire irq; wire m_resetn;

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

    // Slave model. In hang mode it never handshakes (so the firewall times
    // out and abandons). It deliberately IGNORES m_axi_resetn, modelling the
    // worst case where the peripheral reset output is left unconnected -
    // this is what exercises the wr_discard_pending path specifically.
    // Slave model with explicit "owes a response" state.
    //   HONOUR_RESET=1 : peripheral obeys m_axi_resetn (the mandatory wiring).
    //   HONOUR_RESET=0 : peripheral ignores it (unsupported wiring), kept to
    //                    show exactly what protection is lost.
    // In hang mode the slave latches the request WITHOUT handshaking - a
    // deliberately non-compliant peripheral, the nastiest orphan source.
    parameter HONOUR_RESET = 1;
    reg hang; reg fire_orphan; reg owes;

    always @(posedge clk) begin
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

    task ctrl_write(input [CAW-1:0] a, input [31:0] d);
        begin
            @(posedge clk);
            c_awaddr<=a; c_awvalid<=1; c_wdata<=d; c_wstrb<=4'hF; c_wvalid<=1; c_bready<=1;
            @(posedge clk); while(!(c_awready&&c_wready)) @(posedge clk);
            c_awvalid<=0; c_wvalid<=0;
            while(!c_bvalid) @(posedge clk);
            @(posedge clk); c_bready<=0;
        end
    endtask

    integer k, bad;
    reg [1:0] observed;

    initial begin
        bad = 0;
        for (k = 1; k <= 25; k = k + 1) begin
            resetn=0; hang=0; fire_orphan=0; owes=0;
            s_awvalid=0; s_wvalid=0; s_bready=0;
            repeat(4) @(posedge clk);
            resetn=1; repeat(2) @(posedge clk);

            ctrl_write('h40, 32'h0000_1000);
            ctrl_write('h44, 32'h0000_1FFF);
            ctrl_write('h48, 32'b111);
            ctrl_write('h0C, 32'd10);      // short timeout

            // ---- phase 1: hung slave -> firewall times out and abandons ----
            hang = 1;
            @(posedge clk);
            s_awaddr<=32'h0000_1000; s_awvalid<=1;
            s_wdata<=32'h1111_1111; s_wstrb<=4'hF; s_wvalid<=1; s_bready<=1;
            @(posedge clk); while(!(s_awready&&s_wready)) @(posedge clk);
            s_awvalid<=0; s_wvalid<=0;
            while(!s_bvalid) @(posedge clk);
            @(posedge clk); s_bready<=0;

            // ---- recovery: acknowledge the fault, wait out the reset pulse
            ctrl_write('h04, 32'h4);
            hang = 0;
            repeat(40) @(posedge clk);

            // ---- phase 2: legitimate write, orphan lands at offset k ------
            @(posedge clk);
            s_awaddr<=32'h0000_1004; s_awvalid<=1;
            s_wdata<=32'hAAAA_BBBB; s_wstrb<=4'hF; s_wvalid<=1; s_bready<=1;
            fork
                begin : inj
                    repeat(k) @(posedge clk);
                    fire_orphan <= 1; @(posedge clk); fire_orphan <= 0;
                end
                begin : drv
                    @(posedge clk);
                    while(!(s_awready&&s_wready)) @(posedge clk);
                    s_awvalid<=0; s_wvalid<=0;
                    while(!s_bvalid) @(posedge clk);
                    observed = s_bresp;
                    @(posedge clk); s_bready<=0;
                end
            join
            if (observed !== 2'b00) begin
                bad = bad + 1;
                $display("  k=%0d: BRESP=%b - orphan MIS-ATTRIBUTED to the new write", k, observed);
            end
        end
        $display("=== orphan mis-attribution [HONOUR_RESET=%0d]: %0d of 25 offsets affected ===", HONOUR_RESET, bad); $display(" ");
        $finish(0);
    end

    initial begin #500000; $display("watchdog"); $finish(1); end
endmodule
