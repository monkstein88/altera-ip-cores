`timescale 1ns/1ps

// =============================================================================
// de10_lite_avl_mm_firewall_demo.sv
//
// Avalon-MM Firewall demonstration for the Terasic DE10-Lite
// (Intel MAX 10, 10M50DAF484C7G).
//
// The whole system is on-chip and needs no CPU, no Platform Designer system
// and no software:
//
//                      csr                          LEDR[8:0] = STATUS
//                 +-----------+                     LEDR[9]   = irq
//   demo_sequencer|           |
//   (plays the    +---------->| avl_mm_firewall_top |----> demo_target_slave
//    part of the  |   s0      |   (the IP core)     | m0    (the peripheral
//    driver)      +---------->|                     |        being protected,
//                             +---------------------+        with an injectable
//                                                            fault)
//
// The sequencer programs the rule table, runs sixteen scenarios against the
// firewall, and CHECKS EVERY RESPONSE against the core's documented register
// map. HEX4 shows P or F for the scenario named on HEX5. In auto-sweep mode
// HEX3..HEX0 accumulate a pass bitmap: 0xFFFF means all sixteen passed.
//
// Five of the sixteen are about burst behaviour, which is what this core has
// and its AXI4-Lite sibling does not: a burst that runs off the end of its
// window, two abutting permitted windows that deliberately do not merge, a
// window that allows single accesses but refuses bursts, and the core's
// one-beat-per-cycle throughput claim measured on real silicon.
//
// BOARD CONTROLS
// --------------
//   KEY1        system reset (active low)
//   KEY0        step mode: run the selected scenario. Auto mode: restart sweep.
//   SW[3:0]     scenario 0..F to run in step mode
//   SW[5]       0 = LEDR[8:0] show STATUS[8:0], 1 = show STATUS[9:1]
//   SW[6]       0 = HEX3..0 show the pass bitmap, 1 = show the observed word
//   SW[7]       with SW[6]=1: show the upper half of the observed word
//   SW[8]       freeze the auto sweep on the current scenario
//   SW[9]       0 = step mode, 1 = auto sweep
//   SW[4]       unused
//
//   HEX5        scenario index 0..F
//   HEX4        P = passed, F = failed, - = running, blank = no result yet
//   HEX3..HEX0  pass bitmap, or the last value the sequencer observed
//   LEDR[8:0]   live firewall STATUS, low nine bits with SW[5]=0:
//               0 ADDR_VIOLATION  1 PERM_VIOLATION  2 TIMEOUT_ERROR
//               3 BURST_VIOLATION 4 ISOLATED        5 BLOCKED
//               6 WR_BUSY         7 RD_BUSY         8 WR_CMD_STUCK
//   LEDR[9]     firewall irq
//
// STATUS is ten bits wide and the board has ten LEDs, one of which is spoken
// for by irq. SW[5] shifts the window up by one so RD_CMD_STUCK (bit 9) can be
// seen; scenario C checks it programmatically either way.
//
// All switch inputs are resynchronised here; nothing downstream sees a raw pin.
// =============================================================================

module de10_lite_avl_mm_firewall_demo #(
    // Overridden by the testbench to keep simulation short. On the board the
    // defaults give a ~168 ms pause between scenarios and a 2.6 ms debounce.
    parameter int PACE_BITS      = 23,
    parameter int DEBOUNCE_BITS  = 17,
    parameter int TIMEOUT_CYCLES = 200,
    parameter int THRU_GUARD     = 24,
    parameter int BURST_BEATS    = 16
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

    // Twelve bits, not thirty-two, and this is the single biggest lever on
    // Fmax in the whole design.
    //
    // The core's critical path is the combinational rule lookup: the burst
    // extent adder, then NUM_RULES pairs of address comparators (this core
    // checks the FIRST and LAST byte of every transaction, so two per rule),
    // then the verdict. Every one of those carry chains is ADDR_WIDTH bits
    // long. The protected peripheral occupies 256 bytes, so a 32-bit address
    // space buys nothing and costs most of the timing margin.
    localparam int ADDR_WIDTH         = 12;
    localparam int DATA_WIDTH         = 32;
    localparam int BURST_WIDTH        = 8;    // max burst 128 beats
    localparam int CSR_ADDR_WIDTH     = 8;    // words; covers 0x10 + 8*4 = 48
    // Five, not eight, and the reason is measured rather than aesthetic.
    //
    // The core's critical path is the combinational rule lookup, and it grows
    // with NUM_RULES - the README says so, and this demo is where it bites.
    // At NUM_RULES = 8 the design misses 50 MHz on this C7 part by 0.33 ns,
    // with the failing path running from the master's address register through
    // the lookup to the firewall's denied-read beat counter. The rule table
    // here needs exactly five windows, and using five closes timing with room
    // to spare. "Use the smallest NUM_RULES that covers your map" is advice
    // with a number behind it.
    localparam int NUM_RULES          = 5;
    localparam int TIMEOUT_WIDTH      = 20;
    localparam int MAX_PENDING_READS  = 4;
    localparam int USE_WRITE_RESPONSE = 1;
    localparam int MEM_WORDS          = 64;   // 0x00..0xFF, covers every window

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
    // which simulators start from - not a continuous assignment.
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
    // core's README documents this exact trap.
    logic [3:0]  cur_scenario;
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
    // 33 bits, not 32, and the extra one is load-bearing: STATUS is ten bits
    // wide and RD_CMD_STUCK is bit 9. A 32-bit probe carrying status[8:0]
    // cannot see it, so the one bit that scenario C exists to demonstrate
    // would be invisible to the hardware regression - checkable by eye with
    // SW[5], and by nothing else.
    logic [32:0] issp_probe;
    logic [7:0]  issp_source;

    assign issp_probe = {status_shadow[9:0],   // 32:23
                         running,              // 22
                         result_valid,         // 21
                         result_pass,          // 20
                         cur_scenario,         // 19:16
                         pass_bitmap};         // 15:0

`ifdef ENABLE_ISSP
    altsource_probe #(
        .sld_auto_instance_index ("YES"),
        .sld_instance_index      (0),
        .instance_id             ("AVFW"),
        .probe_width             (33),
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

    logic issp_start_q, issp_start_pulse, start_pulse;
    always_ff @(posedge clk) begin
        if (!resetn) issp_start_q <= 1'b0;
        else         issp_start_q <= issp_source[6];
    end
    assign issp_start_pulse = issp_source[6] & ~issp_start_q;
    assign start_pulse      = key_start_pulse | issp_start_pulse;

    // The JTAG source can override the switches. OR-ed, not muxed, so the
    // physical controls keep working with nothing attached.
    logic [3:0] sel_eff;
    logic       auto_eff, freeze_eff;
    assign sel_eff    = sw_s1[3:0] | issp_source[3:0];
    assign auto_eff   = sw_s1[9]   | issp_source[4];
    assign freeze_eff = sw_s1[8]   | issp_source[5];

    // ------------------------------------------------------------------
    // csr: sequencer -> firewall control port (word-addressed)
    // ------------------------------------------------------------------
    logic [CSR_ADDR_WIDTH-1:0] c_address;
    logic                      c_read, c_write;
    logic [31:0]               c_writedata, c_readdata;
    logic [3:0]                c_byteenable;

    // ------------------------------------------------------------------
    // s0: sequencer -> firewall data path
    // ------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0]     d_address;
    logic                      d_read, d_write;
    logic [DATA_WIDTH-1:0]     d_writedata, d_readdata;
    logic [DATA_WIDTH/8-1:0]   d_byteenable;
    logic [BURST_WIDTH-1:0]    d_burstcount;
    logic                      d_waitrequest, d_readdatavalid, d_writeresponsevalid;
    logic [1:0]                d_response;

    // ------------------------------------------------------------------
    // m0: firewall -> protected peripheral
    // ------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0]     p_address;
    logic                      p_read, p_write;
    logic [DATA_WIDTH-1:0]     p_writedata, p_readdata;
    logic [DATA_WIDTH/8-1:0]   p_byteenable;
    logic [BURST_WIDTH-1:0]    p_burstcount;
    logic                      p_waitrequest, p_readdatavalid, p_writeresponsevalid;
    logic [1:0]                p_response;

    logic fw_irq;
    logic periph_resetn, periph_hang, periph_hang_late;
    logic new_cmd_seen, watch_clear;

    // ------------------------------------------------------------------
    // Downstream command watcher.
    //
    // Scenarios 8, 9, A and d assert that a denied or blocked transaction
    // never reaches the peripheral. It has to be an edge detector, not a
    // level: the m0_write left over from a transaction that timed out stays
    // asserted - Avalon-MM forbids withdrawing a command whose waitrequest
    // never fell - so a level check would report a command that is merely
    // still there as a command newly issued.
    // ------------------------------------------------------------------
    logic p_write_q, p_read_q;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            p_write_q    <= 1'b0;
            p_read_q     <= 1'b0;
            new_cmd_seen <= 1'b0;
        end else begin
            p_write_q <= p_write;
            p_read_q  <= p_read;
            if (watch_clear)
                new_cmd_seen <= 1'b0;
            else if ((p_write && !p_write_q) || (p_read && !p_read_q))
                new_cmd_seen <= 1'b1;
        end
    end

    // ==================================================================
    // The IP core under demonstration
    //
    // Referenced from ../../../rtl/ by the Quartus project, so the demo always
    // builds whatever is actually in the repository - there is no private copy
    // of the core here to drift.
    // ==================================================================
    avl_mm_firewall_top #(
        .ADDR_WIDTH         (ADDR_WIDTH),
        .DATA_WIDTH         (DATA_WIDTH),
        .BURST_WIDTH        (BURST_WIDTH),
        .MAX_PENDING_READS  (MAX_PENDING_READS),
        .NUM_RULES          (NUM_RULES),
        .TIMEOUT_WIDTH      (TIMEOUT_WIDTH),
        .CSR_ADDR_WIDTH     (CSR_ADDR_WIDTH),
        .USE_WRITE_RESPONSE (USE_WRITE_RESPONSE)
    ) u_fw (
        .clk     (clk),
        .reset_n (resetn),

        .s0_address           (d_address),
        .s0_read              (d_read),
        .s0_write             (d_write),
        .s0_writedata         (d_writedata),
        .s0_byteenable        (d_byteenable),
        .s0_burstcount        (d_burstcount),
        .s0_waitrequest       (d_waitrequest),
        .s0_readdata          (d_readdata),
        .s0_readdatavalid     (d_readdatavalid),
        .s0_response          (d_response),
        .s0_writeresponsevalid(d_writeresponsevalid),

        .m0_address           (p_address),
        .m0_read              (p_read),
        .m0_write             (p_write),
        .m0_writedata         (p_writedata),
        .m0_byteenable        (p_byteenable),
        .m0_burstcount        (p_burstcount),
        .m0_waitrequest       (p_waitrequest),
        .m0_readdata          (p_readdata),
        .m0_readdatavalid     (p_readdatavalid),
        .m0_response          (p_response),
        .m0_writeresponsevalid(p_writeresponsevalid),

        .csr_address    (c_address),
        .csr_read       (c_read),
        .csr_write      (c_write),
        .csr_writedata  (c_writedata),
        .csr_byteenable (c_byteenable),
        .csr_readdata   (c_readdata),

        .irq (fw_irq)
    );

    // ==================================================================
    // The peripheral being protected
    // ==================================================================
    demo_target_slave #(
        .ADDR_WIDTH         (ADDR_WIDTH),
        .DATA_WIDTH         (DATA_WIDTH),
        .BURST_WIDTH        (BURST_WIDTH),
        .MEM_WORDS          (MEM_WORDS),
        .USE_WRITE_RESPONSE (USE_WRITE_RESPONSE)
    ) u_slave (
        .clk         (clk),
        .resetn      (resetn),
        .soft_resetn (periph_resetn),
        .hang        (periph_hang),
        .hang_late   (periph_hang_late),

        .s_address            (p_address),
        .s_read               (p_read),
        .s_write              (p_write),
        .s_writedata          (p_writedata),
        .s_byteenable         (p_byteenable),
        .s_burstcount         (p_burstcount),
        .s_waitrequest        (p_waitrequest),
        .s_readdata           (p_readdata),
        .s_readdatavalid      (p_readdatavalid),
        .s_response           (p_response),
        .s_writeresponsevalid (p_writeresponsevalid)
    );

    // ==================================================================
    // The demo's "software"
    // ==================================================================
    demo_sequencer #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .DATA_WIDTH     (DATA_WIDTH),
        .BURST_WIDTH    (BURST_WIDTH),
        .CSR_ADDR_WIDTH (CSR_ADDR_WIDTH),
        .TIMEOUT_CYCLES (TIMEOUT_CYCLES),
        .THRU_GUARD     (THRU_GUARD),
        .BURST_BEATS    (BURST_BEATS),
        .PACE_BITS      (PACE_BITS)
    ) u_seq (
        .clk    (clk),
        .resetn (resetn),

        .start     (start_pulse),
        .select    (sel_eff),
        .auto_mode (auto_eff),
        .freeze    (freeze_eff),

        .cur_scenario  (cur_scenario),
        .running       (running),
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

        .fw_irq (fw_irq),

        .c_address    (c_address),
        .c_read       (c_read),
        .c_write      (c_write),
        .c_writedata  (c_writedata),
        .c_byteenable (c_byteenable),
        .c_readdata   (c_readdata),

        .d_address            (d_address),
        .d_read               (d_read),
        .d_write              (d_write),
        .d_writedata          (d_writedata),
        .d_byteenable         (d_byteenable),
        .d_burstcount         (d_burstcount),
        .d_waitrequest        (d_waitrequest),
        .d_readdata           (d_readdata),
        .d_readdatavalid      (d_readdatavalid),
        .d_response           (d_response),
        .d_writeresponsevalid (d_writeresponsevalid)
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

    // STATUS is ten bits and only nine LEDs are free, so SW[5] slides the
    // window up by one to expose RD_CMD_STUCK.
    assign LEDR = {fw_irq, sw_s1[5] ? status_shadow[9:1] : status_shadow[8:0]};

    // SW[4] is reserved for future scenarios; tie it off explicitly so
    // Quartus reports it as intentionally unused rather than as dangling.
    logic unused_sw;
    assign unused_sw = sw_s1[4];

endmodule
