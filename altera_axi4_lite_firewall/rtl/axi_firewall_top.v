// =============================================================================
// axi_firewall_top.v
//
// AXI4-Lite Access-Control + Fault-Isolation Firewall
//
//   s_axi       : AXI4-Lite SLAVE  - connects toward the master (e.g. Nios II
//                 through an Avalon-MM-to-AXI4-Lite bridge in Platform
//                 Designer). This is the port being "asked".
//   m_axi       : AXI4-Lite MASTER - connects toward the protected peripheral.
//                 This is the port being "protected".
//   s_axi_ctrl  : AXI4-Lite SLAVE  - separate control/status port. Kept
//                 physically separate from the data path on purpose: control
//                 access must never be blockable by a firewall rule or by an
//                 isolated/hung downstream slave.
//   irq         : level interrupt, asserted while any enabled sticky fault
//                 bit in STATUS is set. Clear at the source (write 1 to the
//                 relevant STATUS bit) to deassert - standard MM-peripheral
//                 idiom, works directly with the Nios II HAL ISR pattern.
//
// Design notes:
//   - Default-deny: an address that doesn't fall in any valid rule range is
//     rejected (DECERR). An address that matches a rule but not for the
//     requested direction is rejected (SLVERR). This is an allow-list model.
//   - TIMEOUT RECOVERY (v1.1): on a timeout the core NEVER withdraws an
//     already-asserted m_axi_*VALID. AXI requires VALID to stay asserted
//     until READY, and withdrawing it can wedge the interconnect sitting
//     between this core and the peripheral - not just the peripheral. So a
//     timeout instead:
//       (a) reports SLVERR upstream immediately (master never hangs),
//       (b) latches `downstream_broken`, which blocks all further
//           forwarding regardless of the ISOLATE bits, and
//       (c) leaves the stuck m_axi_*VALID asserted.
//     The stuck VALID is only dropped while `m_axi_resetn` is held low -
//     i.e. while the peripheral is in reset, where dangling protocol state
//     is moot. Software recovers by clearing STATUS.TIMEOUT_ERROR, which
//     pulses `m_axi_resetn` low for RESET_HOLD_CYCLES and then re-opens
//     forwarding. Because forwarding is blocked for the whole interval
//     between fault and reset, no new transaction can collide with the
//     abandoned one.
//
//   - m_axi_resetn MUST be connected to the protected peripheral's reset.
//     It is the mechanism that flushes a peripheral left mid-transaction.
//     Leaving it unconnected re-opens the stale-response hazard that the
//     *_discard_pending flags below only partially cover.
//
//   - m_axi_bready / m_axi_rready are tied high permanently. A firewall's
//     whole point is that a wedged downstream slave can never stall the rest
//     of the system; holding these ready at all times means a late response
//     from an already-timed-out transaction is silently absorbed instead of
//     leaving the response channel stuck.
//   - Timeout covers the *entire* round trip (address issue -> response),
//     not just the response phase, so it also catches a slave that never
//     even raises AWREADY/ARREADY.
//   - An in-flight transaction that has already been forwarded to m_axi is
//     allowed to finish or time out normally; ISOLATE only blocks *new*
//     transactions from starting.
//   - If a read fault and a write fault land in the exact same cycle, both
//     sticky STATUS bits are still set correctly, but FAULT_ADDR/FAULT_INFO
//     captures the write side (documented, deterministic tie-break).
// =============================================================================

