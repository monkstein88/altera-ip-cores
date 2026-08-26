`timescale 1ns/1ps

// =============================================================================
// de10_lite_nios_top.sv
//
// Board wrapper for the Nios II Avalon-MM Firewall example on the Terasic
// DE10-Lite (Intel MAX 10, 10M50DAF484C7G).
//
// Everything of interest is inside the Platform Designer system: the CPU, the
// firewall, the protected peripheral, and the PIOs that break it on purpose.
// This file exists to connect that system to pins, and to do the two things
// Platform Designer cannot do for itself.
//
// 1. HOLD THE SYSTEM IN RESET UNTIL THE PLL HAS LOCKED. The system clock is
//    the PLL's 100 MHz output; before lock it is neither 100 MHz nor stable,
//    and a Nios II that starts executing from it does not get far. KEY1 and
//    `locked` are ANDed into the system reset.
//
// 2. RESET THE PLL FROM THE BUTTON, NOT FROM THE SYSTEM RESET. The PLL's
//    areset comes straight from KEY1. Feeding the system reset back into it
//    would deadlock: the system is held in reset until lock, and the PLL
//    cannot lock while held in reset. `pll_ref_reset` - the reset bridge the
//    system needs to keep Qsys happy - is tied inactive here for the same
//    reason.
//
// The fault PIO's three bits drive the peripheral's fault conduit directly.
// Bit 2 is soft_resetn: software resetting the protected peripheral is a step
// in the firewall's documented recovery sequence, and the core deliberately
// does not do it for you.
// =============================================================================

module de10_lite_nios_top (
    input  logic       MAX10_CLK1_50,
    input  logic [1:0] KEY,
    input  logic [9:0] SW,
    output logic [9:0] LEDR
);

    logic sys_resetn;
    logic pll_locked;
    logic [2:0] fault_ctl;

    // KEY1 is the manual reset, active low. Synchronised before use: it is a
    // bare pin with no conditioning on the board.
    logic key1_s0 = 1'b1, key1_s1 = 1'b1;
    always_ff @(posedge MAX10_CLK1_50) begin
        key1_s0 <= KEY[1];
        key1_s1 <= key1_s0;
    end

    // The system leaves reset only once the button is released AND the PLL has
    // locked. See note 1 above.
    assign sys_resetn = key1_s1 & pll_locked;

    firewall_sys u_sys (
        .clk_clk                   (MAX10_CLK1_50),
        .reset_reset_n             (sys_resetn),

        // See note 2: the PLL is reset from the button alone, and the
        // reference-clock reset bridge is tied inactive.
        .pll_areset_export         (~key1_s1),
        .pll_locked_export         (pll_locked),
        .pll_ref_reset_reset_n     (1'b1),

        .led_export                (LEDR),

        // pio_fault drives the peripheral's fault conduit, straight through.
        .fault_ctl_export          (fault_ctl),
        .target_fault_hang         (fault_ctl[0]),
        .target_fault_hang_late    (fault_ctl[1]),
        .target_fault_soft_resetn  (fault_ctl[2])
    );

    // SW is unused: this example reports over the JTAG UART, not the board.
    // Tied off explicitly so Quartus reports it as intentionally unused rather
    // than as dangling.
    logic unused_sw;
    assign unused_sw = ^SW;

endmodule
