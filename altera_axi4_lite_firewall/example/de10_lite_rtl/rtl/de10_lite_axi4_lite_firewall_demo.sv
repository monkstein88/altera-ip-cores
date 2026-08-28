`timescale 1ns/1ps

// =============================================================================
// de10_lite_axi4_lite_firewall_demo.sv
//
// AXI4-Lite Firewall demonstration for the Terasic DE10-Lite
// (Intel MAX 10, 10M50DAF484C7G).
//
// The whole system is on-chip and needs no CPU, no Platform Designer system
// and no software:
//
//                  s_axi_ctrl                       LEDR[8:0] = STATUS[8:0]
//                 +-----------+                     LEDR[9]   = irq
//   demo_sequencer|           |
//   (plays the    +---------->| axi4_lite_firewall_top |------> demo_axi4_lite_target_slave
//    part of the  |  s_axi     |   (the IP core)  | m_axi   (the peripheral
//    driver)      +---------->|                  |          being protected,
//                             +------------------+          with an injectable
//                                                           fault)
//
// The sequencer programs the rule table, runs sixteen scenarios against the
// firewall, and CHECKS EVERY RESPONSE against the core's documented register
// map. HEX4 shows P or F for the scenario named on HEX5. In auto-sweep mode
// HEX3..HEX0 accumulate a pass bitmap: 0xFFFF means all sixteen passed.
//
// BOARD CONTROLS
// --------------
//   KEY1        system reset (active low)
//   KEY0        step mode: run the selected scenario. Auto mode: restart sweep.
//   SW[3:0]     scenario 0..F to run in step mode
//   SW[6]       0 = HEX3..0 show the pass bitmap, 1 = show the observed word
//   SW[7]       with SW[6]=1: show the upper half of the observed word
//   SW[8]       freeze the auto sweep on the current scenario
//   SW[9]       0 = step mode, 1 = auto sweep
//   SW[5:4]     unused
//
//   HEX5        scenario index 0..F
//   HEX4        P = passed, F = failed, - = running, blank = no result yet
//   HEX3..HEX0  pass bitmap, or the last value the sequencer observed
//   LEDR[8:0]   live firewall STATUS[8:0]:
//               0 ADDR_VIOLATION  1 PERM_VIOLATION  2 TIMEOUT_ERROR
//               3 ISOLATED  4 BLOCKED  5 WR_RESP_BUSY  6 RD_RESP_BUSY
//               7 WR_CMD_STUCK  8 RD_CMD_STUCK
//   LEDR[9]     firewall irq
//
// All switch inputs are resynchronised here; nothing downstream sees a raw pin.
// =============================================================================

module de10_lite_axi4_lite_firewall_demo #(
    // Overridden by the testbench to keep simulation short. On the board the
    // defaults give a ~168 ms pause between scenarios and a 2.6 ms debounce.
    parameter int PACE_BITS      = 23,
    parameter int DEBOUNCE_BITS  = 17,
    parameter int TIMEOUT_CYCLES = 200
) (
    input  logic       MAX10_CLK1_50,
    input  logic [1:0] KEY,
    input  logic [9:0] SW,
    output logic [9:0] LEDR,
    output logic [7:0] HEX0,
    output logic [7:0] HEX1,
    output logic [7:0] HEX2,
    output logic [7:0] HEX3,
    output logic [7:0] HEX4,
    output logic [7:0] HEX5
);

    localparam int ADDR_WIDTH      = 32;
    localparam int DATA_WIDTH      = 32;
    localparam int CTRL_ADDR_WIDTH = 12;
    localparam int NUM_RULES       = 8;
    localparam int TIMEOUT_WIDTH   = 20;
    localparam int MEM_WORDS       = 16;

    // Seven-segment glyph codes above 0xF (see hex7seg.sv)
    localparam logic [4:0] GL_BLANK = 5'd16;
    localparam logic [4:0] GL_PASS  = 5'd17;
    localparam logic [4:0] GL_FAIL  = 5'd18;
    localparam logic [4:0] GL_RUN   = 5'd19;

    logic clk;
    assign clk = MAX10_CLK1_50;

    // ------------------------------------------------------------------
    // Reset. KEY1 is the manual reset; the shift register holds the design
    // in reset for the first few clocks after configuration.
    //
    // `= '0` here is a REGISTER power-up value, which Quartus honours and
    // which simulators start from - not the `logic x = expr;` continuous
    // assignment trap the core's README warns about. That trap is about
    // combinational signals; this is a flop with an initial state.
    // ------------------------------------------------------------------
    logic [7:0] por_sr = '0;
    logic       key1_s0 = 1'b0, key1_s1 = 1'b0;

    always_ff @(posedge clk) begin
        por_sr  <= {por_sr[6:0], 1'b1};
        key1_s0 <= KEY[1];
        key1_s1 <= key1_s0;
    end

    logic resetn;
    assign resetn = por_sr[7] & key1_s1;

    // ------------------------------------------------------------------
    // Operator inputs
    // ------------------------------------------------------------------
    logic [9:0] sw_s0, sw_s1;
    always_ff @(posedge clk) begin
        sw_s0 <= SW;
        sw_s1 <= sw_s0;
    end

    logic key_start_pulse;
    key_debounce #(.CNT_BITS(DEBOUNCE_BITS)) u_key0 (
        .clk    (clk),
        .resetn (resetn),
        .key_n  (KEY[0]),
        .pulse  (key_start_pulse)
    );

    // Sequencer outputs. Declared HERE, above the probe block below, because
    // referencing an identifier before its declaration creates an implicit net
    // that then collides with the real declaration. Verilator resolves the
    // forward reference and says nothing; Questa rejects it outright. The
    // core's README documents this exact trap - it is why the toolchain has
    // three front ends rather than one.
    logic [3:0]  cur_scenario;
    logic [3:0]  done_count;
    logic        running, result_valid, result_pass;
    logic [15:0] pass_bitmap;
    logic [31:0] obs, status_shadow;

    // ------------------------------------------------------------------
    // In-System Sources and Probes: the same controls and results, over JTAG.
    //
    // Without this the only way to read this demo's result is to look at the
    // board, which makes it impossible to regression-test on real hardware
    // from a script - and the scenarios worth watching are precisely the ones
    // that involve deliberately wedging a peripheral.
    //
    // The sources are OR-ed with the physical switches rather than replacing
    // them, so the board still works exactly as before with nothing attached.
    // `issp_start` is a level held by the JTAG source register, so it is
    // edge-detected here; the debounced button already produces a pulse.
    //
    // Guarded by `ENABLE_ISSP` so simulation never sees the megafunction:
    // altsource_probe is an Altera primitive that Verilator and Questa have
    // no source for, and a dead generate block would not save them from
    // having to resolve it.
    // ------------------------------------------------------------------
    logic [35:0] issp_probe;
    logic [7:0]  issp_source;

    assign issp_probe = {done_count,           // 35:32
                         status_shadow[8:0],   // 31:23
                         running,              // 22
                         result_valid,         // 21
                         result_pass,          // 20
                         cur_scenario,         // 19:16
                         pass_bitmap};         // 15:0

