// Carries a `timescale even though it is pure synthesisable RTL with no
// delays. Mixing timescaled and untimescaled modules in one compilation is
// tool-dependent (IEEE 1800 3.14.2.3) - slang rejects it outright, Verilator
// warns (TIMESCALEMOD), Questa accepts it silently. Quartus ignores the
// directive for synthesis, so declaring it costs nothing and removes the
// ambiguity.
`timescale 1ns/1ps

// =============================================================================
// avl_mm_firewall_regs.sv
//
// Control & status register block for the Avalon-MM Firewall core.
// Owns: the programmable rule table, global enable/isolate control, sticky
// fault status, interrupt generation, and two independent purely-combinational
// rule-lookup ports (one for the write datapath, one for the read datapath in
// avl_mm_firewall_top.sv) so both channels get an answer in the same cycle
// without contending for a single shared lookup.
//
// BURST-AWARE LOOKUP. Each lookup port takes TWO addresses - the first byte
// and the last byte of the transaction - and reports both whether the first
// address matched a rule and whether the SAME rule also contains the last
// address. A burst that starts inside an allowed window and runs off its end
// must not be forwarded; checking only the start address is the obvious way to
// build a firewall that a DMA engine walks straight through. See
// `chk_*_contain` below and the FW_BURST_RANGE verdict in avl_mm_firewall_top.sv.
//
// CSR PORT. Avalon-MM slave, 32-bit, WORD-addressed (Platform Designer's
// default addressUnits for a slave), fixed read latency of 1, never asserts
// waitrequest. That is the standard Altera register-peripheral profile - the
// same one altera_avalon_pio uses - and it is what makes the port trivially
// safe to reach while the data path is isolated or wedged.
//
// The register map in the documentation is quoted in BYTE offsets, because
// that is what software writing through IOWR_32DIRECT() uses. The word address
// this module sees is the byte offset divided by four. WOFF_* below are word
// offsets for exactly that reason.
//
// LANGUAGE: SystemVerilog (IEEE 1800), synthesisable subset - `logic`,
// always_ff/always_comb, packed structs, enums, unpacked-array shorthand and
// $clog2. All of it is supported by Quartus Prime for synthesis; nothing here
// needs a simulator-only construct.
// =============================================================================

module avl_mm_firewall_regs
    import avl_mm_firewall_pkg::*;
#(
    parameter int ADDR_WIDTH     = 32, // data-path byte address width
    parameter int DATA_WIDTH     = 32, // data-path data width
    parameter int BURST_WIDTH    = 8,  // data-path burstcount width
    parameter int CSR_ADDR_WIDTH = 8,  // CSR port address width, IN WORDS
    parameter int NUM_RULES      = 8,
    parameter int TIMEOUT_WIDTH  = 20
) (
    input  logic                        clk,
    input  logic                        reset_n,      // active-low, synchronous

    // ---------------- CSR Avalon-MM slave (word-addressed, latency 1) ------
    input  logic [CSR_ADDR_WIDTH-1:0]   csr_address,
    input  logic                        csr_read,
    input  logic                        csr_write,
    input  logic [31:0]                 csr_writedata,
    input  logic [3:0]                  csr_byteenable,
    output logic [31:0]                 csr_readdata,

    output logic                        irq,

    // ---------------- live configuration exported to the datapath ----------
    output logic                        global_enable,
    output logic                        isolate_effective,
    output logic [TIMEOUT_WIDTH-1:0]    timeout_value,

    // ---------------- write-path combinational rule lookup -----------------
    input  logic [ADDR_WIDTH-1:0]       chk_w_addr,     // first byte
    input  logic [ADDR_WIDTH-1:0]       chk_w_last,     // last byte of the burst
    output logic                        chk_w_match,    // start address hit a valid rule
    output logic                        chk_w_allow,    // ...and that rule permits writes
    output logic                        chk_w_contain,  // ...and it also contains chk_w_last
    output logic                        chk_w_burst_en, // ...and it permits bursts

    // ---------------- read-path combinational rule lookup ------------------
    input  logic [ADDR_WIDTH-1:0]       chk_r_addr,
    input  logic [ADDR_WIDTH-1:0]       chk_r_last,
    output logic                        chk_r_match,
    output logic                        chk_r_allow,
    output logic                        chk_r_contain,
    output logic                        chk_r_burst_en,

    // ---------------- fault reporting from the datapath --------------------
    // One-cycle pulses. fault_type_in is only sampled when one of them is
    // asserted; the datapath drives the specific fw_code_e so
    // that BURST_RANGE and BURST_DENIED - which share STATUS bit 3 - stay
    // distinguishable in FAULT_INFO.
    input  logic                        fault_addr_violation,
    input  logic                        fault_perm_violation,
    input  logic                        fault_timeout,
    input  logic                        fault_burst_violation,
    input  fw_code_e                    fault_type_in,
    input  logic [ADDR_WIDTH-1:0]       fault_addr_value,
    input  logic                        fault_was_write,
    input  logic [BURST_WIDTH-1:0]      fault_burstcount,

    // ---------------- downstream status, for the recovery sequence ---------
    input  logic                        dstat_blocked,
    input  logic                        dstat_wr_busy,
    input  logic                        dstat_rd_busy,
    input  logic                        dstat_wr_cmd_stuck,
    input  logic                        dstat_rd_cmd_stuck,

    // Single-cycle pulse when software writes RECOVERY.UNBLOCK.
    //
    // This is the authorisation to discard downstream Avalon-MM state: it
    // releases the "downstream broken" latch AND is the one point at which a
    // frozen m0_read/m0_write may be withdrawn without waitrequest having
    // fallen. Software must have reset the protected peripheral before issuing
    // it - see the header of avl_mm_firewall_top.sv.
    output logic                        unblock
);

    localparam logic [15:0] VERSION16 = 16'h0100; // v1.0

    // ------------------------------------------------------------------
    // Register map, in WORDS. The documentation quotes byte offsets (what
    // software uses); word offset = byte offset / 4.
    // ------------------------------------------------------------------
    localparam logic [CSR_ADDR_WIDTH-1:0]
        WOFF_CTRL       = 'h0,   // byte 0x00
        WOFF_STATUS     = 'h1,   // byte 0x04
        WOFF_IRQ_ENABLE = 'h2,   // byte 0x08
        WOFF_TIMEOUT    = 'h3,   // byte 0x0C
        WOFF_FAULT_ADDR = 'h4,   // byte 0x10
        WOFF_FAULT_INFO = 'h5,   // byte 0x14
        WOFF_CORE_INFO  = 'h6,   // byte 0x18
        WOFF_RECOVERY   = 'h7;   // byte 0x1C

    localparam int RULE_WORD_BASE   = 'h10;   // byte 0x40
    localparam int RULE_WORD_STRIDE = 4;      // 4 words = 16 bytes per rule
    localparam int RULE_WORD_SPAN   = NUM_RULES * RULE_WORD_STRIDE;

    // Sub-offsets within one rule slot, in words
    localparam logic [1:0]
        RULE_SUB_BASE  = 2'd0,
        RULE_SUB_LIMIT = 2'd1,
        RULE_SUB_PERM  = 2'd2;

    // FAULT_INFO[3:1] carries an fw_code_e, and rule_perm_t is the RULE_PERM
    // layout. Both come from avl_mm_firewall_pkg so the datapath and this block
    // cannot drift apart.

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
    logic reg_timeout_error;    // STATUS[2] sticky, W1C (clearing releases auto-isolate)
    logic reg_burst_violation;  // STATUS[3] sticky, W1C
    logic auto_isolate_latch;   // internal, OR'd into isolate_effective

    logic [3:0]               reg_irq_enable;
    logic [TIMEOUT_WIDTH-1:0] reg_timeout_value;

    logic [ADDR_WIDTH-1:0]  reg_fault_addr;
    logic                   reg_fault_was_write;
    fw_code_e               reg_fault_type;
    logic [BURST_WIDTH-1:0] reg_fault_burstcount;

    assign global_enable     = reg_global_enable;
    assign isolate_effective = reg_manual_isolate | auto_isolate_latch;
    assign timeout_value     = reg_timeout_value;
    assign irq = (reg_addr_violation  & reg_irq_enable[0]) |
                 (reg_perm_violation  & reg_irq_enable[1]) |
                 (reg_timeout_error   & reg_irq_enable[2]) |
                 (reg_burst_violation & reg_irq_enable[3]);

    // Any fault at all, for the shared FAULT_ADDR / FAULT_INFO capture.
    logic fault_any;
    assign fault_any = fault_addr_violation | fault_perm_violation |
                       fault_timeout        | fault_burst_violation;

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    // Rule-table index for a CSR word address, or -1 if outside the table.
    function automatic int rule_index_of(input logic [CSR_ADDR_WIDTH-1:0] a);
        int addr;                       // widen once, explicitly
        addr = int'(a);
        if (addr >= RULE_WORD_BASE && addr < (RULE_WORD_BASE + RULE_WORD_SPAN))
            return (addr - RULE_WORD_BASE) / RULE_WORD_STRIDE;
        else
            return -1;
    endfunction

    // Byte-enabled merge into an ADDR_WIDTH-wide field. Width-correct for any
    // ADDR_WIDTH <= 32, which the hw.tcl ALLOWED_RANGES permits; hard-wired
    // [31:24] slices would be an out-of-range part-select below 32.
    function automatic logic [ADDR_WIDTH-1:0] merge_addr_field(
            input logic [ADDR_WIDTH-1:0] cur,
            input logic [31:0]           wdata,
            input logic [3:0]            be);
        logic [31:0] merged;
        merged = '0;
        merged[ADDR_WIDTH-1:0] = cur;
        for (int b = 0; b < 4; b++)
            if (be[b]) merged[b*8 +: 8] = wdata[b*8 +: 8];
        return merged[ADDR_WIDTH-1:0];
    endfunction

    function automatic logic [TIMEOUT_WIDTH-1:0] merge_timeout_field(
            input logic [TIMEOUT_WIDTH-1:0] cur,
            input logic [31:0]              wdata,
            input logic [3:0]               be);
        logic [31:0] merged;
        merged = '0;
        merged[TIMEOUT_WIDTH-1:0] = cur;
        for (int b = 0; b < 4; b++)
            if (be[b]) merged[b*8 +: 8] = wdata[b*8 +: 8];
        return merged[TIMEOUT_WIDTH-1:0];
    endfunction

    // ------------------------------------------------------------------
    // Combinational rule lookup - duplicated for write/read so both datapath
    // channels get an independent answer in the same cycle. First matching
    // VALID rule (lowest index) wins.
    //
    // `contain` is evaluated against the SAME rule that matched the start
    // address, not against the table as a whole. Two adjacent windows do not
    // combine into one larger permitted window: a burst spanning both is a
    // DEC_RANGE violation. That is deliberate - permissions are per-window,
    // and a burst crossing a boundary would have to satisfy both.
    // ------------------------------------------------------------------
    always_comb begin
        chk_w_match    = 1'b0;
        chk_w_allow    = 1'b0;
        chk_w_contain  = 1'b0;
        chk_w_burst_en = 1'b0;
        for (int i = 0; i < NUM_RULES; i++) begin
            if (!chk_w_match && rule_perm[i].valid &&
                (chk_w_addr >= rule_base[i]) && (chk_w_addr <= rule_limit[i])) begin
                chk_w_match    = 1'b1;
                chk_w_allow    = rule_perm[i].wr_en;
                chk_w_burst_en = rule_perm[i].burst_en;
                chk_w_contain  = (chk_w_last >= rule_base[i]) &&
                                 (chk_w_last <= rule_limit[i]);
            end
        end
    end

    always_comb begin
        chk_r_match    = 1'b0;
        chk_r_allow    = 1'b0;
        chk_r_contain  = 1'b0;
        chk_r_burst_en = 1'b0;
        for (int i = 0; i < NUM_RULES; i++) begin
            if (!chk_r_match && rule_perm[i].valid &&
                (chk_r_addr >= rule_base[i]) && (chk_r_addr <= rule_limit[i])) begin
                chk_r_match    = 1'b1;
                chk_r_allow    = rule_perm[i].rd_en;
                chk_r_burst_en = rule_perm[i].burst_en;
                chk_r_contain  = (chk_r_last >= rule_base[i]) &&
                                 (chk_r_last <= rule_limit[i]);
            end
        end
    end

    // ------------------------------------------------------------------
    // CSR write path.
    //
    // waitrequest is never asserted, so a write commits in the cycle
    // csr_write is seen. No backpressure and no outstanding-transaction
    // bookkeeping is needed - which is the whole reason for choosing the
    // fixed-latency register profile over a pipelined one for this port.
    // ------------------------------------------------------------------
    int wr_rule_idx;
    always_comb wr_rule_idx = rule_index_of(csr_address);

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            unblock              <= 1'b0;

            reg_global_enable    <= 1'b1;   // secure by default
            reg_auto_isolate_en  <= 1'b1;
            reg_manual_isolate   <= 1'b0;
            reg_addr_violation   <= 1'b0;
            reg_perm_violation   <= 1'b0;
            reg_timeout_error    <= 1'b0;
            reg_burst_violation  <= 1'b0;
            auto_isolate_latch   <= 1'b0;
            reg_irq_enable       <= 4'hF;
            reg_timeout_value    <= '1;
            reg_fault_addr       <= '0;
            reg_fault_was_write  <= 1'b0;
            reg_fault_type       <= FW_ALLOW;   // "no fault recorded yet"
            reg_fault_burstcount <= '0;

            for (int i = 0; i < NUM_RULES; i++) begin
                rule_base[i]  <= '0;
                rule_limit[i] <= '0;
                rule_perm[i]  <= '0;
            end
        end else begin
            unblock <= 1'b0;   // default: single-cycle pulse

            // ---- hardware fault capture (highest priority; always wins the
            //      register write in the same cycle if both occur) ----
            if (fault_addr_violation)  reg_addr_violation  <= 1'b1;
            if (fault_perm_violation)  reg_perm_violation  <= 1'b1;
            if (fault_burst_violation) reg_burst_violation <= 1'b1;
            if (fault_timeout) begin
                reg_timeout_error <= 1'b1;
                if (reg_auto_isolate_en) auto_isolate_latch <= 1'b1;
            end
            if (fault_any) begin
                reg_fault_addr       <= fault_addr_value;
                reg_fault_was_write  <= fault_was_write;
                reg_fault_type       <= fault_type_in;
                reg_fault_burstcount <= fault_burstcount;
            end

            // ---- CSR writes ----
            if (csr_write) begin
                if (wr_rule_idx >= 0) begin
                    case (csr_address[1:0])
                        RULE_SUB_BASE:
                            rule_base[wr_rule_idx] <= merge_addr_field(
                                rule_base[wr_rule_idx], csr_writedata, csr_byteenable);
                        RULE_SUB_LIMIT:
                            rule_limit[wr_rule_idx] <= merge_addr_field(
                                rule_limit[wr_rule_idx], csr_writedata, csr_byteenable);
                        RULE_SUB_PERM:
                            if (csr_byteenable[0])
                                rule_perm[wr_rule_idx] <= rule_perm_t'(csr_writedata[3:0]);
                        default: ; // reserved word within the rule slot, ignored
                    endcase
                end else begin
                    case (csr_address)
                        WOFF_CTRL: begin
                            if (csr_byteenable[0]) begin
                                reg_global_enable   <= csr_writedata[0];
                                reg_auto_isolate_en <= csr_writedata[1];
                                reg_manual_isolate  <= csr_writedata[2];
                            end
                        end
                        WOFF_STATUS: begin   // W1C on bits 3:0
                            if (csr_byteenable[0]) begin
                                if (csr_writedata[0]) reg_addr_violation  <= 1'b0;
                                if (csr_writedata[1]) reg_perm_violation  <= 1'b0;
                                if (csr_writedata[3]) reg_burst_violation <= 1'b0;
                                if (csr_writedata[2]) begin
                                    // Clears the sticky bit and releases
                                    // auto-isolate, but does NOT resume
                                    // forwarding. Reopening the downstream is
                                    // an explicit RECOVERY.UNBLOCK, so that
                                    // acknowledging a fault cannot accidentally
                                    // restart traffic toward a peripheral
                                    // nobody has reset yet.
                                    reg_timeout_error  <= 1'b0;
                                    auto_isolate_latch <= 1'b0;
                                end
                            end
                        end
                        WOFF_RECOVERY:
                            if (csr_byteenable[0] && csr_writedata[0])
                                unblock <= 1'b1;
                        WOFF_IRQ_ENABLE:
                            if (csr_byteenable[0]) reg_irq_enable <= csr_writedata[3:0];
                        WOFF_TIMEOUT:
                            reg_timeout_value <= merge_timeout_field(
                                reg_timeout_value, csr_writedata, csr_byteenable);
                        default: ; // FAULT_ADDR/FAULT_INFO/CORE_INFO read-only; others reserved
                    endcase
                end
            end

            // Fault capture above must win over a same-cycle W1C of the same
            // bit; re-assert if both happened this cycle.
            //
            // auto_isolate_latch has to be re-asserted here too. Without it, a
            // timeout landing in the same cycle as a W1C of STATUS.TIMEOUT_ERROR
            // leaves TIMEOUT_ERROR=1 (forced below) but ISOLATED=0, because the
            // W1C's clear of the latch is the later assignment and wins. That
            // also disagrees with avl_mm_firewall_top.sv, where a fresh fault
            // unconditionally beats unblock for `downstream_broken`.
            if (fault_addr_violation)  reg_addr_violation  <= 1'b1;
            if (fault_perm_violation)  reg_perm_violation  <= 1'b1;
            if (fault_burst_violation) reg_burst_violation <= 1'b1;
            if (fault_timeout) begin
                reg_timeout_error <= 1'b1;
                if (reg_auto_isolate_en) auto_isolate_latch <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // CSR read path - fixed latency of 1, no readdatavalid, no waitrequest.
    // Platform Designer is told `readLatency 1` in avl_mm_firewall_hw.tcl and
    // the interconnect pipelines accordingly.
    // ------------------------------------------------------------------
    int rd_rule_idx;
    always_comb rd_rule_idx = rule_index_of(csr_address);

    // Saturate the captured burstcount into the 8-bit FAULT_INFO field rather
    // than truncating it: a truncated 256-beat burst reading back as 0 is
    // worse than useless when the field exists to tell you how big the
    // offending transfer was.
    // A generate-if, not a ternary. reg_fault_burstcount[BURST_WIDTH-1:8] is
    // an illegal range whenever BURST_WIDTH <= 8, and guarding it with a
    // ternary does not help - the part-select is still elaborated. An untaken
    // generate branch is not.
    logic [7:0] fault_burst_field;
    generate
        if (BURST_WIDTH > 8) begin : g_saturate
            assign fault_burst_field = (|reg_fault_burstcount[BURST_WIDTH-1:8])
                                       ? 8'hFF : reg_fault_burstcount[7:0];
        end else begin : g_direct
            assign fault_burst_field = 8'(reg_fault_burstcount);
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            csr_readdata <= '0;
        end else if (csr_read) begin
            if (rd_rule_idx >= 0) begin
                case (csr_address[1:0])
                    RULE_SUB_BASE:  csr_readdata <= 32'(rule_base[rd_rule_idx]);
                    RULE_SUB_LIMIT: csr_readdata <= 32'(rule_limit[rd_rule_idx]);
                    RULE_SUB_PERM:  csr_readdata <= {28'b0, rule_perm[rd_rule_idx]};
                    default:        csr_readdata <= '0;
                endcase
            end else begin
                case (csr_address)
                    WOFF_CTRL:       csr_readdata <= {29'b0, reg_manual_isolate,
                                                      reg_auto_isolate_en, reg_global_enable};
                    WOFF_STATUS:     csr_readdata <= {22'b0,
                                                      dstat_rd_cmd_stuck,
                                                      dstat_wr_cmd_stuck,
                                                      dstat_rd_busy,
                                                      dstat_wr_busy,
                                                      dstat_blocked,
                                                      isolate_effective,
                                                      reg_burst_violation,
                                                      reg_timeout_error,
                                                      reg_perm_violation,
                                                      reg_addr_violation};
                    WOFF_IRQ_ENABLE: csr_readdata <= {28'b0, reg_irq_enable};
                    WOFF_TIMEOUT:    csr_readdata <= 32'(reg_timeout_value);
                    WOFF_FAULT_ADDR: csr_readdata <= 32'(reg_fault_addr);
                    WOFF_FAULT_INFO: csr_readdata <= {16'b0, fault_burst_field,
                                                      4'b0, reg_fault_type,
                                                      reg_fault_was_write};
                    // [7:0] rules, [12:8] burstcount width, [15:13] log2 bytes
                    // per beat, [31:16] version. Everything a driver needs to
                    // check that it is talking to the core it was built for.
                    WOFF_CORE_INFO:  csr_readdata <= {VERSION16,
                                                      3'($clog2(DATA_WIDTH/8)),
                                                      5'(BURST_WIDTH),
                                                      8'(NUM_RULES)};
                    WOFF_RECOVERY:   csr_readdata <= '0;   // write-only, self-clearing
                    default:         csr_readdata <= '0;
                endcase
            end
        end
    end

endmodule
