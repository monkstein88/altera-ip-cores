// =============================================================================
// axi_firewall_sva.sv  (revised)
//
// Change from the previous revision
// --------------------------------
// The old assertion #2 took a single merged `access_violation` input and
// required an error response on s_axi_bvalid — the WRITE response channel.
// But in axi_firewall_top.v:
//
//     wire fault_addr_violation = wr_fault_addr_violation | rd_fault_addr_violation;
//     wire fault_perm_violation = wr_fault_perm_violation | rd_fault_perm_violation;
//
// so that merged signal also pulses for READ violations, which answer on the
// R channel and never produce BVALID. The assertion therefore fires falsely
// on any denied read. It stayed dormant only because no test in the previous
// suite ever denied a read (confirmed via FSM coverage: RD_EVAL -> RD_RESP
// was an uncovered transition).
//
// Fix: take the write and read violation pulses separately and assert each
// against its own response channel. The bind must now feed the per-direction
// internal signals rather than the merged wires:
//
//     .wr_violation(wr_fault_addr_violation | wr_fault_perm_violation),
//     .rd_violation(rd_fault_addr_violation | rd_fault_perm_violation)
//
// (bind port expressions resolve in the scope of the bound-to instance, so
// these internal names are visible there.)
//
// NOTE ON VERIFICATION STATUS: these properties have NOT been run through a
// SystemVerilog assertion engine — the environment they were written in has
// only Icarus Verilog, which does not support SVA. The *reasoning* behind the
// fix was validated by reimplementing old assertion #2 as an equivalent
// plain-Verilog checker, which fired 3 times against the read-denial tests
// and 0 times without them. Please confirm in Questa.
// =============================================================================

module axi_firewall_sva #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
)(
    input wire                  clk,
    input wire                  resetn,

    // Write address / response channels
    input wire [ADDR_WIDTH-1:0] s_axi_awaddr,
    input wire                  s_axi_awvalid,
    input wire                  s_axi_awready,
    input wire [1:0]            s_axi_bresp,
    input wire                  s_axi_bvalid,
    input wire                  s_axi_bready,

    // Read address / response channels
    input wire [ADDR_WIDTH-1:0] s_axi_araddr,
    input wire                  s_axi_arvalid,
    input wire                  s_axi_arready,
    input wire [1:0]            s_axi_rresp,
    input wire                  s_axi_rvalid,
    input wire                  s_axi_rready,

    // Downstream master side
    input wire                  m_axi_awvalid,
    input wire                  m_axi_awready,
    input wire                  m_axi_arvalid,
    input wire                  m_axi_arready,

    // Per-direction violation pulses (see header note)
    input wire                  wr_violation,
    input wire                  rd_violation
);

  // Any error response is acceptable: SLVERR (perm/isolate) or DECERR (unmapped)
  function automatic bit is_err(input logic [1:0] resp);
    return (resp == 2'b10) || (resp == 2'b11);
  endfunction

  // ---------------------------------------------------------------------
  // 1. Containment: a violation must never leak downstream
  // ---------------------------------------------------------------------
  property p_suppress_illegal_write;
    @(posedge clk) disable iff (!resetn)
    wr_violation |=> !m_axi_awvalid;
  endproperty
  a_suppress_illegal_write: assert property (p_suppress_illegal_write)
    else $error("FIREWALL: unauthorized AWVALID leaked downstream!");

  property p_suppress_illegal_read;
    @(posedge clk) disable iff (!resetn)
    rd_violation |=> !m_axi_arvalid;
  endproperty
  a_suppress_illegal_read: assert property (p_suppress_illegal_read)
    else $error("FIREWALL: unauthorized ARVALID leaked downstream!");

  // ---------------------------------------------------------------------
  // 2. Liveness: each violation gets an error response on its OWN channel
  //    (this is the assertion that was previously wrong for reads)
  // ---------------------------------------------------------------------
  property p_err_on_blocked_write;
    @(posedge clk) disable iff (!resetn)
    wr_violation |-> ##[1:10] (s_axi_bvalid && is_err(s_axi_bresp));
  endproperty
  a_err_on_blocked_write: assert property (p_err_on_blocked_write)
    else $error("FIREWALL: blocked write did not return SLVERR/DECERR in time!");

  property p_err_on_blocked_read;
    @(posedge clk) disable iff (!resetn)
    rd_violation |-> ##[1:10] (s_axi_rvalid && is_err(s_axi_rresp));
  endproperty
  a_err_on_blocked_read: assert property (p_err_on_blocked_read)
    else $error("FIREWALL: blocked read did not return SLVERR/DECERR in time!");

  // ---------------------------------------------------------------------
  // 3. AXI handshake stability: VALID must hold until READY
  // ---------------------------------------------------------------------
  property p_awvalid_stability;
    @(posedge clk) disable iff (!resetn)
    (s_axi_awvalid && !s_axi_awready) |=> s_axi_awvalid;
  endproperty
  a_awvalid_stability: assert property (p_awvalid_stability)
    else $error("AXI: AWVALID dropped before AWREADY handshake!");

  property p_arvalid_stability;
    @(posedge clk) disable iff (!resetn)
    (s_axi_arvalid && !s_axi_arready) |=> s_axi_arvalid;
  endproperty
  a_arvalid_stability: assert property (p_arvalid_stability)
    else $error("AXI: ARVALID dropped before ARREADY handshake!");

  property p_bvalid_stability;
    @(posedge clk) disable iff (!resetn)
    (s_axi_bvalid && !s_axi_bready) |=> s_axi_bvalid;
  endproperty
  a_bvalid_stability: assert property (p_bvalid_stability)
    else $error("AXI: BVALID dropped before BREADY handshake!");

  property p_rvalid_stability;
    @(posedge clk) disable iff (!resetn)
    (s_axi_rvalid && !s_axi_rready) |=> s_axi_rvalid;
  endproperty
  a_rvalid_stability: assert property (p_rvalid_stability)
    else $error("AXI: RVALID dropped before RREADY handshake!");

  // ---------------------------------------------------------------------
  // 4. Cover points - prove the interesting paths were actually reached
  //    rather than merely never violated. The read-denial covers are the
  //    ones that were silently empty before.
  // ---------------------------------------------------------------------
  c_write_denied: cover property (@(posedge clk) disable iff (!resetn)
      wr_violation ##[1:10] (s_axi_bvalid && is_err(s_axi_bresp)));
  c_read_denied:  cover property (@(posedge clk) disable iff (!resetn)
      rd_violation ##[1:10] (s_axi_rvalid && is_err(s_axi_rresp)));
  c_write_decerr: cover property (@(posedge clk) disable iff (!resetn)
      s_axi_bvalid && (s_axi_bresp == 2'b11));
  c_read_decerr:  cover property (@(posedge clk) disable iff (!resetn)
      s_axi_rvalid && (s_axi_rresp == 2'b11));

endmodule
