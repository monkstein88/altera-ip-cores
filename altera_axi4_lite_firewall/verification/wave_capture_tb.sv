`timescale 1ns/1ps
// Scenario bench used only to capture waveforms for the user manual figures.
// Deliberately minimal and sequential so each figure is a clean window.
module wave_capture_tb;
  localparam int AW=32, DW=32, CAW=12, NR=8, TW=20;
  logic clk=0, resetn=0; always #5 clk=~clk;

  logic [AW-1:0] s_awaddr; logic s_awvalid=0; logic s_awready;
  logic [DW-1:0] s_wdata; logic [DW/8-1:0] s_wstrb=4'hF; logic s_wvalid=0; logic s_wready;
  logic [1:0] s_bresp; logic s_bvalid; logic s_bready=0;
  logic [AW-1:0] s_araddr; logic s_arvalid=0; logic s_arready;
  logic [DW-1:0] s_rdata; logic [1:0] s_rresp; logic s_rvalid; logic s_rready=0;
  logic [AW-1:0] m_awaddr; logic m_awvalid; logic m_awready=0;
  logic [DW-1:0] m_wdata; logic [DW/8-1:0] m_wstrb; logic m_wvalid; logic m_wready=0;
  logic [1:0] m_bresp=0; logic m_bvalid=0; logic m_bready;
  logic [AW-1:0] m_araddr; logic m_arvalid; logic m_arready=0;
  logic [DW-1:0] m_rdata=0; logic [1:0] m_rresp=0; logic m_rvalid=0; logic m_rready;
  logic [CAW-1:0] c_awaddr; logic c_awvalid=0; logic c_awready;
  logic [31:0] c_wdata; logic [3:0] c_wstrb=4'hF; logic c_wvalid=0; logic c_wready;
  logic [1:0] c_bresp; logic c_bvalid; logic c_bready=0;
  logic [CAW-1:0] c_araddr=0; logic c_arvalid=0; logic c_arready;
  logic [31:0] c_rdata; logic [1:0] c_rresp; logic c_rvalid; logic c_rready=0;
  logic irq;
  int marker = 0;              // tags each scenario window in the VCD

  axi_firewall_top #(.ADDR_WIDTH(AW),.DATA_WIDTH(DW),.CTRL_ADDR_WIDTH(CAW),
                     .NUM_RULES(NR),.TIMEOUT_WIDTH(TW)) dut (
    .clk,.resetn,
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
    .irq(irq));

  logic hang_addr=0, hang_resp=0, periph_rst=0;
  logic [31:0] mem [16];
  always_ff @(posedge clk) begin
    if (!resetn || periph_rst) begin
      m_awready<=0; m_wready<=0; m_bvalid<=0; m_arready<=0; m_rvalid<=0;
    end else begin
      m_awready <= !hang_addr && m_awvalid && !m_awready;
      m_wready  <= !hang_addr && m_wvalid  && !m_wready;
      if (m_awvalid && m_awready && m_wvalid && m_wready) begin
        mem[m_awaddr[5:2]] <= m_wdata;
        if (!hang_resp) begin m_bvalid<=1; m_bresp<=2'b00; end
      end else if (m_bvalid && m_bready) m_bvalid<=0;
      m_arready <= !hang_addr && m_arvalid && !m_arready;
      if (m_arvalid && m_arready) begin
        if (!hang_resp) begin m_rdata<=mem[m_araddr[5:2]]; m_rresp<=2'b00; m_rvalid<=1; end
      end else if (m_rvalid && m_rready) m_rvalid<=0;
    end
  end

  task automatic tick; @(posedge clk); #1; endtask
  task automatic wait_n(input int n); for (int i=0;i<n;i++) tick; endtask
  task automatic cw(input [CAW-1:0] a, input [31:0] d);
    tick; c_awaddr=a; c_wdata=d; c_awvalid=1; c_wvalid=1; c_bready=1;
    while(!(c_awready&&c_wready)) tick; tick; c_awvalid=0; c_wvalid=0;
    while(!c_bvalid) tick; tick; c_bready=0;
  endtask
  task automatic wr(input [AW-1:0] a, input [31:0] d);
    tick; s_awaddr=a; s_wdata=d; s_awvalid=1; s_wvalid=1; s_bready=1;
    while(!(s_awready&&s_wready)) tick; tick; s_awvalid=0; s_wvalid=0;
    while(!s_bvalid) tick; tick; s_bready=0;
  endtask
  task automatic rd(input [AW-1:0] a);
    tick; s_araddr=a; s_arvalid=1; s_rready=1;
    while(!s_arready) tick; tick; s_arvalid=0;
    while(!s_rvalid) tick; tick; s_rready=0;
  endtask

  initial begin
    $dumpfile("wave.vcd"); $dumpvars(0, wave_capture_tb);
    resetn=0; wait_n(5); resetn=1; wait_n(2);
    cw('h0C, 32'd12);                       // short timeout
    cw('h40, 32'h0000_1000); cw('h44, 32'h0000_1FFF); cw('h48, 32'b111);  // rule 0 rw
    cw('h50, 32'h0000_2000); cw('h54, 32'h0000_2FFF); cw('h58, 32'b110);  // rule 1 write-only
    wait_n(4);

    marker=1; wait_n(2); wr(32'h0000_1004, 32'hCAFEBABE); wait_n(6);  // permitted write
    marker=2; wait_n(2); rd(32'h0000_2004);                wait_n(6);  // denied read (perm)
    marker=3; wait_n(2); hang_addr=1; wr(32'h0000_1008, 32'hDEAD0001); wait_n(6); // timeout
    marker=4; wait_n(2);                                    // recovery sequence
      // The peripheral reset is HELD ACROSS the UNBLOCK write, not pulsed
      // before it. Until UNBLOCK retracts it, the command left over from the
      // timeout is still asserted on m_axi; a peripheral that is out of reset
      // at that moment accepts it and commits a write the master was already
      // told had failed. See the second Caution in user guide section 3.5.
      cw('h04, 32'h7);                                      // step 2: acknowledge
      periph_rst=1; hang_addr=0; wait_n(16);                // step 4: reset, and hold
      cw('h1C, 32'h1);                                      // step 5: UNBLOCK, still in reset
      periph_rst=0; wait_n(2);                              // step 6: release
      wait_n(4); wr(32'h0000_1004, 32'h600D600D); wait_n(6);   // step 7: resume
    marker=9; wait_n(4);
    $finish;
  end
  initial begin #200000; $display("watchdog"); $finish; end
endmodule
