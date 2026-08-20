`timescale 1ns/1ps

// =============================================================================
// de10_lite_nios_top.sv
//
// Board wrapper for the Nios II/f AXI4-Lite Firewall example on the Terasic
// DE10-Lite (Intel MAX 10, 10M50DAF484C7G).
//
// Almost everything lives inside the Platform Designer system, `firewall_sys`,
// which is built by ../qsys/build_system.tcl. This file does only what a board
// wrapper should: bring in the clock, sequence the reset around the PLL, and
// join the two halves of the fault-injection path.
//
//        MAX10_CLK1_50 ──▶ firewall_sys ──▶ LEDR
//         (50 MHz)          (100 MHz,        (firewall STATUS, driven
//                            from an          by software over a PIO)
//                            internal PLL)
//
// RESET SEQUENCING. KEY[0] resets the PLL directly through `pll_areset`. The
// rest of the system is held in reset until `pll_locked` rises, so the CPU
// never executes an instruction on an unlocked clock. The PLL's reference
// reset is tied inactive: if it followed the system reset, the system could
// not start, because the system reset waits on a lock that the PLL is being
// held in reset from ever achieving. See the comment in build_system.tcl.
//
// FAULT INJECTION. `fault_ctl` is a PIO output inside the system; the
// peripheral's `hang`/`hang_late`/`soft_resetn` are conduit inputs to it.
// Platform Designer exports both ends and they are joined here, which is what
// lets software break the protected peripheral on purpose - and, more
// importantly, RESET it during recovery. Version 2.0 of the core removed its
// peripheral-reset output and made that the integrator's job; bit 2 below is
// that job.
// =============================================================================

module de10_lite_nios_top (
    input  logic       MAX10_CLK1_50,
    input  logic [1:0] KEY,
    input  logic [9:0] SW,
    output logic [9:0] LEDR
);

    logic       pll_locked;
    logic       sys_resetn;
    logic [2:0] fault_ctl;      // bit0 hang, bit1 hang_late, bit2 soft_resetn

    // KEY is active low. Hold the system down until the PLL has locked.
    assign sys_resetn = KEY[0] & pll_locked;

    firewall_sys u_sys (
        .clk_clk                  (MAX10_CLK1_50),
        .reset_reset_n            (sys_resetn),

        // The PLL is reset straight from the button; its reference-clock
        // reset is tied inactive so it can always reach lock.
        .pll_areset_export        (~KEY[0]),
        .pll_ref_reset_reset_n    (1'b1),
        .pll_locked_export        (pll_locked),

        .led_export               (LEDR),

        // The PIO drives the peripheral's fault inputs.
        .fault_ctl_export         (fault_ctl),
        .target_fault_hang        (fault_ctl[0]),
        .target_fault_hang_late   (fault_ctl[1]),
        .target_fault_soft_resetn (fault_ctl[2])
    );

    // SW and KEY[1] are unused here - the demo is driven over the JTAG UART,
    // not from the board. Tie them off explicitly so Quartus reports them as
    // intentionally unused rather than as dangling inputs.
    logic unused;
    assign unused = ^{SW, KEY[1]};

endmodule
