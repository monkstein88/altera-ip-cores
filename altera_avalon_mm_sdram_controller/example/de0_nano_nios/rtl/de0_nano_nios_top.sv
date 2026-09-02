`timescale 1ns/1ps

// =============================================================================
// de0_nano_nios_top.sv
//
// Board wrapper for the Nios II SDRAM controller example on the Terasic
// DE0-Nano (Intel Cyclone IV E, EP4CE22F17C6) and its ISSI IS42S16160B.
//
// Everything of interest is inside the Platform Designer system: the CPU, the
// on-chip RAM it runs from, and the SDRAM controller it tests. This file
// connects that system to pins and does the three things Platform Designer
// cannot do for itself.
//
// 1. THE SHIFTED SDRAM CLOCK. DRAM_CLK is the same 100 MHz as the system
//    clock, shifted early by 1.667 ns, and ALTPLL's second output cannot be
//    enabled from a qsys-script. So the PLL is here; see rtl/sdram_pll.sv.
//
// 2. HOLD THE SYSTEM IN RESET UNTIL THE PLL HAS LOCKED. Before lock the system
//    clock is neither 100 MHz nor stable, and a Nios II that starts executing
//    from it does not get far. It also matters more than usual here: the
//    controller's power-on sequence starts at reset release, and an SDRAM
//    initialised off an unstable clock is not initialised.
//
// 3. RESET THE PLL FROM THE BUTTON, NOT FROM THE SYSTEM RESET. Feeding the
//    system reset back into the PLL would deadlock - the system is held in
//    reset until lock, and the PLL cannot lock while held in reset.
//
// LED is driven by software through a PIO, not by hardware: what it shows is
// the memory test's progress, and that is the program's business.
// =============================================================================

module de0_nano_nios_top (
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

    logic clk, dram_clk, pll_locked;

    sdram_pll u_pll (
        .areset (~KEY[1]),
        .inclk0 (CLOCK_50),
        .c0     (clk),
        .c1     (dram_clk),
        .locked (pll_locked)
    );

    // Straight from the PLL to the pin. Any logic in this path eats into the
    // -3 ns budget.
    assign DRAM_CLK = dram_clk;

    // System reset: the button AND the PLL lock, resynchronised to the system
    // clock so the release is clean.
    logic rst_meta, rst_sync, sys_resetn;
    always_ff @(posedge clk or negedge pll_locked) begin
        if (!pll_locked) begin
            rst_meta <= 1'b0;
            rst_sync <= 1'b0;
        end else begin
            rst_meta <= KEY[1];
            rst_sync <= rst_meta;
        end
    end
    assign sys_resetn = rst_sync;

    sdram_nios_nano_sys u_sys (
        .clk_clk          (clk),
        .reset_reset_n    (sys_resetn),
        .led_export       (LED),
        .sdram_wire_addr  (DRAM_ADDR),
        .sdram_wire_ba    (DRAM_BA),
        .sdram_wire_cas_n (DRAM_CAS_N),
        .sdram_wire_cke   (DRAM_CKE),
        .sdram_wire_cs_n  (DRAM_CS_N),
        .sdram_wire_dq    (DRAM_DQ),
        .sdram_wire_dqm   (DRAM_DQM),
        .sdram_wire_ras_n (DRAM_RAS_N),
        .sdram_wire_we_n  (DRAM_WE_N)
    );

    // SW is not read by this design. The memory test is driven over the JTAG
    // UART, where it can print, rather than from switches it would have to
    // encode results back onto.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_sw = &{1'b0, SW, KEY[0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
