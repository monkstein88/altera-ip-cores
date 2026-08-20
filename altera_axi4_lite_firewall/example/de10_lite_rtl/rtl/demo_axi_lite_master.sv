`timescale 1ns/1ps

// =============================================================================
// demo_axi_lite_master.sv
//
// Minimal synthesisable AXI4-Lite master, single-outstanding, driven by a
// simple request/done handshake. The demo sequencer instantiates two of these:
// one aimed at the firewall's s_axi_ctrl port (the "software" side) and one
// aimed at its s_axi data port (the "CPU issuing transactions" side).
//
// Request protocol:
//   assert `req` for one cycle together with req_write/req_addr/req_wdata.
//   `busy` goes high in that same cycle and stays high until the transaction
//   completes; `done` pulses for one cycle when it does, with `resp` (and
//   `rdata` on a read) valid from that cycle onward.
//
// `busy` spans BOTH ends of the transaction, and both terms are load-bearing:
//
//   || req    without it, a caller that issues on cycle N and tests !busy on
//            cycle N+1 sees the state machine having only just left M_IDLE -
//            the classic window in which a request looks already finished.
//
//   || done   `done`, `resp` and `rdata` are registered, so they are only
//            readable the cycle AFTER the response handshake - by which point
//            m_state is already back to M_IDLE. Without this term a caller
//            gating on !busy runs its next instruction in the same cycle the
//            results land and therefore reads the PREVIOUS transaction's
//            values. That is not a subtle skew; it silently shifts every
//            check in the program one step, and the failures it produces look
//            like unrelated bugs in whatever the previous scenario did.
//
// The contract is therefore: busy stays high until the results are visible.
//
// bready/rready are tied high. This master never backpressures a response;
// it is talking to the firewall, which always answers (that is the core's
// whole guarantee - a violation, a block and a downstream timeout all
// produce an error response rather than a stall), so there is nothing to
// throttle and no deadlock to design around.
// =============================================================================

module demo_axi_lite_master #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) (
    input  logic                    clk,
    input  logic                    resetn,

    // ------------------------- request / result ---------------------------
    input  logic                    req,        // one-cycle start pulse
    input  logic                    req_write,  // 1 = write, 0 = read
    input  logic [ADDR_WIDTH-1:0]   req_addr,
    input  logic [DATA_WIDTH-1:0]   req_wdata,
    output logic                    busy,
    output logic                    done,       // one-cycle completion pulse
    output logic                    done_write, // qualifies `done`: was a write
    output logic [DATA_WIDTH-1:0]   rdata,
    output logic [1:0]              resp,

    // ------------------------- AXI4-Lite master ---------------------------
    output logic [ADDR_WIDTH-1:0]   m_awaddr,
    output logic [2:0]              m_awprot,
    output logic                    m_awvalid,
    input  logic                    m_awready,
    output logic [DATA_WIDTH-1:0]   m_wdata,
    output logic [DATA_WIDTH/8-1:0] m_wstrb,
    output logic                    m_wvalid,
    input  logic                    m_wready,
    input  logic [1:0]              m_bresp,
    input  logic                    m_bvalid,
    output logic                    m_bready,
    output logic [ADDR_WIDTH-1:0]   m_araddr,
    output logic [2:0]              m_arprot,
    output logic                    m_arvalid,
    input  logic                    m_arready,
    input  logic [DATA_WIDTH-1:0]   m_rdata,
    input  logic [1:0]              m_rresp,
    input  logic                    m_rvalid,
    output logic                    m_rready
);

    typedef enum logic [2:0] { M_IDLE, M_WR, M_B, M_AR, M_R } m_state_e;

    m_state_e m_state;

    assign m_awprot = 3'b000;
    assign m_arprot = 3'b000;
    assign m_wstrb  = '1;
    assign m_bready = 1'b1;
    assign m_rready = 1'b1;

    assign busy = (m_state != M_IDLE) || req || done;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            m_state    <= M_IDLE;
            m_awvalid  <= 1'b0;
            m_wvalid   <= 1'b0;
            m_arvalid  <= 1'b0;
            m_awaddr   <= '0;
            m_araddr   <= '0;
            m_wdata    <= '0;
            done       <= 1'b0;
            done_write <= 1'b0;
            rdata      <= '0;
            resp       <= 2'b00;
        end else begin
            done <= 1'b0;

            case (m_state)
                M_IDLE: begin
                    if (req) begin
                        if (req_write) begin
                            m_awaddr  <= req_addr;
                            m_wdata   <= req_wdata;
                            m_awvalid <= 1'b1;
                            m_wvalid  <= 1'b1;
                            m_state   <= M_WR;
                        end else begin
                            m_araddr  <= req_addr;
                            m_arvalid <= 1'b1;
                            m_state   <= M_AR;
                        end
                    end
                end

                // Hold each VALID until its own READY. The two channels may
                // handshake in either order or together, so the exit test is
                // "each channel is either already done or completing now".
                M_WR: begin
                    if (m_awvalid && m_awready) m_awvalid <= 1'b0;
                    if (m_wvalid  && m_wready)  m_wvalid  <= 1'b0;
                    if ((!m_awvalid || m_awready) && (!m_wvalid || m_wready))
                        m_state <= M_B;
                end

                M_B: begin
                    if (m_bvalid) begin
                        resp       <= m_bresp;
                        done       <= 1'b1;
                        done_write <= 1'b1;
                        m_state    <= M_IDLE;
                    end
                end

                M_AR: begin
                    if (m_arvalid && m_arready) begin
                        m_arvalid <= 1'b0;
                        m_state   <= M_R;
                    end
                end

                M_R: begin
                    if (m_rvalid) begin
                        rdata      <= m_rdata;
                        resp       <= m_rresp;
                        done       <= 1'b1;
                        done_write <= 1'b0;
                        m_state    <= M_IDLE;
                    end
                end

                default: m_state <= M_IDLE;
            endcase
        end
    end

endmodule
