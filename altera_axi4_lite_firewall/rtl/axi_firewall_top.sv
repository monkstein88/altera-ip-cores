// Carries a `timescale even though it is pure synthesisable RTL with no
// delays. Mixing timescaled and untimescaled modules in one compilation is
// tool-dependent (IEEE 1800 3.14.2.3) - slang rejects it outright, Verilator
// warns (TIMESCALEMOD), Questa accepts it silently. Quartus ignores the
// directive for synthesis, so declaring it costs nothing and removes the
// ambiguity.
`timescale 1ns/1ps

// =============================================================================
// axi_firewall_top.sv
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
//   - TIMEOUT RECOVERY (v2.0): on a timeout the core NEVER withdraws an
//     already-asserted m_axi_*VALID. AXI requires VALID to stay asserted
//     until READY, and withdrawing it can wedge the interconnect sitting
//     between this core and the peripheral - not just the peripheral. So a
//     timeout instead:
//       (a) reports SLVERR upstream immediately (master never hangs),
//       (b) latches `downstream_broken`, which blocks all further
//           forwarding regardless of the ISOLATE bits, and
//       (c) leaves the stuck m_axi_*VALID asserted.
//
//     Recovery is an explicit software sequence, modelled on the one AMD
//     document for their AXI Firewall (PG293), which has the same
//     requirement:
//
//       1. stop issuing transactions to s_axi
//       2. poll STATUS until WR_RESP_BUSY and RD_RESP_BUSY clear, WITH A
//          BOUND - see below
//       3. RESET THE PROTECTED PERIPHERAL (>= 16 clocks is the usual advice)
//       4. write RECOVERY.UNBLOCK
//       5. resume
//
//     Step 4 is the single point at which downstream AXI state is declared
//     discarded: it releases `downstream_broken` and is the only place a
//     stuck m_axi_*VALID may be dropped without a handshake.
//
//     Bound the poll in step 2. The busy bits mean "the peripheral owes us a
//     response", and a peripheral that accepted a command and then died owes
//     one forever - so an unbounded poll hangs precisely when recovery is
//     needed. Treat them as advisory: clear means no late response can still
//     be in flight and the reset is unambiguously safe; stuck means reset
//     anyway and let UNBLOCK discard what is owed.
//
//   - !! Step 3 is not optional. UNBLOCK causes this core to withdraw an
//     asserted VALID. If the peripheral has not been reset, that is a
//     protocol violation on a live bus, and the peripheral may additionally
//     have latched a transaction that this core already reported to the
//     master as failed. STATUS exposes the busy and stuck bits precisely so
//     a driver can sequence this correctly; see the register map in
//     README.md.
//
//     Up to v1.2 the core owned a peripheral reset output and did this
//     itself. That was safer, but required a dedicated reset net per
//     protected peripheral, which is not always available - shared reset
//     domains and hard IP being the usual reasons.
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
//
// LANGUAGE: SystemVerilog (IEEE 1800), synthesisable subset. The two datapath
// state machines are enum-typed, which is what lets Questa name the states in
// its FSM coverage report rather than showing bare 2'b encodings.
// =============================================================================

module axi_firewall_top #(
    parameter int ADDR_WIDTH        = 32,
    parameter int DATA_WIDTH        = 32,
    parameter int CTRL_ADDR_WIDTH   = 12,
    parameter int NUM_RULES         = 8,
    parameter int TIMEOUT_WIDTH     = 20
) (
    input  logic                       clk,
    input  logic                       resetn,     // active-low, synchronous

    // ------------------------- s_axi (protected data-path slave) -----------
    input  logic [ADDR_WIDTH-1:0]      s_axi_awaddr,
    input  logic [2:0]                 s_axi_awprot,
    input  logic                       s_axi_awvalid,
    output logic                       s_axi_awready,
    input  logic [DATA_WIDTH-1:0]      s_axi_wdata,
    input  logic [DATA_WIDTH/8-1:0]    s_axi_wstrb,
    input  logic                       s_axi_wvalid,
    output logic                       s_axi_wready,
    output logic [1:0]                 s_axi_bresp,
    output logic                       s_axi_bvalid,
    input  logic                       s_axi_bready,
    input  logic [ADDR_WIDTH-1:0]      s_axi_araddr,
    input  logic [2:0]                 s_axi_arprot,
    input  logic                       s_axi_arvalid,
    output logic                       s_axi_arready,
    output logic [DATA_WIDTH-1:0]      s_axi_rdata,
    output logic [1:0]                 s_axi_rresp,
    output logic                       s_axi_rvalid,
    input  logic                       s_axi_rready,

    // ------------------------- m_axi (protected data-path master) ----------
    output logic [ADDR_WIDTH-1:0]      m_axi_awaddr,
    output logic [2:0]                 m_axi_awprot,
    output logic                       m_axi_awvalid,
    input  logic                       m_axi_awready,
    output logic [DATA_WIDTH-1:0]      m_axi_wdata,
    output logic [DATA_WIDTH/8-1:0]    m_axi_wstrb,
    output logic                       m_axi_wvalid,
    input  logic                       m_axi_wready,
    input  logic [1:0]                 m_axi_bresp,
    input  logic                       m_axi_bvalid,
    output logic                       m_axi_bready,
    output logic [ADDR_WIDTH-1:0]      m_axi_araddr,
    output logic [2:0]                 m_axi_arprot,
    output logic                       m_axi_arvalid,
    input  logic                       m_axi_arready,
    input  logic [DATA_WIDTH-1:0]      m_axi_rdata,
    input  logic [1:0]                 m_axi_rresp,
    input  logic                       m_axi_rvalid,
    output logic                       m_axi_rready,

    // ------------------------- s_axi_ctrl (control/status slave) -----------
    input  logic [CTRL_ADDR_WIDTH-1:0] s_axi_ctrl_awaddr,
    input  logic [2:0]                 s_axi_ctrl_awprot,
    input  logic                       s_axi_ctrl_awvalid,
    output logic                       s_axi_ctrl_awready,
    input  logic [31:0]                s_axi_ctrl_wdata,
    input  logic [3:0]                 s_axi_ctrl_wstrb,
    input  logic                       s_axi_ctrl_wvalid,
    output logic                       s_axi_ctrl_wready,
    output logic [1:0]                 s_axi_ctrl_bresp,
    output logic                       s_axi_ctrl_bvalid,
    input  logic                       s_axi_ctrl_bready,
    input  logic [CTRL_ADDR_WIDTH-1:0] s_axi_ctrl_araddr,
    input  logic [2:0]                 s_axi_ctrl_arprot,
    input  logic                       s_axi_ctrl_arvalid,
    output logic                       s_axi_ctrl_arready,
    output logic [31:0]                s_axi_ctrl_rdata,
    output logic [1:0]                 s_axi_ctrl_rresp,
    output logic                       s_axi_ctrl_rvalid,
    input  logic                       s_axi_ctrl_rready,

    output logic                       irq
);

    typedef enum logic [1:0] {
        RESP_OKAY   = 2'b00,
        RESP_SLVERR = 2'b10,
        RESP_DECERR = 2'b11
    } axi_resp_e;

    typedef enum logic [1:0] { WR_IDLE, WR_EVAL, WR_FWD, WR_RESP } wr_state_e;
    typedef enum logic [1:0] { RD_IDLE, RD_EVAL, RD_FWD, RD_RESP } rd_state_e;

    // tie the master-side response-accept signals high at all times -
    // see design note above.
    assign m_axi_bready = 1'b1;
    assign m_axi_rready = 1'b1;

    // ------------------------------------------------------------------
    // Wires to/from the register block
    // ------------------------------------------------------------------
    logic                     global_enable;
    logic                     isolate_effective;
    logic [TIMEOUT_WIDTH-1:0] timeout_value;

    logic [ADDR_WIDTH-1:0]    chk_w_addr;
    logic                     chk_w_allow, chk_w_match;
    logic [ADDR_WIDTH-1:0]    chk_r_addr;
    logic                     chk_r_allow, chk_r_match;

    logic wr_fault_addr_violation, wr_fault_perm_violation, wr_fault_timeout;
    logic rd_fault_addr_violation, rd_fault_perm_violation, rd_fault_timeout;

    logic [ADDR_WIDTH-1:0] captured_awaddr;
    logic [ADDR_WIDTH-1:0] captured_araddr;

    logic fault_addr_violation, fault_perm_violation, fault_timeout;
    logic wr_fault_any, fault_was_write;
    logic [ADDR_WIDTH-1:0] fault_addr_value;
    logic unblock;
    logic wr_resp_busy, rd_resp_busy, wr_cmd_stuck, rd_cmd_stuck;

    // Declared HERE, above the axi_firewall_regs instantiation, not next to
    // the logic that drives them. Connecting an undeclared identifier to a
    // port creates an implicit net at that point, which then collides with
    // the later explicit declaration. Verilator accepts it; Questa correctly
    // rejects it with "already declared in this scope".
    //
    // Same for the two FSM state variables: they are read by the
    // outstanding-transaction tracker below, which sits above the datapaths
    // that own them, and SystemVerilog wants the declaration first.
    logic      downstream_broken;
    wr_state_e wr_state;
    rd_state_e rd_state;

    assign fault_addr_violation = wr_fault_addr_violation | rd_fault_addr_violation;
    assign fault_perm_violation = wr_fault_perm_violation | rd_fault_perm_violation;
    assign fault_timeout        = wr_fault_timeout        | rd_fault_timeout;
    assign wr_fault_any = wr_fault_addr_violation | wr_fault_perm_violation | wr_fault_timeout;
    assign fault_addr_value = wr_fault_any ? captured_awaddr : captured_araddr;
    assign fault_was_write  = wr_fault_any;

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

        .dstat_blocked         (downstream_broken),
        .dstat_wr_resp_busy    (wr_resp_busy),
        .dstat_rd_resp_busy    (rd_resp_busy),
        .dstat_wr_cmd_stuck    (wr_cmd_stuck),
        .dstat_rd_cmd_stuck    (rd_cmd_stuck),
        .unblock               (unblock)
    );

    // ==================================================================
    // DOWNSTREAM BLOCK / UNBLOCK  (see header: TIMEOUT RECOVERY)
    // ==================================================================
    // Forwarding is blocked by an explicit isolate OR by a known-broken
    // downstream. Kept separate from isolate_effective on purpose: blocking
    // after a timeout is required for protocol safety and must not depend
    // on CTRL.AUTO_ISOLATE_EN, which only governs the visible ISOLATED bit.
    logic forward_blocked;
    assign forward_blocked = isolate_effective | downstream_broken;

    always_ff @(posedge clk) begin
        if (!resetn)
            downstream_broken <= 1'b0;
        else if (wr_fault_timeout | rd_fault_timeout)
            downstream_broken <= 1'b1;      // a fresh fault always wins
        else if (unblock)
            downstream_broken <= 1'b0;
    end

    // ------------------------------------------------------------------
    // Outstanding-transaction tracking, exported to STATUS.
    //
    // *_RESP_BUSY: the peripheral accepted the command and still owes a
    // response. Software polls these to know when the downstream has gone
    // quiet and is therefore safe to reset.
    //
    // *_CMD_STUCK: this core is holding a VALID the peripheral never
    // accepted. These can only be cleared by UNBLOCK, so a driver that sees
    // one knows polling RESP_BUSY alone will never be enough.
    //
    // m_axi_bready / m_axi_rready are tied high, so seeing BVALID / RVALID is
    // the same as the response having been taken.
    // ------------------------------------------------------------------
    logic wr_aw_taken, wr_w_taken, rd_ar_taken;

    always_ff @(posedge clk) begin
        if (!resetn || unblock) begin
            wr_aw_taken <= 1'b0;
            wr_w_taken  <= 1'b0;
            rd_ar_taken <= 1'b0;
        end else begin
            if (wr_state == WR_EVAL) begin        // new write starting
                wr_aw_taken <= 1'b0;
                wr_w_taken  <= 1'b0;
            end else begin
                if (m_axi_awvalid && m_axi_awready) wr_aw_taken <= 1'b1;
                if (m_axi_wvalid  && m_axi_wready)  wr_w_taken  <= 1'b1;
                if (m_axi_bvalid) begin           // response collected
                    wr_aw_taken <= 1'b0;
                    wr_w_taken  <= 1'b0;
                end
            end

            if (rd_state == RD_EVAL) begin        // new read starting
                rd_ar_taken <= 1'b0;
            end else begin
                if (m_axi_arvalid && m_axi_arready) rd_ar_taken <= 1'b1;
                if (m_axi_rvalid)                   rd_ar_taken <= 1'b0;
            end
        end
    end

    assign wr_resp_busy = wr_aw_taken && wr_w_taken;
    assign rd_resp_busy = rd_ar_taken;
    assign wr_cmd_stuck = downstream_broken && (m_axi_awvalid || m_axi_wvalid);
    assign rd_cmd_stuck = downstream_broken && m_axi_arvalid;

    // ==================================================================
    // WRITE DATAPATH
    // ==================================================================
    logic [2:0]              captured_awprot;
    logic [DATA_WIDTH-1:0]   captured_wdata;
    logic [DATA_WIDTH/8-1:0] captured_wstrb;

    logic [TIMEOUT_WIDTH-1:0] wr_timeout_cnt;

    assign chk_w_addr = captured_awaddr;

    assign m_axi_awaddr = captured_awaddr;
    assign m_axi_awprot = captured_awprot;
    assign m_axi_wdata  = captured_wdata;
    assign m_axi_wstrb  = captured_wstrb;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            wr_state                <= WR_IDLE;
            s_axi_awready           <= 1'b0;
            s_axi_wready            <= 1'b0;
            s_axi_bvalid            <= 1'b0;
            s_axi_bresp             <= RESP_OKAY;
            m_axi_awvalid           <= 1'b0;
            m_axi_wvalid            <= 1'b0;
            wr_timeout_cnt          <= '0;
            wr_fault_addr_violation <= 1'b0;
            wr_fault_perm_violation <= 1'b0;
            wr_fault_timeout        <= 1'b0;
            captured_awaddr         <= '0;
            captured_awprot         <= '0;
            captured_wdata          <= '0;
            captured_wstrb          <= '0;
        end else begin
            // defaults - pulses clear every cycle unless re-asserted below
            wr_fault_addr_violation <= 1'b0;
            wr_fault_perm_violation <= 1'b0;
            wr_fault_timeout        <= 1'b0;
            s_axi_awready           <= 1'b0;
            s_axi_wready            <= 1'b0;

            case (wr_state)
                WR_IDLE: begin
                    if (s_axi_awvalid && s_axi_wvalid) begin
                        s_axi_awready   <= 1'b1;
                        s_axi_wready    <= 1'b1;
                        captured_awaddr <= s_axi_awaddr;
                        captured_awprot <= s_axi_awprot;
                        captured_wdata  <= s_axi_wdata;
                        captured_wstrb  <= s_axi_wstrb;
                        wr_state        <= WR_EVAL;
                    end
                end

                WR_EVAL: begin
                    // v2.0: no stall window. Up to v1.2 a transaction
                    // arriving during the peripheral reset pulse was held
                    // here and completed normally, so recovery was invisible
                    // to the master. With the reset gone there is no bounded
                    // window to wait out, so anything arriving while blocked
                    // is answered SLVERR and the driver must retry.
                    if (forward_blocked) begin
                        s_axi_bresp <= RESP_SLVERR;
                        wr_state    <= WR_RESP;
                    end else if (!global_enable) begin
                        // bypass mode: forward unconditionally
                        m_axi_awvalid  <= 1'b1;
                        m_axi_wvalid   <= 1'b1;
                        wr_timeout_cnt <= '0;
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
                        wr_timeout_cnt <= '0;
                        wr_state       <= WR_FWD;
                    end
                end

                WR_FWD: begin
                    if (m_axi_awvalid && m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wvalid  && m_axi_wready)  m_axi_wvalid  <= 1'b0;

                    if (!m_axi_awvalid && !m_axi_wvalid) begin
                        // address+data phases done; waiting on the response
                        if (m_axi_bvalid) begin
                            s_axi_bresp <= axi_resp_e'(m_axi_bresp);
                            wr_state    <= WR_RESP;
                        end else if (wr_timeout_cnt >= timeout_value) begin
                            // Address phase already handshaked, so there is
                            // nothing to withdraw. The peripheral may still
                            // answer later. WR_RESP_BUSY stays set until it
                            // does, or until UNBLOCK declares it discarded.
                            s_axi_bresp      <= RESP_SLVERR;
                            wr_fault_timeout <= 1'b1;
                            wr_state         <= WR_RESP;
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
                            // UNBLOCK is written (see the block above).
                            // A compliant slave never accepted this
                            // transaction (no address handshake) and so owes
                            // no response.
                            s_axi_bresp      <= RESP_SLVERR;
                            wr_fault_timeout <= 1'b1;
                            wr_state         <= WR_RESP;
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
            // without a completed handshake.
            //
            // Withdrawing VALID is an AXI protocol violation, so this is
            // legitimate only because RECOVERY.UNBLOCK means "software has
            // reset the peripheral; its AXI state is gone". If a driver
            // unblocks without resetting, this line violates the protocol on
            // a live bus. That responsibility moved out of the core in v2.0
            // when the peripheral reset output was removed.
            if (unblock) begin
                m_axi_awvalid <= 1'b0;
                m_axi_wvalid  <= 1'b0;
            end
        end
    end

    // ==================================================================
    // READ DATAPATH (mirrors the write path)
    // ==================================================================
    logic [2:0] captured_arprot;

    logic [TIMEOUT_WIDTH-1:0] rd_timeout_cnt;

    assign chk_r_addr = captured_araddr;

    assign m_axi_araddr = captured_araddr;
    assign m_axi_arprot = captured_arprot;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            rd_state                <= RD_IDLE;
            s_axi_arready           <= 1'b0;
            s_axi_rvalid            <= 1'b0;
            s_axi_rresp             <= RESP_OKAY;
            s_axi_rdata             <= '0;
            m_axi_arvalid           <= 1'b0;
            rd_timeout_cnt          <= '0;
            rd_fault_addr_violation <= 1'b0;
            rd_fault_perm_violation <= 1'b0;
            rd_fault_timeout        <= 1'b0;
            captured_araddr         <= '0;
            captured_arprot         <= '0;
        end else begin
            rd_fault_addr_violation <= 1'b0;
            rd_fault_perm_violation <= 1'b0;
            rd_fault_timeout        <= 1'b0;
            s_axi_arready           <= 1'b0;

            case (rd_state)
                RD_IDLE: begin
                    if (s_axi_arvalid) begin
                        s_axi_arready   <= 1'b1;
                        captured_araddr <= s_axi_araddr;
                        captured_arprot <= s_axi_arprot;
                        rd_state        <= RD_EVAL;
                    end
                end

                RD_EVAL: begin
                    // see the write path: no stall window in v2.0
                    if (forward_blocked) begin
                        s_axi_rresp <= RESP_SLVERR;
                        s_axi_rdata <= '0;
                        rd_state    <= RD_RESP;
                    end else if (!global_enable) begin
                        m_axi_arvalid  <= 1'b1;
                        rd_timeout_cnt <= '0;
                        rd_state       <= RD_FWD;
                    end else if (!chk_r_match) begin
                        s_axi_rresp             <= RESP_DECERR;
                        s_axi_rdata             <= '0;
                        rd_fault_addr_violation <= 1'b1;
                        rd_state                <= RD_RESP;
                    end else if (!chk_r_allow) begin
                        s_axi_rresp             <= RESP_SLVERR;
                        s_axi_rdata             <= '0;
                        rd_fault_perm_violation <= 1'b1;
                        rd_state                <= RD_RESP;
                    end else begin
                        m_axi_arvalid  <= 1'b1;
                        rd_timeout_cnt <= '0;
                        rd_state       <= RD_FWD;
                    end
                end

                RD_FWD: begin
                    if (m_axi_arvalid && m_axi_arready) m_axi_arvalid <= 1'b0;

                    if (!m_axi_arvalid) begin
                        if (m_axi_rvalid) begin
                            s_axi_rdata <= m_axi_rdata;
                            s_axi_rresp <= axi_resp_e'(m_axi_rresp);
                            rd_state    <= RD_RESP;
                        end else if (rd_timeout_cnt >= timeout_value) begin
                            s_axi_rdata      <= '0;
                            s_axi_rresp      <= RESP_SLVERR;
                            rd_fault_timeout <= 1'b1;
                            rd_state         <= RD_RESP;
                        end else begin
                            rd_timeout_cnt <= rd_timeout_cnt + 1'b1;
                        end
                    end else begin
                        if (rd_timeout_cnt >= timeout_value) begin
                            // See write path: ARVALID is NOT withdrawn here.
                            s_axi_rdata      <= '0;
                            s_axi_rresp      <= RESP_SLVERR;
                            rd_fault_timeout <= 1'b1;
                            rd_state         <= RD_RESP;
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
            if (unblock) begin
                m_axi_arvalid <= 1'b0;
            end
        end
    end

endmodule
