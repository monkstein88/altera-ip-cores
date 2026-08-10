// =============================================================================
// axi_firewall_regs.v
//
// Control & status register block for the AXI4-Lite Firewall core.
// Owns: the programmable rule table, global enable/isolate control, sticky
// fault status, interrupt generation, and two independent purely-combinational
// rule-lookup ports (one for the write datapath, one for the read datapath in
// axi_firewall_top.v) so both channels get an answer in the same cycle without
// contending for a single shared lookup.
//
// AXI4-Lite slave port: single-outstanding, fully synchronous reset (resetn,
// active-low). See README.md for the full register map.
// =============================================================================

module axi_firewall_regs #(
    parameter ADDR_WIDTH      = 32,  // data-path address width (rule base/limit width)
    parameter CTRL_ADDR_WIDTH = 12,  // control port address width
    parameter NUM_RULES       = 8,
    parameter TIMEOUT_WIDTH   = 20
) (
    input  wire                        clk,
    input  wire                        resetn,        // active-low, synchronous

    // ---------------- AXI4-Lite control/status slave port ------------------
    input  wire [CTRL_ADDR_WIDTH-1:0]  s_axi_ctrl_awaddr,
    input  wire [2:0]                  s_axi_ctrl_awprot,
    input  wire                        s_axi_ctrl_awvalid,
    output wire                        s_axi_ctrl_awready,
    input  wire [31:0]                 s_axi_ctrl_wdata,
    input  wire [3:0]                  s_axi_ctrl_wstrb,
    input  wire                        s_axi_ctrl_wvalid,
    output wire                        s_axi_ctrl_wready,
    output reg  [1:0]                  s_axi_ctrl_bresp,
    output reg                         s_axi_ctrl_bvalid,
    input  wire                        s_axi_ctrl_bready,
    input  wire [CTRL_ADDR_WIDTH-1:0]  s_axi_ctrl_araddr,
    input  wire [2:0]                  s_axi_ctrl_arprot,
    input  wire                        s_axi_ctrl_arvalid,
    output wire                        s_axi_ctrl_arready,
    output reg  [31:0]                 s_axi_ctrl_rdata,
    output reg  [1:0]                  s_axi_ctrl_rresp,
    output reg                         s_axi_ctrl_rvalid,
    input  wire                        s_axi_ctrl_rready,

    output wire                        irq,

    // ---------------- live configuration exported to the datapath ----------
    output wire                        global_enable,
    output wire                        isolate_effective,
    output wire [TIMEOUT_WIDTH-1:0]    timeout_value,

    // ---------------- write-path combinational rule lookup -----------------
    input  wire [ADDR_WIDTH-1:0]       chk_w_addr,
    output wire                        chk_w_allow,
    output wire                        chk_w_match,

    // ---------------- read-path combinational rule lookup -------------------
    input  wire [ADDR_WIDTH-1:0]       chk_r_addr,
    output wire                        chk_r_allow,
    output wire                        chk_r_match,

    // ---------------- fault reporting from the datapath ---------------------
    input  wire                        fault_addr_violation,
    input  wire                        fault_perm_violation,
    input  wire                        fault_timeout,
    input  wire [ADDR_WIDTH-1:0]       fault_addr_value,
    input  wire                        fault_was_write,

    // Single-cycle pulse when software clears STATUS.TIMEOUT_ERROR (W1C).
    // Drives the downstream recovery sequence in axi_firewall_top.v: it
    // releases the "downstream broken" latch and starts the peripheral
    // reset pulse. See that file's header for why recovery must reset the
    // peripheral rather than simply resuming traffic.
    output reg                         timeout_ack
);

    localparam [15:0] VERSION16 = 16'h0100; // v1.0

    // ------------------------------------------------------------------
    // Rule table storage
    // ------------------------------------------------------------------
    reg [ADDR_WIDTH-1:0] rule_base    [0:NUM_RULES-1];
    reg [ADDR_WIDTH-1:0] rule_limit   [0:NUM_RULES-1];
    reg                  rule_valid_r [0:NUM_RULES-1];
    reg                  rule_rd_en   [0:NUM_RULES-1];
    reg                  rule_wr_en   [0:NUM_RULES-1];

    // ------------------------------------------------------------------
    // Control / status registers
    // ------------------------------------------------------------------
    reg reg_global_enable;
    reg reg_auto_isolate_en;
    reg reg_manual_isolate;

    reg reg_addr_violation;   // STATUS[0] sticky, W1C
    reg reg_perm_violation;   // STATUS[1] sticky, W1C
    reg reg_timeout_error;    // STATUS[2] sticky, W1C (clearing also releases auto-isolate)
    reg auto_isolate_latch;   // internal, OR'd into isolate_effective

    reg [2:0] reg_irq_enable;
    reg [TIMEOUT_WIDTH-1:0] reg_timeout_value;

    reg [ADDR_WIDTH-1:0] reg_fault_addr;
    reg                  reg_fault_was_write;
    reg [2:0]            reg_fault_type;   // 001=ADDR 010=PERM 011=TIMEOUT

    assign global_enable     = reg_global_enable;
    assign isolate_effective = reg_manual_isolate | auto_isolate_latch;
    assign timeout_value     = reg_timeout_value;
    assign irq = (reg_addr_violation & reg_irq_enable[0]) |
                 (reg_perm_violation & reg_irq_enable[1]) |
                 (reg_timeout_error  & reg_irq_enable[2]);

    // ------------------------------------------------------------------
    // Combinational rule lookup - duplicated for write/read so both
    // datapath FSMs get an independent answer in the same cycle.
    // First matching VALID rule (lowest index) wins.
    // ------------------------------------------------------------------
    integer wi, ri;
    reg w_allow_v, w_match_v;
    reg r_allow_v, r_match_v;

    always @(*) begin
        w_allow_v = 1'b0;
        w_match_v = 1'b0;
        for (wi = 0; wi < NUM_RULES; wi = wi + 1) begin
            if (!w_match_v && rule_valid_r[wi] &&
                (chk_w_addr >= rule_base[wi]) && (chk_w_addr <= rule_limit[wi])) begin
                w_match_v = 1'b1;
                w_allow_v = rule_wr_en[wi];
            end
        end
    end

    always @(*) begin
        r_allow_v = 1'b0;
        r_match_v = 1'b0;
        for (ri = 0; ri < NUM_RULES; ri = ri + 1) begin
            if (!r_match_v && rule_valid_r[ri] &&
                (chk_r_addr >= rule_base[ri]) && (chk_r_addr <= rule_limit[ri])) begin
                r_match_v = 1'b1;
                r_allow_v = rule_rd_en[ri];
            end
        end
    end

    assign chk_w_allow = w_allow_v;
    assign chk_w_match = w_match_v;
    assign chk_r_allow = r_allow_v;
    assign chk_r_match = r_match_v;

    // ------------------------------------------------------------------
    // AXI4-Lite slave - write channel (address+data accepted together;
    // a slave is always permitted to add wait states, so requiring both
    // AWVALID and WVALID before asserting either READY is fully compliant
    // and keeps this to a single simple, well-tested pattern).
    // ------------------------------------------------------------------
    reg axi_awready_r, axi_wready_r;
    reg [CTRL_ADDR_WIDTH-1:0] axi_awaddr_r;

    assign s_axi_ctrl_awready = axi_awready_r;
    assign s_axi_ctrl_wready  = axi_wready_r;

    always @(posedge clk) begin
        if (!resetn) begin
            axi_awready_r <= 1'b0;
            axi_wready_r  <= 1'b0;
            axi_awaddr_r  <= {CTRL_ADDR_WIDTH{1'b0}};
        end else begin
            if (!axi_awready_r && s_axi_ctrl_awvalid && s_axi_ctrl_wvalid) begin
                axi_awready_r <= 1'b1;
                axi_wready_r  <= 1'b1;
                axi_awaddr_r  <= s_axi_ctrl_awaddr;
            end else begin
                axi_awready_r <= 1'b0;
                axi_wready_r  <= 1'b0;
            end
        end
    end

    // rule-table index decode for a given control-port word address
    function integer rule_index_of;
        input [CTRL_ADDR_WIDTH-1:0] a;
        begin
            if (a >= 'h40 && a < ('h40 + NUM_RULES*16))
                rule_index_of = (a - 'h40) >> 4;
            else
                rule_index_of = -1;
        end
    endfunction

    integer k;
    integer widx;
    reg do_write;

    always @(posedge clk) begin
        if (!resetn) begin
            s_axi_ctrl_bvalid   <= 1'b0;
            s_axi_ctrl_bresp    <= 2'b00;
            timeout_ack         <= 1'b0;

            reg_global_enable   <= 1'b1;   // secure by default
            reg_auto_isolate_en <= 1'b1;
            reg_manual_isolate  <= 1'b0;
            reg_addr_violation  <= 1'b0;
            reg_perm_violation  <= 1'b0;
            reg_timeout_error   <= 1'b0;
            auto_isolate_latch  <= 1'b0;
            reg_irq_enable      <= 3'b111;
            reg_timeout_value   <= {TIMEOUT_WIDTH{1'b1}};
            reg_fault_addr      <= {ADDR_WIDTH{1'b0}};
            reg_fault_was_write <= 1'b0;
            reg_fault_type      <= 3'b000;

            for (k = 0; k < NUM_RULES; k = k + 1) begin
                rule_base[k]    <= {ADDR_WIDTH{1'b0}};
                rule_limit[k]   <= {ADDR_WIDTH{1'b0}};
                rule_valid_r[k] <= 1'b0;
                rule_rd_en[k]   <= 1'b0;
                rule_wr_en[k]   <= 1'b0;
            end
        end else begin
            timeout_ack <= 1'b0;   // default: single-cycle pulse

            // ---- hardware fault capture (highest priority; always wins
            //      the register-write in the same cycle if both occur) ----
            if (fault_addr_violation) begin
                reg_addr_violation <= 1'b1;
                reg_fault_addr     <= fault_addr_value;
                reg_fault_was_write<= fault_was_write;
                reg_fault_type     <= 3'b001;
            end
            if (fault_perm_violation) begin
                reg_perm_violation <= 1'b1;
                reg_fault_addr     <= fault_addr_value;
                reg_fault_was_write<= fault_was_write;
                reg_fault_type     <= 3'b010;
            end
            if (fault_timeout) begin
                reg_timeout_error  <= 1'b1;
                reg_fault_addr     <= fault_addr_value;
                reg_fault_was_write<= fault_was_write;
                reg_fault_type     <= 3'b011;
                if (reg_auto_isolate_en)
                    auto_isolate_latch <= 1'b1;
            end

            // ---- write channel ----
            do_write = axi_awready_r && s_axi_ctrl_awvalid &&
                       axi_wready_r  && s_axi_ctrl_wvalid  && !s_axi_ctrl_bvalid;

            if (do_write) begin
                s_axi_ctrl_bvalid <= 1'b1;
                s_axi_ctrl_bresp  <= 2'b00; // OKAY

                widx = rule_index_of(axi_awaddr_r);

                if (widx >= 0) begin
                    case (axi_awaddr_r[3:0])
                        4'h0: begin // RULE_BASE
                            if (s_axi_ctrl_wstrb[0]) rule_base[widx][7:0]   <= s_axi_ctrl_wdata[7:0];
                            if (s_axi_ctrl_wstrb[1]) rule_base[widx][15:8]  <= s_axi_ctrl_wdata[15:8];
                            if (s_axi_ctrl_wstrb[2]) rule_base[widx][23:16] <= s_axi_ctrl_wdata[23:16];
                            if (s_axi_ctrl_wstrb[3]) rule_base[widx][31:24] <= s_axi_ctrl_wdata[31:24];
                        end
                        4'h4: begin // RULE_LIMIT
                            if (s_axi_ctrl_wstrb[0]) rule_limit[widx][7:0]   <= s_axi_ctrl_wdata[7:0];
                            if (s_axi_ctrl_wstrb[1]) rule_limit[widx][15:8]  <= s_axi_ctrl_wdata[15:8];
                            if (s_axi_ctrl_wstrb[2]) rule_limit[widx][23:16] <= s_axi_ctrl_wdata[23:16];
                            if (s_axi_ctrl_wstrb[3]) rule_limit[widx][31:24] <= s_axi_ctrl_wdata[31:24];
                        end
                        4'h8: begin // RULE_PERM
                            if (s_axi_ctrl_wstrb[0]) begin
                                rule_rd_en[widx]   <= s_axi_ctrl_wdata[0];
                                rule_wr_en[widx]   <= s_axi_ctrl_wdata[1];
                                rule_valid_r[widx] <= s_axi_ctrl_wdata[2];
                            end
                        end
                        default: ; // reserved word, ignored
                    endcase
                end else begin
                    case (axi_awaddr_r)
                        'h00: begin // CTRL
                            if (s_axi_ctrl_wstrb[0]) begin
                                reg_global_enable   <= s_axi_ctrl_wdata[0];
                                reg_auto_isolate_en <= s_axi_ctrl_wdata[1];
                                reg_manual_isolate  <= s_axi_ctrl_wdata[2];
                            end
                        end
                        'h04: begin // STATUS (W1C on bits 2:0)
                            if (s_axi_ctrl_wstrb[0]) begin
                                if (s_axi_ctrl_wdata[0]) reg_addr_violation <= 1'b0;
                                if (s_axi_ctrl_wdata[1]) reg_perm_violation <= 1'b0;
                                if (s_axi_ctrl_wdata[2]) begin
                                    reg_timeout_error  <= 1'b0;
                                    auto_isolate_latch <= 1'b0; // ack fault -> release auto-isolate
                                    timeout_ack        <= 1'b1; // -> start downstream recovery
                                end
                            end
                        end
                        'h08: begin // IRQ_ENABLE
                            if (s_axi_ctrl_wstrb[0]) reg_irq_enable <= s_axi_ctrl_wdata[2:0];
                        end
                        'h0C: begin // TIMEOUT_VALUE
                            for (k = 0; k < TIMEOUT_WIDTH; k = k + 1)
                                if (s_axi_ctrl_wstrb[k/8]) reg_timeout_value[k] <= s_axi_ctrl_wdata[k];
                        end
                        default: ; // FAULT_ADDR/FAULT_INFO/CORE_INFO are read-only; others reserved
                    endcase
                end
            end else if (s_axi_ctrl_bready && s_axi_ctrl_bvalid) begin
                s_axi_ctrl_bvalid <= 1'b0;
            end

            // fault capture above must win over a same-cycle W1C of the
            // same bit; re-assert if both happened this cycle.
            if (fault_addr_violation) reg_addr_violation <= 1'b1;
            if (fault_perm_violation) reg_perm_violation <= 1'b1;
            if (fault_timeout)        reg_timeout_error  <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // AXI4-Lite slave - read channel
    // ------------------------------------------------------------------
    reg axi_arready_r;
    reg [CTRL_ADDR_WIDTH-1:0] axi_araddr_r;
    integer ridx;

    assign s_axi_ctrl_arready = axi_arready_r;

    always @(posedge clk) begin
        if (!resetn) begin
            axi_arready_r <= 1'b0;
            axi_araddr_r  <= {CTRL_ADDR_WIDTH{1'b0}};
        end else if (!axi_arready_r && s_axi_ctrl_arvalid) begin
            axi_arready_r <= 1'b1;
            axi_araddr_r  <= s_axi_ctrl_araddr;
        end else begin
            axi_arready_r <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            s_axi_ctrl_rvalid <= 1'b0;
            s_axi_ctrl_rresp  <= 2'b00;
            s_axi_ctrl_rdata  <= 32'h0;
        end else begin
            if (axi_arready_r && s_axi_ctrl_arvalid && !s_axi_ctrl_rvalid) begin
                s_axi_ctrl_rvalid <= 1'b1;
                s_axi_ctrl_rresp  <= 2'b00; // OKAY

                ridx = rule_index_of(axi_araddr_r);

                if (ridx >= 0) begin
                    case (axi_araddr_r[3:0])
                        4'h0: s_axi_ctrl_rdata <= rule_base[ridx];
                        4'h4: s_axi_ctrl_rdata <= rule_limit[ridx];
                        4'h8: s_axi_ctrl_rdata <= {29'b0, rule_valid_r[ridx], rule_wr_en[ridx], rule_rd_en[ridx]};
                        default: s_axi_ctrl_rdata <= 32'h0;
                    endcase
                end else begin
                    case (axi_araddr_r)
                        'h00: s_axi_ctrl_rdata <= {29'b0, reg_manual_isolate, reg_auto_isolate_en, reg_global_enable};
                        'h04: s_axi_ctrl_rdata <= {28'b0, isolate_effective, reg_timeout_error, reg_perm_violation, reg_addr_violation};
                        'h08: s_axi_ctrl_rdata <= {29'b0, reg_irq_enable};
                        'h0C: s_axi_ctrl_rdata <= {{(32-TIMEOUT_WIDTH){1'b0}}, reg_timeout_value};
                        'h10: s_axi_ctrl_rdata <= reg_fault_addr;
                        'h14: s_axi_ctrl_rdata <= {28'b0, reg_fault_type, reg_fault_was_write};
                        'h18: s_axi_ctrl_rdata <= {VERSION16, 8'h0, NUM_RULES[7:0]};
                        default: s_axi_ctrl_rdata <= 32'h0;
                    endcase
                end
            end else if (s_axi_ctrl_rready && s_axi_ctrl_rvalid) begin
                s_axi_ctrl_rvalid <= 1'b0;
            end
        end
    end

endmodule
