// Carries a `timescale even though it is pure synthesisable RTL with no
// delays. Mixing timescaled and untimescaled modules in one compilation is
// tool-dependent (IEEE 1800 3.14.2.3) - slang rejects it outright, Verilator
// warns (TIMESCALEMOD), Questa accepts it silently. Quartus ignores the
// directive for synthesis, so declaring it costs nothing and removes the
// ambiguity.
`timescale 1ns/1ps

// =============================================================================
// axi4_lite_firewall_regs.sv
//
// Control & status register block for the AXI4-Lite Firewall core.
// Owns: the programmable rule table, global enable/isolate control, sticky
// fault status, interrupt generation, and two independent purely-combinational
// rule-lookup ports (one for the write datapath, one for the read datapath in
// axi4_lite_firewall_top.sv) so both channels get an answer in the same cycle without
// contending for a single shared lookup.
//
// AXI4-Lite slave port: single-outstanding, fully synchronous reset (resetn,
// active-low). See README.md for the full register map.
//
// LANGUAGE: SystemVerilog (IEEE 1800), synthesisable subset - `logic`,
// always_ff/always_comb, packed structs, enums, unpacked-array shorthand and
// $clog2. All of it is supported by Quartus Prime for synthesis; nothing here
// needs a simulator-only construct.
// =============================================================================

module axi4_lite_firewall_regs #(
    parameter int ADDR_WIDTH      = 32,  // data-path address width (rule base/limit width)
    parameter int CTRL_ADDR_WIDTH = 12,  // control port address width
    parameter int NUM_RULES       = 8,
    parameter int TIMEOUT_WIDTH   = 20
) (
    input  logic                        clk,
    input  logic                        resetn,        // active-low, synchronous

    // ---------------- AXI4-Lite control/status slave port ------------------
    input  logic [CTRL_ADDR_WIDTH-1:0]  s_axi_ctrl_awaddr,
    input  logic [2:0]                  s_axi_ctrl_awprot,
    input  logic                        s_axi_ctrl_awvalid,
    output logic                        s_axi_ctrl_awready,
    input  logic [31:0]                 s_axi_ctrl_wdata,
    input  logic [3:0]                  s_axi_ctrl_wstrb,
    input  logic                        s_axi_ctrl_wvalid,
    output logic                        s_axi_ctrl_wready,
    output logic [1:0]                  s_axi_ctrl_bresp,
    output logic                        s_axi_ctrl_bvalid,
    input  logic                        s_axi_ctrl_bready,
    input  logic [CTRL_ADDR_WIDTH-1:0]  s_axi_ctrl_araddr,
    input  logic [2:0]                  s_axi_ctrl_arprot,
    input  logic                        s_axi_ctrl_arvalid,
    output logic                        s_axi_ctrl_arready,
    output logic [31:0]                 s_axi_ctrl_rdata,
    output logic [1:0]                  s_axi_ctrl_rresp,
    output logic                        s_axi_ctrl_rvalid,
    input  logic                        s_axi_ctrl_rready,

    output logic                        irq,

    // ---------------- live configuration exported to the datapath ----------
    output logic                        global_enable,
    output logic                        isolate_effective,
    output logic [TIMEOUT_WIDTH-1:0]    timeout_value,

    // ---------------- write-path combinational rule lookup -----------------
    input  logic [ADDR_WIDTH-1:0]       chk_w_addr,
    output logic                        chk_w_allow,
    output logic                        chk_w_match,

    // ---------------- read-path combinational rule lookup -------------------
    input  logic [ADDR_WIDTH-1:0]       chk_r_addr,
    output logic                        chk_r_allow,
    output logic                        chk_r_match,

    // ---------------- fault reporting from the datapath ---------------------
    input  logic                        fault_addr_violation,
    input  logic                        fault_perm_violation,
    input  logic                        fault_timeout,
    input  logic [ADDR_WIDTH-1:0]       fault_addr_value,
    input  logic                        fault_was_write,

    // ---------------- downstream status, for the recovery sequence ---------
    input  logic                        dstat_blocked,
    input  logic                        dstat_wr_resp_busy,
    input  logic                        dstat_rd_resp_busy,
    input  logic                        dstat_wr_cmd_stuck,
    input  logic                        dstat_rd_cmd_stuck,

    // Single-cycle pulse when software writes RECOVERY.UNBLOCK.
    //
    // This is the authorisation to discard downstream AXI state: it releases
    // the "downstream broken" latch AND is the one point at which a stuck
    // m_axi_*VALID may be withdrawn without a handshake. Software must have
    // reset the protected peripheral before issuing it - see the header of
    // axi4_lite_firewall_top.sv.
    output logic                        unblock
);

    localparam logic [15:0] VERSION16 = 16'h0200; // v2.0

    // ------------------------------------------------------------------
    // Register map. Named localparams rather than bare literals in the
    // address decode below - the same constants are used by the write
    // decode, the read mux and the testbench's expectations.
    // ------------------------------------------------------------------
    localparam logic [CTRL_ADDR_WIDTH-1:0]
        OFF_CTRL       = 'h00,
        OFF_STATUS     = 'h04,
        OFF_IRQ_ENABLE = 'h08,
        OFF_TIMEOUT    = 'h0C,
        OFF_FAULT_ADDR = 'h10,
        OFF_FAULT_INFO = 'h14,
        OFF_CORE_INFO  = 'h18,
        OFF_RECOVERY   = 'h1C;

    localparam int RULE_TABLE_BASE = 'h40;  // byte offset of RULE[0]
    localparam int RULE_STRIDE     = 16;    // bytes per rule
    localparam int RULE_TABLE_SPAN = NUM_RULES * RULE_STRIDE;

    // Sub-offsets within one rule slot
    localparam logic [3:0]
        RULE_SUB_BASE  = 4'h0,
        RULE_SUB_LIMIT = 4'h4,
        RULE_SUB_PERM  = 4'h8;

    // FAULT_INFO[3:1]
    typedef enum logic [2:0] {
        FAULT_NONE    = 3'b000,
        FAULT_ADDR    = 3'b001,
        FAULT_PERM    = 3'b010,
        FAULT_TIMEOUT = 3'b011
    } fault_type_e;

    // RULE_PERM[2:0] - declared MSB-first so the packed layout is exactly
    // {VALID, WRITE_ALLOW, READ_ALLOW} = bits [2:0] of the register.
    typedef struct packed {
        logic valid;
        logic wr_en;
        logic rd_en;
    } rule_perm_t;

    // ------------------------------------------------------------------
    // Rule table storage
    // ------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0] rule_base  [NUM_RULES];
    logic [ADDR_WIDTH-1:0] rule_limit [NUM_RULES];
    rule_perm_t            rule_perm  [NUM_RULES];

    // ------------------------------------------------------------------
    // Control / status registers
    // ------------------------------------------------------------------
    logic reg_global_enable;
    logic reg_auto_isolate_en;
    logic reg_manual_isolate;

    logic reg_addr_violation;   // STATUS[0] sticky, W1C
    logic reg_perm_violation;   // STATUS[1] sticky, W1C
    logic reg_timeout_error;    // STATUS[2] sticky, W1C (clearing also releases auto-isolate)
    logic auto_isolate_latch;   // internal, OR'd into isolate_effective

    logic [2:0]             reg_irq_enable;
    logic [TIMEOUT_WIDTH-1:0] reg_timeout_value;

    logic [ADDR_WIDTH-1:0] reg_fault_addr;
    logic                  reg_fault_was_write;
    fault_type_e           reg_fault_type;

    assign global_enable     = reg_global_enable;
    assign isolate_effective = reg_manual_isolate | auto_isolate_latch;
    assign timeout_value     = reg_timeout_value;
    assign irq = (reg_addr_violation & reg_irq_enable[0]) |
                 (reg_perm_violation & reg_irq_enable[1]) |
                 (reg_timeout_error  & reg_irq_enable[2]);

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    // Rule-table index for a control-port byte address, or -1 if the address
    // is outside the table.
    function automatic int rule_index_of(input logic [CTRL_ADDR_WIDTH-1:0] a);
        int addr;                       // widen once, explicitly
        addr = int'(a);
        if (addr >= RULE_TABLE_BASE && addr < (RULE_TABLE_BASE + RULE_TABLE_SPAN))
            return (addr - RULE_TABLE_BASE) / RULE_STRIDE;
        else
            return -1;
    endfunction

    // Byte-strobed merge into an ADDR_WIDTH-wide field.
    //
    // The Verilog-2001 version open-coded four `if (wstrb[n]) field[n*8+:8] <=`
    // statements against hard-wired [31:24] slices, so any ADDR_WIDTH below 32
    // - which the hw.tcl ALLOWED_RANGES has always permitted - was an
    // out-of-range part-select. This form is width-correct for any
    // ADDR_WIDTH <= 32.
    function automatic logic [ADDR_WIDTH-1:0] merge_addr_field(
            input logic [ADDR_WIDTH-1:0] cur,
            input logic [31:0]           wdata,
            input logic [3:0]            strb);
        logic [31:0] merged;
        merged = '0;
        merged[ADDR_WIDTH-1:0] = cur;
        for (int b = 0; b < 4; b++)
            if (strb[b]) merged[b*8 +: 8] = wdata[b*8 +: 8];
        return merged[ADDR_WIDTH-1:0];
    endfunction

    function automatic logic [TIMEOUT_WIDTH-1:0] merge_timeout_field(
            input logic [TIMEOUT_WIDTH-1:0] cur,
            input logic [31:0]              wdata,
            input logic [3:0]               strb);
        logic [31:0] merged;
        merged = '0;
        merged[TIMEOUT_WIDTH-1:0] = cur;
        for (int b = 0; b < 4; b++)
            if (strb[b]) merged[b*8 +: 8] = wdata[b*8 +: 8];
        return merged[TIMEOUT_WIDTH-1:0];
    endfunction

    // ------------------------------------------------------------------
    // Combinational rule lookup - duplicated for write/read so both
    // datapath FSMs get an independent answer in the same cycle.
    // First matching VALID rule (lowest index) wins.
    // ------------------------------------------------------------------
    always_comb begin
        chk_w_allow = 1'b0;
        chk_w_match = 1'b0;
        for (int i = 0; i < NUM_RULES; i++) begin
            if (!chk_w_match && rule_perm[i].valid &&
                (chk_w_addr >= rule_base[i]) && (chk_w_addr <= rule_limit[i])) begin
                chk_w_match = 1'b1;
                chk_w_allow = rule_perm[i].wr_en;
            end
        end
    end

    always_comb begin
        chk_r_allow = 1'b0;
        chk_r_match = 1'b0;
        for (int i = 0; i < NUM_RULES; i++) begin
            if (!chk_r_match && rule_perm[i].valid &&
                (chk_r_addr >= rule_base[i]) && (chk_r_addr <= rule_limit[i])) begin
                chk_r_match = 1'b1;
                chk_r_allow = rule_perm[i].rd_en;
            end
        end
    end

    // ------------------------------------------------------------------
    // AXI4-Lite slave - write channel (address+data accepted together;
    // a slave is always permitted to add wait states, so requiring both
    // AWVALID and WVALID before asserting either READY is fully compliant
    // and keeps this to a single simple, well-tested pattern).
    //
    // The !s_axi_ctrl_bvalid qualifier is load-bearing. This port is
    // single-outstanding: the write below is only committed when `do_write`
    // is true, which also requires !s_axi_ctrl_bvalid. Asserting READY
    // without that qualifier lets a master whose previous BVALID is still
    // unacknowledged complete the AW/W handshake for a *second* write that
    // then never commits and never gets a response - silent data loss plus
    // a wedged write channel. Withholding READY is the correct backpressure.
    // ------------------------------------------------------------------
    logic [CTRL_ADDR_WIDTH-1:0] axi_awaddr_r;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            s_axi_ctrl_awready <= 1'b0;
            s_axi_ctrl_wready  <= 1'b0;
            axi_awaddr_r       <= '0;
        end else begin
            if (!s_axi_ctrl_awready && s_axi_ctrl_awvalid && s_axi_ctrl_wvalid &&
                !s_axi_ctrl_bvalid) begin
                s_axi_ctrl_awready <= 1'b1;
                s_axi_ctrl_wready  <= 1'b1;
                axi_awaddr_r       <= s_axi_ctrl_awaddr;
            end else begin
                s_axi_ctrl_awready <= 1'b0;
                s_axi_ctrl_wready  <= 1'b0;
            end
        end
    end

    // Hoisted out of the always_ff below, where they were blocking assignments
    // inside a clocked process. Same logic, no mixed assignment styles.
    logic do_write;
    int   wr_rule_idx;

    assign do_write = s_axi_ctrl_awready && s_axi_ctrl_awvalid &&
                      s_axi_ctrl_wready  && s_axi_ctrl_wvalid  && !s_axi_ctrl_bvalid;

    always_comb wr_rule_idx = rule_index_of(axi_awaddr_r);

    always_ff @(posedge clk) begin
        if (!resetn) begin
            s_axi_ctrl_bvalid   <= 1'b0;
            s_axi_ctrl_bresp    <= 2'b00;
            unblock             <= 1'b0;

            reg_global_enable   <= 1'b1;   // secure by default
            reg_auto_isolate_en <= 1'b1;
            reg_manual_isolate  <= 1'b0;
            reg_addr_violation  <= 1'b0;
            reg_perm_violation  <= 1'b0;
            reg_timeout_error   <= 1'b0;
            auto_isolate_latch  <= 1'b0;
            reg_irq_enable      <= 3'b111;
            reg_timeout_value   <= '1;
            reg_fault_addr      <= '0;
            reg_fault_was_write <= 1'b0;
            reg_fault_type      <= FAULT_NONE;

            for (int i = 0; i < NUM_RULES; i++) begin
                rule_base[i]  <= '0;
                rule_limit[i] <= '0;
                rule_perm[i]  <= '0;
            end
        end else begin
            unblock <= 1'b0;   // default: single-cycle pulse

            // ---- hardware fault capture (highest priority; always wins
            //      the register-write in the same cycle if both occur) ----
            if (fault_addr_violation) begin
                reg_addr_violation  <= 1'b1;
                reg_fault_addr      <= fault_addr_value;
                reg_fault_was_write <= fault_was_write;
                reg_fault_type      <= FAULT_ADDR;
            end
            if (fault_perm_violation) begin
                reg_perm_violation  <= 1'b1;
                reg_fault_addr      <= fault_addr_value;
                reg_fault_was_write <= fault_was_write;
                reg_fault_type      <= FAULT_PERM;
            end
            if (fault_timeout) begin
                reg_timeout_error   <= 1'b1;
                reg_fault_addr      <= fault_addr_value;
                reg_fault_was_write <= fault_was_write;
                reg_fault_type      <= FAULT_TIMEOUT;
                if (reg_auto_isolate_en)
                    auto_isolate_latch <= 1'b1;
            end

            // ---- write channel ----
            if (do_write) begin
                s_axi_ctrl_bvalid <= 1'b1;
                s_axi_ctrl_bresp  <= 2'b00; // OKAY

                if (wr_rule_idx >= 0) begin
                    case (axi_awaddr_r[3:0])
                        RULE_SUB_BASE:
                            rule_base[wr_rule_idx] <= merge_addr_field(
                                rule_base[wr_rule_idx], s_axi_ctrl_wdata, s_axi_ctrl_wstrb);
                        RULE_SUB_LIMIT:
                            rule_limit[wr_rule_idx] <= merge_addr_field(
                                rule_limit[wr_rule_idx], s_axi_ctrl_wdata, s_axi_ctrl_wstrb);
                        RULE_SUB_PERM:
                            if (s_axi_ctrl_wstrb[0])
                                rule_perm[wr_rule_idx] <= rule_perm_t'(s_axi_ctrl_wdata[2:0]);
                        default: ; // reserved word within the rule slot, ignored
                    endcase
                end else begin
                    case (axi_awaddr_r)
                        OFF_CTRL: begin
                            if (s_axi_ctrl_wstrb[0]) begin
                                reg_global_enable   <= s_axi_ctrl_wdata[0];
                                reg_auto_isolate_en <= s_axi_ctrl_wdata[1];
                                reg_manual_isolate  <= s_axi_ctrl_wdata[2];
                            end
                        end
                        OFF_STATUS: begin   // W1C on bits 2:0
                            if (s_axi_ctrl_wstrb[0]) begin
                                if (s_axi_ctrl_wdata[0]) reg_addr_violation <= 1'b0;
                                if (s_axi_ctrl_wdata[1]) reg_perm_violation <= 1'b0;
                                if (s_axi_ctrl_wdata[2]) begin
                                    // v2.0: clears the sticky bit and releases
                                    // auto-isolate, but no longer resumes
                                    // forwarding. Reopening the downstream is
                                    // now an explicit RECOVERY.UNBLOCK, so
                                    // that acknowledging a fault cannot
                                    // accidentally restart traffic toward a
                                    // peripheral nobody has reset yet.
                                    reg_timeout_error  <= 1'b0;
                                    auto_isolate_latch <= 1'b0;
                                end
                            end
                        end
                        OFF_RECOVERY:
                            if (s_axi_ctrl_wstrb[0] && s_axi_ctrl_wdata[0])
                                unblock <= 1'b1;
                        OFF_IRQ_ENABLE:
                            if (s_axi_ctrl_wstrb[0]) reg_irq_enable <= s_axi_ctrl_wdata[2:0];
                        OFF_TIMEOUT:
                            reg_timeout_value <= merge_timeout_field(
                                reg_timeout_value, s_axi_ctrl_wdata, s_axi_ctrl_wstrb);
                        default: ; // FAULT_ADDR/FAULT_INFO/CORE_INFO are read-only; others reserved
                    endcase
                end
            end else if (s_axi_ctrl_bready && s_axi_ctrl_bvalid) begin
                s_axi_ctrl_bvalid <= 1'b0;
            end

            // Fault capture above must win over a same-cycle W1C of the same
            // bit; re-assert if both happened this cycle.
            //
            // auto_isolate_latch has to be re-asserted here too. Without it, a
            // timeout landing in the same cycle as a W1C of STATUS.TIMEOUT_ERROR
            // left TIMEOUT_ERROR=1 (forced below) but ISOLATED=0, because the
            // W1C's clear of the latch is the later assignment and wins. That
            // also disagreed with axi4_lite_firewall_top.sv, where the fault
            // unconditionally beats unblock for `downstream_broken`.
            if (fault_addr_violation) reg_addr_violation <= 1'b1;
            if (fault_perm_violation) reg_perm_violation <= 1'b1;
            if (fault_timeout) begin
                reg_timeout_error <= 1'b1;
                if (reg_auto_isolate_en) auto_isolate_latch <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // AXI4-Lite slave - read channel
    //
    // As on the write channel, the !s_axi_ctrl_rvalid qualifier is required:
    // the data phase below only fires when no response is already pending, so
    // accepting an address while RVALID is unacknowledged would consume a
    // read that never gets answered and hang the channel.
    // ------------------------------------------------------------------
    logic [CTRL_ADDR_WIDTH-1:0] axi_araddr_r;
    int                         rd_rule_idx;

    always_comb rd_rule_idx = rule_index_of(axi_araddr_r);

    always_ff @(posedge clk) begin
        if (!resetn) begin
            s_axi_ctrl_arready <= 1'b0;
            axi_araddr_r       <= '0;
        end else if (!s_axi_ctrl_arready && s_axi_ctrl_arvalid &&
                     !s_axi_ctrl_rvalid) begin
            s_axi_ctrl_arready <= 1'b1;
            axi_araddr_r       <= s_axi_ctrl_araddr;
        end else begin
            s_axi_ctrl_arready <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            s_axi_ctrl_rvalid <= 1'b0;
            s_axi_ctrl_rresp  <= 2'b00;
            s_axi_ctrl_rdata  <= '0;
        end else begin
            if (s_axi_ctrl_arready && s_axi_ctrl_arvalid && !s_axi_ctrl_rvalid) begin
                s_axi_ctrl_rvalid <= 1'b1;
                s_axi_ctrl_rresp  <= 2'b00; // OKAY

                if (rd_rule_idx >= 0) begin
                    case (axi_araddr_r[3:0])
                        RULE_SUB_BASE:  s_axi_ctrl_rdata <= 32'(rule_base[rd_rule_idx]);
                        RULE_SUB_LIMIT: s_axi_ctrl_rdata <= 32'(rule_limit[rd_rule_idx]);
                        RULE_SUB_PERM:  s_axi_ctrl_rdata <= {29'b0, rule_perm[rd_rule_idx]};
                        default:        s_axi_ctrl_rdata <= '0;
                    endcase
                end else begin
                    case (axi_araddr_r)
                        OFF_CTRL:       s_axi_ctrl_rdata <= {29'b0, reg_manual_isolate,
                                                             reg_auto_isolate_en, reg_global_enable};
                        OFF_STATUS:     s_axi_ctrl_rdata <= {23'b0,
                                                             dstat_rd_cmd_stuck,
                                                             dstat_wr_cmd_stuck,
                                                             dstat_rd_resp_busy,
                                                             dstat_wr_resp_busy,
                                                             dstat_blocked,
                                                             isolate_effective,
                                                             reg_timeout_error, reg_perm_violation,
                                                             reg_addr_violation};
                        OFF_IRQ_ENABLE: s_axi_ctrl_rdata <= {29'b0, reg_irq_enable};
                        OFF_TIMEOUT:    s_axi_ctrl_rdata <= 32'(reg_timeout_value);
                        OFF_FAULT_ADDR: s_axi_ctrl_rdata <= 32'(reg_fault_addr);
                        OFF_FAULT_INFO: s_axi_ctrl_rdata <= {28'b0, reg_fault_type,
                                                             reg_fault_was_write};
                        OFF_CORE_INFO:  s_axi_ctrl_rdata <= {VERSION16, 8'h0, 8'(NUM_RULES)};
                        OFF_RECOVERY:   s_axi_ctrl_rdata <= '0;   // write-only, self-clearing
                        default:        s_axi_ctrl_rdata <= '0;
                    endcase
                end
            end else if (s_axi_ctrl_rready && s_axi_ctrl_rvalid) begin
                s_axi_ctrl_rvalid <= 1'b0;
            end
        end
    end

endmodule