`ifdef ENABLE_ISSP
    altsource_probe #(
        .sld_auto_instance_index ("YES"),
        .sld_instance_index      (0),
        .instance_id             ("FWDM"),
        .probe_width             (36),
        .source_width            (8),
        .source_initial_value    ("0"),
        .enable_metastability    ("NO")
    ) u_issp (
        .probe  (issp_probe),
        .source (issp_source)
    );
`else
    assign issp_source = 8'h00;
`endif

    // ------------------------------------------------------------------
    // THE JTAG SOURCE REGISTER IS NOT UPDATED ATOMICALLY.
    //
    // altsource_probe shifts a new source value in over JTAG one bit at a
    // time, and with enable_metastability = "NO" those bits reach the design
    // as they land - there is no holding register between the scan chain and
    // the fabric. For a few microseconds the design therefore sees words that
    // were never written: a mixture of the old value and the new one.
    //
    // Bit 6 is a START edge and bits [3:0] choose WHICH scenario to start, so
    // if bit 6 rises while the select bits are still half-updated, the wrong
    // scenario runs - and the host, which asked for the right one, reads back
    // a result that looks like a firewall failure.
    //
    // This was isolated on this repository's SDRAM controller example, which
    // has the same construct, by asking for scenario 4 and watching scenario
    // 3 run. It is a general hazard of altsource_probe, not a quirk of any
    // one design: any multi-bit source where one bit qualifies the others has
    // it.
    //
    // The source word is therefore filtered before anything uses it, exactly
    // the way key_debounce filters a mechanical button: a new value only
    // counts once it has held still for 256 consecutive clocks (5.1 us at
    // 50 MHz), far longer than a JTAG update takes to settle and far shorter
    // than any host notices.
    // ------------------------------------------------------------------
    logic [7:0] src_stable, src_q, src_cnt;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            src_q      <= 8'h00;
            src_cnt    <= 8'h00;
            src_stable <= 8'h00;
        end else begin
            src_q <= issp_source;
            if (issp_source != src_q)   src_cnt    <= 8'h00;      // still moving
            else if (!(&src_cnt))       src_cnt    <= src_cnt + 8'd1;
            else                        src_stable <= src_q;      // held still: accept
        end
    end

    logic issp_start_q, issp_start_pulse, start_pulse;
    always_ff @(posedge clk) begin
        if (!resetn) issp_start_q <= 1'b0;
        else         issp_start_q <= src_stable[6];
    end
    assign issp_start_pulse = src_stable[6] & ~issp_start_q;
    assign start_pulse      = key_start_pulse | issp_start_pulse;

    // ------------------------------------------------------------------
    // s_axi_ctrl: sequencer -> firewall control port
    // ------------------------------------------------------------------
    logic [CTRL_ADDR_WIDTH-1:0] c_awaddr, c_araddr;
    logic [2:0]                 c_awprot, c_arprot;
    logic                       c_awvalid, c_awready, c_arvalid, c_arready;
    logic [31:0]                c_wdata, c_rdata;
    logic [3:0]                 c_wstrb;
    logic                       c_wvalid, c_wready;
    logic [1:0]                 c_bresp, c_rresp;
    logic                       c_bvalid, c_bready, c_rvalid, c_rready;

    // ------------------------------------------------------------------
    // s_axi: sequencer -> firewall data path
    // ------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0]      d_awaddr, d_araddr;
    logic [2:0]                 d_awprot, d_arprot;
    logic                       d_awvalid, d_awready, d_arvalid, d_arready;
    logic [DATA_WIDTH-1:0]      d_wdata, d_rdata;
    logic [DATA_WIDTH/8-1:0]    d_wstrb;
    logic                       d_wvalid, d_wready;
    logic [1:0]                 d_bresp, d_rresp;
    logic                       d_bvalid, d_bready, d_rvalid, d_rready;

    // ------------------------------------------------------------------
    // m_axi: firewall -> protected peripheral
    // ------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0]      p_awaddr, p_araddr;
    logic [2:0]                 p_awprot, p_arprot;
    logic                       p_awvalid, p_awready, p_arvalid, p_arready;
    logic [DATA_WIDTH-1:0]      p_wdata, p_rdata;
    logic [DATA_WIDTH/8-1:0]    p_wstrb;
    logic                       p_wvalid, p_wready;
    logic [1:0]                 p_bresp, p_rresp;
    logic                       p_bvalid, p_bready, p_rvalid, p_rready;

    logic fw_irq;
    logic periph_resetn, periph_hang, periph_hang_late;
    logic new_cmd_seen, watch_clear;


    // ------------------------------------------------------------------
    // Downstream command watcher.
    //
    // Scenario A asserts that while the downstream is blocked, no NEW command
    // reaches the peripheral. It has to be an edge detector, not a level: the
    // AWVALID left over from the transaction that timed out stays asserted -
    // AXI forbids withdrawing it - so a level check would report a command
    // that is merely still there as a command newly issued.
    // ------------------------------------------------------------------
    logic p_awvalid_q, p_arvalid_q;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            p_awvalid_q  <= 1'b0;
            p_arvalid_q  <= 1'b0;
            new_cmd_seen <= 1'b0;
        end else begin
            p_awvalid_q <= p_awvalid;
            p_arvalid_q <= p_arvalid;
            if (watch_clear)
                new_cmd_seen <= 1'b0;
            else if ((p_awvalid && !p_awvalid_q) || (p_arvalid && !p_arvalid_q))
                new_cmd_seen <= 1'b1;
        end
    end

    // ==================================================================
    // The IP core under demonstration
    // ==================================================================
    axi4_lite_firewall_top #(
        .ADDR_WIDTH      (ADDR_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .CTRL_ADDR_WIDTH (CTRL_ADDR_WIDTH),
        .NUM_RULES       (NUM_RULES),
        .TIMEOUT_WIDTH   (TIMEOUT_WIDTH)
    ) u_firewall (
        .clk    (clk),
        .resetn (resetn),

        .s_axi_awaddr (d_awaddr),  .s_axi_awprot (d_awprot),
        .s_axi_awvalid(d_awvalid), .s_axi_awready(d_awready),
        .s_axi_wdata  (d_wdata),   .s_axi_wstrb  (d_wstrb),
        .s_axi_wvalid (d_wvalid),  .s_axi_wready (d_wready),
        .s_axi_bresp  (d_bresp),   .s_axi_bvalid (d_bvalid),  .s_axi_bready(d_bready),
        .s_axi_araddr (d_araddr),  .s_axi_arprot (d_arprot),
        .s_axi_arvalid(d_arvalid), .s_axi_arready(d_arready),
        .s_axi_rdata  (d_rdata),   .s_axi_rresp  (d_rresp),
        .s_axi_rvalid (d_rvalid),  .s_axi_rready (d_rready),

        .m_axi_awaddr (p_awaddr),  .m_axi_awprot (p_awprot),
        .m_axi_awvalid(p_awvalid), .m_axi_awready(p_awready),
        .m_axi_wdata  (p_wdata),   .m_axi_wstrb  (p_wstrb),
        .m_axi_wvalid (p_wvalid),  .m_axi_wready (p_wready),
        .m_axi_bresp  (p_bresp),   .m_axi_bvalid (p_bvalid),  .m_axi_bready(p_bready),
        .m_axi_araddr (p_araddr),  .m_axi_arprot (p_arprot),
        .m_axi_arvalid(p_arvalid), .m_axi_arready(p_arready),
        .m_axi_rdata  (p_rdata),   .m_axi_rresp  (p_rresp),
        .m_axi_rvalid (p_rvalid),  .m_axi_rready (p_rready),

        .s_axi_ctrl_awaddr (c_awaddr),  .s_axi_ctrl_awprot (c_awprot),
        .s_axi_ctrl_awvalid(c_awvalid), .s_axi_ctrl_awready(c_awready),
        .s_axi_ctrl_wdata  (c_wdata),   .s_axi_ctrl_wstrb  (c_wstrb),
        .s_axi_ctrl_wvalid (c_wvalid),  .s_axi_ctrl_wready (c_wready),
        .s_axi_ctrl_bresp  (c_bresp),   .s_axi_ctrl_bvalid (c_bvalid),
        .s_axi_ctrl_bready (c_bready),
        .s_axi_ctrl_araddr (c_araddr),  .s_axi_ctrl_arprot (c_arprot),
        .s_axi_ctrl_arvalid(c_arvalid), .s_axi_ctrl_arready(c_arready),
        .s_axi_ctrl_rdata  (c_rdata),   .s_axi_ctrl_rresp  (c_rresp),
        .s_axi_ctrl_rvalid (c_rvalid),  .s_axi_ctrl_rready (c_rready),

        .irq (fw_irq)
    );

    // ==================================================================
    // The peripheral being protected
    // ==================================================================
    demo_axi4_lite_target_slave #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .MEM_WORDS  (MEM_WORDS)
    ) u_target (
        .clk         (clk),
        .resetn      (resetn),           // system reset
        .soft_resetn (periph_resetn),    // software-controlled, from the sequencer
        .hang        (periph_hang),
        .hang_late   (periph_hang_late),

        .s_awaddr (p_awaddr),  .s_awprot (p_awprot),
        .s_awvalid(p_awvalid), .s_awready(p_awready),
        .s_wdata  (p_wdata),   .s_wstrb  (p_wstrb),
        .s_wvalid (p_wvalid),  .s_wready (p_wready),
        .s_bresp  (p_bresp),   .s_bvalid (p_bvalid),  .s_bready(p_bready),
        .s_araddr (p_araddr),  .s_arprot (p_arprot),
        .s_arvalid(p_arvalid), .s_arready(p_arready),
        .s_rdata  (p_rdata),   .s_rresp  (p_rresp),
        .s_rvalid (p_rvalid),  .s_rready (p_rready)
    );

    // ==================================================================
    // The demo's "driver"
    // ==================================================================
    demo_sequencer #(
        .ADDR_WIDTH      (ADDR_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .CTRL_ADDR_WIDTH (CTRL_ADDR_WIDTH),
        .TIMEOUT_CYCLES  (TIMEOUT_CYCLES),
        .PACE_BITS       (PACE_BITS)
    ) u_seq (
        .clk    (clk),
        .resetn (resetn),

        .start     (start_pulse),
        .select    (sw_s1[3:0] | src_stable[3:0]),
        .auto_mode (sw_s1[9]   | src_stable[4]),
        .freeze    (sw_s1[8]   | src_stable[5]),

        .cur_scenario  (cur_scenario),
        .running       (running),
        .done_count    (done_count),
        .result_valid  (result_valid),
        .result_pass   (result_pass),
        .pass_bitmap   (pass_bitmap),
        .obs           (obs),
        .status_shadow (status_shadow),

        .periph_resetn    (periph_resetn),
        .periph_hang      (periph_hang),
        .periph_hang_late (periph_hang_late),

        .new_cmd_seen (new_cmd_seen),
        .watch_clear  (watch_clear),
        .fw_irq       (fw_irq),

        .c_awaddr(c_awaddr),  .c_awprot(c_awprot),
        .c_awvalid(c_awvalid),.c_awready(c_awready),
        .c_wdata (c_wdata),   .c_wstrb (c_wstrb),
        .c_wvalid(c_wvalid),  .c_wready(c_wready),
        .c_bresp (c_bresp),   .c_bvalid(c_bvalid),  .c_bready(c_bready),
        .c_araddr(c_araddr),  .c_arprot(c_arprot),
        .c_arvalid(c_arvalid),.c_arready(c_arready),
        .c_rdata (c_rdata),   .c_rresp (c_rresp),
        .c_rvalid(c_rvalid),  .c_rready(c_rready),

        .d_awaddr(d_awaddr),  .d_awprot(d_awprot),
        .d_awvalid(d_awvalid),.d_awready(d_awready),
        .d_wdata (d_wdata),   .d_wstrb (d_wstrb),
        .d_wvalid(d_wvalid),  .d_wready(d_wready),
        .d_bresp (d_bresp),   .d_bvalid(d_bvalid),  .d_bready(d_bready),
        .d_araddr(d_araddr),  .d_arprot(d_arprot),
        .d_arvalid(d_arvalid),.d_arready(d_arready),
        .d_rdata (d_rdata),   .d_rresp (d_rresp),
        .d_rvalid(d_rvalid),  .d_rready(d_rready)
    );

    // ==================================================================
    // Display
    // ==================================================================
    logic [15:0] disp_word;
    always_comb begin
        if (!sw_s1[6])      disp_word = pass_bitmap;
        else if (!sw_s1[7]) disp_word = obs[15:0];
        else                disp_word = obs[31:16];
    end

    logic [4:0] code4;
    always_comb begin
        if (running)             code4 = GL_RUN;
        else if (!result_valid)  code4 = GL_BLANK;
        else if (result_pass)    code4 = GL_PASS;
        else                     code4 = GL_FAIL;
    end

    hex7seg u_hex0 (.code({1'b0, disp_word[3:0]}),   .hex(HEX0));
    hex7seg u_hex1 (.code({1'b0, disp_word[7:4]}),   .hex(HEX1));
    hex7seg u_hex2 (.code({1'b0, disp_word[11:8]}),  .hex(HEX2));
    hex7seg u_hex3 (.code({1'b0, disp_word[15:12]}), .hex(HEX3));
    hex7seg u_hex4 (.code(code4),                    .hex(HEX4));
    hex7seg u_hex5 (.code({1'b0, cur_scenario}),     .hex(HEX5));

    assign LEDR = {fw_irq, status_shadow[8:0]};

    // SW[5:4] are reserved for future scenarios; tie them off explicitly so
    // Quartus reports them as intentionally unused rather than as dangling.
    logic unused_sw;
    assign unused_sw = ^sw_s1[5:4];

endmodule
