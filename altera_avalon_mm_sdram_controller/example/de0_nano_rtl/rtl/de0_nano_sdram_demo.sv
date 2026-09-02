`timescale 1ns/1ps

// =============================================================================
// de0_nano_sdram_demo.sv
//
// Top level of the SDRAM controller demonstration for the Terasic DE0-Nano
// (Intel Cyclone IV E EP4CE22F17C6) and its ISSI IS42S16160B - 32 MB, 16M x 16.
//
// This is the DE10-Lite demonstration on a different board and a different
// part. The sequencer, the master and the scenarios are the same files in
// example/common; what changes here is the pinout, the clocking, the address
// width and how the result is displayed.
//
// -----------------------------------------------------------------------------
// WHAT IS DIFFERENT FROM THE DE10-LITE, AND WHY
// -----------------------------------------------------------------------------
//   Part      IS42S16160B, a NINE-bit column against the DE10-Lite's ten. The
//             Avalon word address is therefore 24 bits, not 25, and the
//             scenarios that sweep a row or cross a bank follow COL_BITS.
//   Clock     DRAM_CLK is shifted -1667 ps, not -3000. Each board has its own
//             figure; see sdram_pll.sv.
//   Display   Eight LEDs and no seven-segment digits, so the board shows the
//             pass bitmap and nothing else. Everything the DE10-Lite puts on
//             its digits - scenario, pass/fail, failing address - is on JTAG,
//             which is what run_on_board.sh reads in any case.
//
// -----------------------------------------------------------------------------
// CLOCKING
// -----------------------------------------------------------------------------
//   CLOCK_50 -> PLL -> c0  100 MHz  0 deg    everything on-chip
//                   -> c1  100 MHz -1667 ps  DRAM_CLK, the chip's own pin
//
// -----------------------------------------------------------------------------
// BOARD CONTROLS
// -----------------------------------------------------------------------------
//   KEY[1]   reset (active low)
//   KEY[0]   start the selected scenario, or an auto sweep if SW[3] is up
//   SW[2:0]  scenario select, 0-7
//   SW[3]    auto: sweep every scenario in order from a cleared bitmap
//
//   LED[7:0] pass bitmap, one bit per scenario - or all eight blinking
//            together if the PLL has not locked, which no bitmap does.
//
// The DE10-Lite has a `freeze` switch that stops an auto sweep at the first
// failure. There is no spare switch here, so freeze is reachable over JTAG
// only. Everything else works from the board.
// =============================================================================

module de0_nano_sdram_demo (
    input  logic        CLOCK_50,

    input  logic [1:0]  KEY,
    input  logic [3:0]  SW,
    output logic [7:0]  LED,

    // ---- SDRAM ------------------------------------------------------------
    output logic [12:0] DRAM_ADDR,
    output logic [1:0]  DRAM_BA,
    output logic        DRAM_CAS_N,
    output logic        DRAM_CKE,
    output logic        DRAM_CLK,
    output logic        DRAM_CS_N,
    inout  wire  [15:0] DRAM_DQ,
    output logic [1:0]  DRAM_DQM,
    output logic        DRAM_RAS_N,
    output logic        DRAM_WE_N
);

    localparam int ADDR_WIDTH = 24;   // 4 banks x 8192 rows x 512 columns
    localparam int COL_BITS   = 9;    // IS42S16160B, half the DE10-Lite part
    localparam int DATA_WIDTH = 16;

    // ----------------------------------------------------------------------
    // Clocks
    // ----------------------------------------------------------------------
    logic clk, dram_clk, pll_locked;

    sdram_pll u_pll (
        .areset (~KEY[1]),
        .inclk0 (CLOCK_50),
        .c0     (clk),
        .c1     (dram_clk),
        .locked (pll_locked)
    );

    // DRAM_CLK is driven straight from the PLL output. Do not put logic in
    // this path: any added delay eats into the -1.667 ns budget.
    assign DRAM_CLK = dram_clk;

    // ----------------------------------------------------------------------
    // Reset. Held until the PLL locks, then released synchronously to clk.
    // The controller's own init sequence starts from this release, which is
    // why the sequencer additionally waits before its first access.
    // ----------------------------------------------------------------------
    logic rst_meta, rst_sync, resetn;
    always_ff @(posedge clk or negedge pll_locked) begin
        if (!pll_locked) begin
            rst_meta <= 1'b0;
            rst_sync <= 1'b0;
        end else begin
            rst_meta <= KEY[1];
            rst_sync <= rst_meta;
        end
    end
    assign resetn = rst_sync;

    // ----------------------------------------------------------------------
    // Board inputs
    // ----------------------------------------------------------------------
    logic [3:0] sw_meta, sw_s1;
    always_ff @(posedge clk) begin
        if (!resetn) begin
            sw_meta <= '0;
            sw_s1   <= '0;
        end else begin
            sw_meta <= SW;
            sw_s1   <= sw_meta;
        end
    end

    logic key_start_pulse;
    key_debounce #(.CNT_BITS(18)) u_key0 (   // 2^18 / 100 MHz = 2.6 ms
        .clk    (clk),
        .resetn (resetn),
        .key_n  (KEY[0]),
        .pulse  (key_start_pulse)
    );

    // ----------------------------------------------------------------------
    // In-System Sources and Probes
    //
    // Guarded by ENABLE_ISSP so a simulator never has to resolve the
    // altsource_probe primitive, for which there is no source.
    //
    //   probe[184:0] = { src_stable[7:0], perf_words[31:0], perf_rd_cycles[31:0],
    //                    perf_wr_cycles[31:0], fail_actual[15:0],
    //                    fail_expected[15:0], fail_addr[23:0], 1'b0,
    //                    err_code[2:0], done_count[3:0], pll_locked,
    //                    running, result_valid, result_pass,
    //                    cur_scenario[3:0], pass_bitmap[7:0] }
    //
    //   source[7:0]  = { seq_reset, start, freeze, auto, select[3:0] }
    //
    // done_count is the important one. It increments once per completed
    // scenario, so a host can start a scenario and wait for the counter to
    // MOVE, instead of watching `running` go high and then low. Watching a
    // level means racing the start pulse: read a moment too early and the
    // level has not risen yet, so "not running" reads as "already finished"
    // and the host samples the PREVIOUS scenario's result. A monotonic
    // counter has no such window. That failure mode cost real time in this
    // repository's firewall demo; it is designed out here.
    // ----------------------------------------------------------------------
    // Width follows the address, rather than being hand-counted: 160 fixed
    // bits plus one failing address. On this board that is 184, where the
    // DE10-Lite's 25-bit address makes it 185.
    localparam int PROBE_W = 160 + ADDR_WIDTH;
    logic [PROBE_W-1:0] issp_probe;
    logic [7:0]   issp_source;      // raw, straight off the JTAG shift register
    logic [7:0]   src_stable;       // what the design actually acts on

    // ----------------------------------------------------------------------
    // Sequencer <-> master
    // ----------------------------------------------------------------------
    logic                    cmd_valid, cmd_ready, cmd_write;
    logic [ADDR_WIDTH-1:0]   cmd_addr;
    logic [DATA_WIDTH-1:0]   cmd_wdata;
    logic [DATA_WIDTH/8-1:0] cmd_be;
    logic                    rsp_valid;
    logic [DATA_WIDTH-1:0]   rsp_data;

    // ---- master <-> sdram_perbank_sys s1 -----------------------------------------
    logic [ADDR_WIDTH-1:0]   avm_address;
    logic [DATA_WIDTH/8-1:0] avm_byteenable_n;
    logic                    avm_chipselect;
    logic [DATA_WIDTH-1:0]   avm_writedata;
    logic                    avm_read_n, avm_write_n;
    logic [DATA_WIDTH-1:0]   avm_readdata;
    logic                    avm_readdatavalid, avm_waitrequest;

    // ---- sequencer status -------------------------------------------------
    logic                    running, result_valid, result_pass;
    logic [3:0]              cur_scenario, done_count;
    logic [7:0]              pass_bitmap;
    logic [2:0]              err_code;
    logic [ADDR_WIDTH-1:0]   fail_addr;
    logic [DATA_WIDTH-1:0]   fail_expected, fail_actual;
    logic [31:0]             perf_wr_cycles, perf_rd_cycles, perf_words;

    // ----------------------------------------------------------------------
    // THE JTAG SOURCE REGISTER IS NOT UPDATED ATOMICALLY.
    //
    // altsource_probe shifts a new source value in over JTAG one bit at a
    // time, and with enable_metastability = "NO" those bits reach the design
    // as they land - there is no holding register between the scan chain and
    // the fabric. For a few microseconds the design therefore sees words that
    // were never written: a mixture of the old value and the new one.
    //
    // That matters here because bit 6 is a START edge and bits [3:0] choose
    // WHICH scenario to start. If bit 6 rises while the select bits are still
    // half-updated, the wrong scenario runs - and the host, which asked for
    // the right one, reads back a result that looks like a hardware failure.
    // Measured directly on this board: asking for scenario 4 ran scenario 3,
    // intermittently, with the frequency depending on JTAG timing.
    //
    // So the source word is filtered before anything uses it, exactly the way
    // key_debounce filters a mechanical button - it only counts as a new
    // value once it has held still for 256 consecutive clocks (2.56 us at
    // 100 MHz), which is far longer than a JTAG update takes to settle and
    // far shorter than any host notices.
    //
    // (This is a general hazard of altsource_probe, not a quirk of this
    // design. Any multi-bit source where one bit qualifies the others has it.)
    // ----------------------------------------------------------------------
    logic [7:0] src_q;
    logic [7:0] src_cnt;

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

    // The JTAG source is OR-ed with the physical controls rather than muxed,
    // so the switches keep working with nothing plugged in.
    logic [3:0] sel_eff;
    logic       auto_eff, freeze_eff;
    // Only three select bits on this board, so scenarios 8-15 - which do not
    // exist - are unreachable from the switches, and freeze is JTAG-only.
    assign sel_eff    = {1'b0, sw_s1[2:0]} | src_stable[3:0];
    assign auto_eff   = sw_s1[3]           | src_stable[4];
    assign freeze_eff =                      src_stable[5];

    logic issp_start_q, issp_start_pulse, start_pulse;
    always_ff @(posedge clk) begin
        if (!resetn) issp_start_q <= 1'b0;
        else         issp_start_q <= src_stable[6];
    end
    assign issp_start_pulse = src_stable[6] & ~issp_start_q;
    assign start_pulse      = key_start_pulse | issp_start_pulse;

    demo_sdram_seq #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .COL_BITS   (COL_BITS)
    ) u_seq (
        .clk            (clk),
        .resetn         (resetn),
        .select         (sel_eff),
        .auto_mode      (auto_eff),
        .freeze         (freeze_eff),
        .start_pulse    (start_pulse),
        .seq_reset      (src_stable[7]),
        .running        (running),
        .cur_scenario   (cur_scenario),
        .result_valid   (result_valid),
        .result_pass    (result_pass),
        .pass_bitmap    (pass_bitmap),
        .done_count     (done_count),
        .err_code       (err_code),
        .fail_addr      (fail_addr),
        .fail_expected  (fail_expected),
        .fail_actual    (fail_actual),
        .perf_wr_cycles (perf_wr_cycles),
        .perf_rd_cycles (perf_rd_cycles),
        .perf_words     (perf_words),
        .cmd_valid      (cmd_valid),
        .cmd_write      (cmd_write),
        .cmd_addr       (cmd_addr),
        .cmd_wdata      (cmd_wdata),
        .cmd_be         (cmd_be),
        .cmd_ready      (cmd_ready),
        .rsp_valid      (rsp_valid),
        .rsp_data       (rsp_data)
    );

    demo_avl_mm_master #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_master (
        .clk               (clk),
        .resetn            (resetn),
        .cmd_valid         (cmd_valid),
        .cmd_ready         (cmd_ready),
        .cmd_write         (cmd_write),
        .cmd_addr          (cmd_addr),
        .cmd_wdata         (cmd_wdata),
        .cmd_be            (cmd_be),
        .rsp_valid         (rsp_valid),
        .rsp_data          (rsp_data),
        .avm_address       (avm_address),
        .avm_byteenable_n  (avm_byteenable_n),
        .avm_chipselect    (avm_chipselect),
        .avm_writedata     (avm_writedata),
        .avm_read_n        (avm_read_n),
        .avm_write_n       (avm_write_n),
        .avm_readdata      (avm_readdata),
        .avm_readdatavalid (avm_readdatavalid),
        .avm_waitrequest   (avm_waitrequest)
    );

    // ----------------------------------------------------------------------
    // The Platform Designer system: the SDRAM controller, and nothing else.
    // Its s1 slave is exported rather than connected, because the master
    // above it is plain RTL.
    // ----------------------------------------------------------------------
    sdram_nano_sys u_sys (
        .clk_in_clk             (clk),
        .reset_in_reset_n       (resetn),
        .sdram_s1_address       (avm_address),
        .sdram_s1_byteenable_n  (avm_byteenable_n),
        .sdram_s1_chipselect    (avm_chipselect),
        .sdram_s1_writedata     (avm_writedata),
        .sdram_s1_read_n        (avm_read_n),
        .sdram_s1_write_n       (avm_write_n),
        .sdram_s1_readdata      (avm_readdata),
        .sdram_s1_readdatavalid (avm_readdatavalid),
        .sdram_s1_waitrequest   (avm_waitrequest),
        .sdram_wire_addr        (DRAM_ADDR),
        .sdram_wire_ba          (DRAM_BA),
        .sdram_wire_cas_n       (DRAM_CAS_N),
        .sdram_wire_cke         (DRAM_CKE),
        .sdram_wire_cs_n        (DRAM_CS_N),
        .sdram_wire_dq          (DRAM_DQ),
        .sdram_wire_dqm         (DRAM_DQM),
        .sdram_wire_ras_n       (DRAM_RAS_N),
        .sdram_wire_we_n        (DRAM_WE_N)
    );

    // ----------------------------------------------------------------------
    // ISSP
    // ----------------------------------------------------------------------
    assign issp_probe = {src_stable,            // 184:177
                         perf_words,            // 176:145
                         perf_rd_cycles,        // 144:113
                         perf_wr_cycles,        // 112:81
                         fail_actual,           //  80:65
                         fail_expected,         //  64:49
                         fail_addr,             //  48:24
                         1'b0,                  //     23
                         err_code,              //  22:20
                         done_count,            //  19:16
                         pll_locked,            //     15
                         running,               //     14
                         result_valid,          //     13
                         result_pass,           //     12
                         cur_scenario,          //  11:8
                         pass_bitmap};          //   7:0
    // src_stable is in the probe on purpose: it lets a host confirm that the
    // value it wrote is the value the design is acting on, which is what
    // turned the bug above from a mystery into a two-line fix.

`ifdef ENABLE_ISSP
    altsource_probe #(
        .sld_auto_instance_index ("YES"),
        .sld_instance_index      (0),
        .instance_id             ("SDRM"),
        .probe_width             (PROBE_W),
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

    // ----------------------------------------------------------------------
    // Board output
    //
    // Eight LEDs, one per scenario, showing the pass bitmap. There are no
    // digits on this board, so the scenario number, the pass/fail glyph and
    // the failing address that the DE10-Lite displays are not shown here -
    // they are in the JTAG probe, which is what actually gets read.
    //
    // The one state worth distinguishing on the board itself is "the PLL has
    // not locked", because then nothing else means anything. It BLINKS all
    // eight together rather than lighting a pattern: any static pattern is
    // also a legal pass bitmap, and blinking is not.
    // ----------------------------------------------------------------------
    logic [24:0] blink_cnt;
    always_ff @(posedge clk or negedge pll_locked) begin
        if (!pll_locked) blink_cnt <= blink_cnt + 25'd1;   // free-running
        else             blink_cnt <= '0;
    end

    always_comb begin
        if (!pll_locked) LED = {8{blink_cnt[24]}};   // ~1.5 Hz at 100 MHz
        else             LED = pass_bitmap;
    end

endmodule
