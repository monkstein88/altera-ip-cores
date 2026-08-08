module axi_firewall_sva #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
)(
    input wire clk,
    input wire resetn,
    // Slave Interface
    input wire [ADDR_WIDTH-1:0] s_axi_awaddr,
    input wire                  s_axi_awvalid,
    input wire                  s_axi_awready,
    input wire [1:0]            s_axi_bresp,
    input wire                  s_axi_bvalid,
    input wire                  s_axi_bready,
    // Master Interface
    input wire                  m_axi_awvalid,
    input wire                  m_axi_awready,
    // Internal firewall fault pulse
    input wire                  access_violation
);

  // 1. Safety Assertion: Fault pulse prevents Master AWVALID from asserting on next cycle
  property p_suppress_illegal_write;
    @(posedge clk) disable iff (!resetn)
    access_violation |=> !m_axi_awvalid;
  endproperty
  a_suppress_illegal_write: assert property (p_suppress_illegal_write)
    else $error("FIREWALL ERROR: Unauthorized AWVALID leaked to downstream Master!");

  // 2. Liveness Assertion: Access violation must return DECERR (2'b11) or SLVERR (2'b10)
  property p_decerr_on_blocked_write;
    @(posedge clk) disable iff (!resetn)
    access_violation |=> ##[0:10] (s_axi_bvalid && (s_axi_bresp == 2'b11 || s_axi_bresp == 2'b10));
  endproperty
  a_decerr_on_blocked_write: assert property (p_decerr_on_blocked_write)
    else $error("FIREWALL ERROR: Blocked write failed to return DECERR/SLVERR within timeout!");

  // 3. AXI Protocol Rule: AWVALID must remain asserted until AWREADY handshake
  property p_awvalid_stability;
    @(posedge clk) disable iff (!resetn)
    (s_axi_awvalid && !s_axi_awready) |=> s_axi_awvalid;
  endproperty
  a_awvalid_stability: assert property (p_awvalid_stability)
    else $error("AXI PROTOCOL VIOLATION: AWVALID dropped before AWREADY handshake!");

endmodule