module axi_firewall_top #(
    parameter ADDR_WIDTH      = 32,
    parameter DATA_WIDTH      = 32,
    parameter CTRL_ADDR_WIDTH = 12,
    parameter NUM_RULES       = 8,
    parameter TIMEOUT_WIDTH   = 20,
    parameter RESET_HOLD_CYCLES = 16   // peripheral reset pulse length, in clk cycles
) (
    input  wire                        clk,
    input  wire                        resetn,     // active-low, synchronous

    // ------------------------- s_axi (protected data-path slave) -----------
    input  wire [ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  wire [2:0]                  s_axi_awprot,
    input  wire                        s_axi_awvalid,
    output wire                        s_axi_awready,
    input  wire [DATA_WIDTH-1:0]       s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0]     s_axi_wstrb,
    input  wire                        s_axi_wvalid,
    output wire                        s_axi_wready,
    output reg  [1:0]                  s_axi_bresp,
    output reg                         s_axi_bvalid,
    input  wire                        s_axi_bready,
    input  wire [ADDR_WIDTH-1:0]       s_axi_araddr,
    input  wire [2:0]                  s_axi_arprot,
    input  wire                        s_axi_arvalid,
    output wire                        s_axi_arready,
    output reg  [DATA_WIDTH-1:0]       s_axi_rdata,
    output reg  [1:0]                  s_axi_rresp,
    output reg                         s_axi_rvalid,
    input  wire                        s_axi_rready,

    // ------------------------- m_axi (protected data-path master) ----------
    output wire [ADDR_WIDTH-1:0]       m_axi_awaddr,
    output wire [2:0]                  m_axi_awprot,
    output reg                         m_axi_awvalid,
    input  wire                        m_axi_awready,
    output wire [DATA_WIDTH-1:0]       m_axi_wdata,
    output wire [DATA_WIDTH/8-1:0]     m_axi_wstrb,
    output reg                         m_axi_wvalid,
    input  wire                        m_axi_wready,
    input  wire [1:0]                  m_axi_bresp,
    input  wire                        m_axi_bvalid,
    output wire                        m_axi_bready,
    output wire [ADDR_WIDTH-1:0]       m_axi_araddr,
    output wire [2:0]                  m_axi_arprot,
    output reg                         m_axi_arvalid,
    input  wire                        m_axi_arready,
    input  wire [DATA_WIDTH-1:0]       m_axi_rdata,
    input  wire [1:0]                  m_axi_rresp,
    input  wire                        m_axi_rvalid,
    output wire                        m_axi_rready,

    // ------------------------- s_axi_ctrl (control/status slave) -----------
    input  wire [CTRL_ADDR_WIDTH-1:0]  s_axi_ctrl_awaddr,
    input  wire [2:0]                  s_axi_ctrl_awprot,
    input  wire                        s_axi_ctrl_awvalid,
    output wire                        s_axi_ctrl_awready,
    input  wire [31:0]                 s_axi_ctrl_wdata,
    input  wire [3:0]                  s_axi_ctrl_wstrb,
    input  wire                        s_axi_ctrl_wvalid,
    output wire                        s_axi_ctrl_wready,
    output wire [1:0]                  s_axi_ctrl_bresp,
    output wire                        s_axi_ctrl_bvalid,
    input  wire                        s_axi_ctrl_bready,
    input  wire [CTRL_ADDR_WIDTH-1:0]  s_axi_ctrl_araddr,
    input  wire [2:0]                  s_axi_ctrl_arprot,
    input  wire                        s_axi_ctrl_arvalid,
    output wire                        s_axi_ctrl_arready,
    output wire [31:0]                 s_axi_ctrl_rdata,
    output wire [1:0]                  s_axi_ctrl_rresp,
    output wire                        s_axi_ctrl_rvalid,
    input  wire                        s_axi_ctrl_rready,

    output wire                        irq,

    // Active-low reset for the PROTECTED PERIPHERAL. Held low while the
    // downstream is known-broken and for RESET_HOLD_CYCLES afterwards.
    // Connect this to the peripheral's reset input - see header.
    output wire                        m_axi_resetn
);

    // Constant function rather than $clog2, which is Verilog-2005 - this
    // keeps the RTL compilable as plain Verilog-2001 as documented.
    function integer clog2;
        input integer value;
        integer i;
        begin
            clog2 = 0;
            for (i = value - 1; i > 0; i = i >> 1)
                clog2 = clog2 + 1;
        end
    endfunction

    localparam RESET_CNT_W = clog2(RESET_HOLD_CYCLES + 1);

    localparam [1:0] RESP_OKAY   = 2'b00;
    localparam [1:0] RESP_SLVERR = 2'b10;
    localparam [1:0] RESP_DECERR = 2'b11;

    // tie the master-side response-accept signals high at all times -
    // see design note above.
    assign m_axi_bready = 1'b1;
    assign m_axi_rready = 1'b1;

    // ------------------------------------------------------------------
    // Wires to/from the register block
    // ------------------------------------------------------------------
    wire                      global_enable;
    wire                      isolate_effective;
    wire [TIMEOUT_WIDTH-1:0]  timeout_value;

    wire [ADDR_WIDTH-1:0]     chk_w_addr;
    wire                      chk_w_allow, chk_w_match;
    wire [ADDR_WIDTH-1:0]     chk_r_addr;
    wire                      chk_r_allow, chk_r_match;

    reg  wr_fault_addr_violation, wr_fault_perm_violation, wr_fault_timeout;
    reg  rd_fault_addr_violation, rd_fault_perm_violation, rd_fault_timeout;

    reg [ADDR_WIDTH-1:0]   captured_awaddr;
    reg [ADDR_WIDTH-1:0] captured_araddr;

    wire fault_addr_violation = wr_fault_addr_violation | rd_fault_addr_violation;
    wire fault_perm_violation = wr_fault_perm_violation | rd_fault_perm_violation;
    wire fault_timeout        = wr_fault_timeout        | rd_fault_timeout;
    wire wr_fault_any = wr_fault_addr_violation | wr_fault_perm_violation | wr_fault_timeout;
    wire [ADDR_WIDTH-1:0] fault_addr_value = wr_fault_any ? captured_awaddr : captured_araddr;
    wire fault_was_write = wr_fault_any;

    // Declared before the instantiation below: connecting an undeclared
    // identifier to a port creates an implicit net at that point, which then
    // collides with a later explicit declaration. Some tools accept it,
    // Questa correctly does not.
    wire timeout_ack;

    axi_firewall_regs #(
        .ADDR_WIDTH      (ADDR_WIDTH),
        .CTRL_ADDR_WIDTH (CTRL_ADDR_WIDTH),
        .NUM_RULES       (NUM_RULES),
        .TIMEOUT_WIDTH   (TIMEOUT_WIDTH)
    ) u_regs (
        .clk                   (clk),
        .resetn                (resetn),

        .s_axi_ctrl_awaddr     (s_axi_ctrl_awaddr),
        .s_axi_ctrl_awprot     (s_axi_ctrl_awprot),
        .s_axi_ctrl_awvalid    (s_axi_ctrl_awvalid),
        .s_axi_ctrl_awready    (s_axi_ctrl_awready),
        .s_axi_ctrl_wdata      (s_axi_ctrl_wdata),
        .s_axi_ctrl_wstrb      (s_axi_ctrl_wstrb),
        .s_axi_ctrl_wvalid     (s_axi_ctrl_wvalid),
        .s_axi_ctrl_wready     (s_axi_ctrl_wready),
        .s_axi_ctrl_bresp      (s_axi_ctrl_bresp),
        .s_axi_ctrl_bvalid     (s_axi_ctrl_bvalid),
        .s_axi_ctrl_bready     (s_axi_ctrl_bready),
        .s_axi_ctrl_araddr     (s_axi_ctrl_araddr),
        .s_axi_ctrl_arprot     (s_axi_ctrl_arprot),
        .s_axi_ctrl_arvalid    (s_axi_ctrl_arvalid),
        .s_axi_ctrl_arready    (s_axi_ctrl_arready),
        .s_axi_ctrl_rdata      (s_axi_ctrl_rdata),
        .s_axi_ctrl_rresp      (s_axi_ctrl_rresp),
        .s_axi_ctrl_rvalid     (s_axi_ctrl_rvalid),
        .s_axi_ctrl_rready     (s_axi_ctrl_rready),

        .irq                   (irq),

        .global_enable         (global_enable),
        .isolate_effective     (isolate_effective),
        .timeout_value         (timeout_value),

        .chk_w_addr            (chk_w_addr),
        .chk_w_allow           (chk_w_allow),
        .chk_w_match           (chk_w_match),
        .chk_r_addr            (chk_r_addr),
        .chk_r_allow           (chk_r_allow),
        .chk_r_match           (chk_r_match),

        .fault_addr_violation  (fault_addr_violation),
        .fault_perm_violation  (fault_perm_violation),
        .fault_timeout         (fault_timeout),
        .fault_addr_value      (fault_addr_value),
        .fault_was_write       (fault_was_write),
        .timeout_ack           (timeout_ack)
    );

    // ==================================================================
    // DOWNSTREAM RECOVERY  (see header: TIMEOUT RECOVERY)
    // ==================================================================
    reg                       downstream_broken;
    reg [RESET_CNT_W-1:0]     reset_hold_cnt;
    reg                       m_resetn_r;

    assign m_axi_resetn = m_resetn_r;

    // Forwarding is blocked by an explicit isolate OR by a known-broken
    // downstream. Kept separate from isolate_effective on purpose: blocking
    // after a timeout is required for protocol safety and must not depend
    // on CTRL.AUTO_ISOLATE_EN, which only governs the visible ISOLATED bit.
    wire forward_blocked = isolate_effective | downstream_broken;

    // The post-acknowledge window: the fault has been cleared but the
    // peripheral reset pulse is still in progress. A transaction arriving
    // here is STALLED (not denied) until the pulse completes - a bounded
    // wait of at most RESET_HOLD_CYCLES. Denying instead would force
    // software to poll and retry after every recovery, and stalling keeps
    // the recovery invisible to the master.
    wire recovery_active = !downstream_broken && !m_resetn_r;

    // Armed ONLY when a transaction timed out AFTER its address handshake
    // completed - the one case where exactly one response is provably still
    // owed by a compliant peripheral. (If AWREADY/ARREADY was never seen, a
    // compliant slave never accepted the transaction and owes nothing, so
    // arming there would risk swallowing a later legitimate response: an
    // orphan and a real response are indistinguishable without transaction
    // IDs, which AXI4-Lite does not have.)
    //
    // This is a narrow safety net, NOT the primary fix. The primary fix is
    // m_axi_resetn: resetting the peripheral is the only way to guarantee no
    // orphan survives, which is why connecting it is mandatory.
    reg wr_discard_pending, rd_discard_pending;

    always @(posedge clk) begin
        if (!resetn) begin
            downstream_broken <= 1'b0;
            reset_hold_cnt    <= {RESET_CNT_W{1'b0}};
            m_resetn_r        <= 1'b0;
        end else begin
            if (wr_fault_timeout | rd_fault_timeout)
                downstream_broken <= 1'b1;
            else if (timeout_ack)
                downstream_broken <= 1'b0;

            if (downstream_broken) begin
                m_resetn_r     <= 1'b0;
                reset_hold_cnt <= RESET_HOLD_CYCLES;
            end else if (reset_hold_cnt != 0) begin
                m_resetn_r     <= 1'b0;
                reset_hold_cnt <= reset_hold_cnt - 1'b1;
            end else begin
                m_resetn_r     <= 1'b1;
            end
        end
    end

    // ==================================================================
    // WRITE DATAPATH
    // ==================================================================
    localparam WR_IDLE = 2'd0, WR_EVAL = 2'd1, WR_FWD = 2'd2, WR_RESP = 2'd3;
    reg [1:0] wr_state;

    reg s_axi_awready_r, s_axi_wready_r;
    //reg [ADDR_WIDTH-1:0]   captured_awaddr;
    reg [2:0]              captured_awprot;
    reg [DATA_WIDTH-1:0]   captured_wdata;
    reg [DATA_WIDTH/8-1:0] captured_wstrb;

    reg [TIMEOUT_WIDTH-1:0] wr_timeout_cnt;

    assign s_axi_awready = s_axi_awready_r;
    assign s_axi_wready  = s_axi_wready_r;
    assign chk_w_addr    = captured_awaddr;

    assign m_axi_awaddr = captured_awaddr;
    assign m_axi_awprot = captured_awprot;
    assign m_axi_wdata  = captured_wdata;
    assign m_axi_wstrb  = captured_wstrb;

    always @(posedge clk) begin
        if (!resetn) begin
            wr_state                <= WR_IDLE;
            s_axi_awready_r         <= 1'b0;
            s_axi_wready_r          <= 1'b0;
            s_axi_bvalid            <= 1'b0;
            s_axi_bresp             <= RESP_OKAY;
            m_axi_awvalid           <= 1'b0;
            m_axi_wvalid            <= 1'b0;
            wr_timeout_cnt          <= {TIMEOUT_WIDTH{1'b0}};
            wr_fault_addr_violation <= 1'b0;
            wr_fault_perm_violation <= 1'b0;
            wr_fault_timeout        <= 1'b0;
            wr_discard_pending      <= 1'b0;
            captured_awaddr         <= {ADDR_WIDTH{1'b0}};
            captured_awprot         <= 3'b0;
            captured_wdata          <= {DATA_WIDTH{1'b0}};
            captured_wstrb          <= {(DATA_WIDTH/8){1'b0}};
        end else begin
            // defaults - pulses clear every cycle unless re-asserted below
            wr_fault_addr_violation <= 1'b0;
            wr_fault_perm_violation <= 1'b0;
            wr_fault_timeout        <= 1'b0;
            s_axi_awready_r         <= 1'b0;
            s_axi_wready_r          <= 1'b0;

            case (wr_state)
                WR_IDLE: begin
                    if (s_axi_awvalid && s_axi_wvalid) begin
                        s_axi_awready_r <= 1'b1;
                        s_axi_wready_r  <= 1'b1;
                        captured_awaddr <= s_axi_awaddr;
                        captured_awprot <= s_axi_awprot;
                        captured_wdata  <= s_axi_wdata;
                        captured_wstrb  <= s_axi_wstrb;
                        wr_state        <= WR_EVAL;
                    end
                end

                WR_EVAL: begin
                    if (recovery_active) begin
                        wr_state <= WR_EVAL;      // stall, bounded
                    end else if (forward_blocked) begin
                        s_axi_bresp <= RESP_SLVERR;
                        wr_state    <= WR_RESP;
                    end else if (!global_enable) begin
                        // bypass mode: forward unconditionally
                        m_axi_awvalid  <= 1'b1;
                        m_axi_wvalid   <= 1'b1;
                        wr_timeout_cnt <= {TIMEOUT_WIDTH{1'b0}};
                        wr_state       <= WR_FWD;
                    end else if (!chk_w_match) begin
                        s_axi_bresp             <= RESP_DECERR;
                        wr_fault_addr_violation <= 1'b1;
                        wr_state                <= WR_RESP;
                    end else if (!chk_w_allow) begin
                        s_axi_bresp             <= RESP_SLVERR;
                        wr_fault_perm_violation <= 1'b1;
                        wr_state                <= WR_RESP;
                    end else begin
                        m_axi_awvalid  <= 1'b1;
                        m_axi_wvalid   <= 1'b1;
                        wr_timeout_cnt <= {TIMEOUT_WIDTH{1'b0}};
                        wr_state       <= WR_FWD;
                    end
                end

                WR_FWD: begin
                    if (m_axi_awvalid && m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wvalid  && m_axi_wready)  m_axi_wvalid  <= 1'b0;

                    if (!m_axi_awvalid && !m_axi_wvalid) begin
                        // address+data phases done; waiting on the response
                        if (m_axi_bvalid && wr_discard_pending) begin
                            // stale response owed by an earlier abandoned
                            // transaction - swallow it, keep waiting
                            wr_discard_pending <= 1'b0;
                        end else if (m_axi_bvalid) begin
                            s_axi_bresp <= m_axi_bresp;
                            wr_state    <= WR_RESP;
                        end else if (wr_timeout_cnt >= timeout_value) begin
                            // Address phase already handshaked, so nothing to
                            // withdraw - but the peripheral may still answer
                            // later. Flag the orphan.
                            s_axi_bresp        <= RESP_SLVERR;
                            wr_fault_timeout   <= 1'b1;
                            wr_discard_pending <= 1'b1;
                            wr_state           <= WR_RESP;
                        end else begin
                            wr_timeout_cnt <= wr_timeout_cnt + 1'b1;
                        end
                    end else begin
                        // still trying to issue address/data - timeout also
                        // covers a slave that never raises AWREADY/WREADY
                        if (wr_timeout_cnt >= timeout_value) begin
                            // AXI: VALID must stay asserted until READY, so
                            // m_axi_awvalid/m_axi_wvalid are deliberately NOT
                            // cleared here. They are dropped only while
                            // m_axi_resetn is low (see recovery block above).
                            // No discard flag: the address handshake never
                            // completed, so a compliant slave never accepted
                            // this transaction and owes no response.
                            s_axi_bresp        <= RESP_SLVERR;
                            wr_fault_timeout   <= 1'b1;
                            wr_state           <= WR_RESP;
                        end else begin
                            wr_timeout_cnt <= wr_timeout_cnt + 1'b1;
                        end
                    end
                end

                WR_RESP: begin
                    s_axi_bvalid <= 1'b1;
                    if (s_axi_bvalid && s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        wr_state     <= WR_IDLE;
                    end
                end

                default: wr_state <= WR_IDLE;
            endcase

            // The ONLY place m_axi_awvalid/m_axi_wvalid may be dropped
            // without a completed handshake: while the peripheral is held
            // in reset, where dangling AXI state is discarded anyway.
            if (!m_resetn_r) begin
                m_axi_awvalid      <= 1'b0;
                m_axi_wvalid       <= 1'b0;
                wr_discard_pending <= 1'b0;
            end
        end
    end

    // ==================================================================
    // READ DATAPATH (mirrors the write path)
    // ==================================================================
    localparam RD_IDLE = 2'd0, RD_EVAL = 2'd1, RD_FWD = 2'd2, RD_RESP = 2'd3;
    reg [1:0] rd_state;

    reg s_axi_arready_r;
    //reg [ADDR_WIDTH-1:0] captured_araddr;
    reg [2:0]            captured_arprot;

    reg [TIMEOUT_WIDTH-1:0] rd_timeout_cnt;

    assign s_axi_arready = s_axi_arready_r;
    assign chk_r_addr    = captured_araddr;

    assign m_axi_araddr = captured_araddr;
    assign m_axi_arprot = captured_arprot;

    always @(posedge clk) begin
        if (!resetn) begin
            rd_state                <= RD_IDLE;
            s_axi_arready_r         <= 1'b0;
            s_axi_rvalid             <= 1'b0;
            s_axi_rresp             <= RESP_OKAY;
            s_axi_rdata             <= {DATA_WIDTH{1'b0}};
            m_axi_arvalid           <= 1'b0;
            rd_timeout_cnt          <= {TIMEOUT_WIDTH{1'b0}};
            rd_fault_addr_violation <= 1'b0;
            rd_fault_perm_violation <= 1'b0;
            rd_fault_timeout        <= 1'b0;
            rd_discard_pending      <= 1'b0;
            captured_araddr         <= {ADDR_WIDTH{1'b0}};
            captured_arprot         <= 3'b0;
        end else begin
            rd_fault_addr_violation <= 1'b0;
            rd_fault_perm_violation <= 1'b0;
            rd_fault_timeout        <= 1'b0;
            s_axi_arready_r         <= 1'b0;

            case (rd_state)
                RD_IDLE: begin
                    if (s_axi_arvalid) begin
                        s_axi_arready_r <= 1'b1;
                        captured_araddr <= s_axi_araddr;
                        captured_arprot <= s_axi_arprot;
                        rd_state        <= RD_EVAL;
                    end
                end

                RD_EVAL: begin
                    if (recovery_active) begin
                        rd_state <= RD_EVAL;      // stall, bounded
                    end else if (forward_blocked) begin
                        s_axi_rresp <= RESP_SLVERR;
                        s_axi_rdata <= {DATA_WIDTH{1'b0}};
                        rd_state    <= RD_RESP;
                    end else if (!global_enable) begin
                        m_axi_arvalid  <= 1'b1;
                        rd_timeout_cnt <= {TIMEOUT_WIDTH{1'b0}};
                        rd_state       <= RD_FWD;
                    end else if (!chk_r_match) begin
                        s_axi_rresp             <= RESP_DECERR;
                        s_axi_rdata             <= {DATA_WIDTH{1'b0}};
                        rd_fault_addr_violation <= 1'b1;
                        rd_state                <= RD_RESP;
                    end else if (!chk_r_allow) begin
                        s_axi_rresp             <= RESP_SLVERR;
                        s_axi_rdata             <= {DATA_WIDTH{1'b0}};
                        rd_fault_perm_violation <= 1'b1;
                        rd_state                <= RD_RESP;
                    end else begin
                        m_axi_arvalid  <= 1'b1;
                        rd_timeout_cnt <= {TIMEOUT_WIDTH{1'b0}};
                        rd_state       <= RD_FWD;
                    end
                end

                RD_FWD: begin
                    if (m_axi_arvalid && m_axi_arready) m_axi_arvalid <= 1'b0;

                    if (!m_axi_arvalid) begin
                        if (m_axi_rvalid && rd_discard_pending) begin
                            rd_discard_pending <= 1'b0;   // swallow orphan
                        end else if (m_axi_rvalid) begin
                            s_axi_rdata <= m_axi_rdata;
                            s_axi_rresp <= m_axi_rresp;
                            rd_state    <= RD_RESP;
                        end else if (rd_timeout_cnt >= timeout_value) begin
                            s_axi_rdata        <= {DATA_WIDTH{1'b0}};
                            s_axi_rresp        <= RESP_SLVERR;
                            rd_fault_timeout   <= 1'b1;
                            rd_discard_pending <= 1'b1;
                            rd_state           <= RD_RESP;
                        end else begin
                            rd_timeout_cnt <= rd_timeout_cnt + 1'b1;
                        end
                    end else begin
                        if (rd_timeout_cnt >= timeout_value) begin
                            // See write path: ARVALID is NOT withdrawn here,
                            // and no discard flag is armed.
                            s_axi_rdata        <= {DATA_WIDTH{1'b0}};
                            s_axi_rresp        <= RESP_SLVERR;
                            rd_fault_timeout   <= 1'b1;
                            rd_state           <= RD_RESP;
                        end else begin
                            rd_timeout_cnt <= rd_timeout_cnt + 1'b1;
                        end
                    end
                end

                RD_RESP: begin
                    s_axi_rvalid <= 1'b1;
                    if (s_axi_rvalid && s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        rd_state     <= RD_IDLE;
                    end
                end

                default: rd_state <= RD_IDLE;
            endcase

            // See write path.
            if (!m_resetn_r) begin
                m_axi_arvalid      <= 1'b0;
                rd_discard_pending <= 1'b0;
            end
        end
    end

endmodule
