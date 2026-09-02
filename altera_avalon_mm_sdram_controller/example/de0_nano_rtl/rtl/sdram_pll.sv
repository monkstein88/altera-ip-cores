`timescale 1ns/1ps

// =============================================================================
// sdram_pll.sv
//
// The DE0-Nano's SDRAM clocking, as a plain ALTPLL instantiation.
//
//   inclk0  50 MHz, from the board oscillator on CLOCK_50
//   c0      100 MHz at 0 degrees  -> the controller and everything else
//   c1      100 MHz at -1667 ps   -> DRAM_CLK, the chip's own clock pin
//
// -----------------------------------------------------------------------------
// WHY THE SECOND OUTPUT IS SHIFTED
// -----------------------------------------------------------------------------
// c1 is the same 100 MHz as c0, shifted EARLY by 3 ns. Everything the FPGA
// drives towards the SDRAM - address, command, write data - leaves an output
// register clocked by c0 and then spends real time getting there: clock-to-out
// of the I/O register, the board trace, and the chip's own input setup window.
// If the SDRAM latched on the same edge as c0, it would sample those signals
// while they were still moving.
//
// Clocking the chip early moves the chip's sampling edge back to a point where
// the previous cycle's outputs are long settled. -1667 ps is the value Terasic
// uses for THIS board, in the PLL of their DE0_Nano_QSYS_DEMO, and it is a
// property of this board's layout rather than of the controller.
//
// Note that it is NOT the DE10-Lite's -3000 ps. The two boards route their
// SDRAM differently and each has its own figure; copying one to the other is
// exactly the mistake this comment exists to prevent.
//
// Getting this wrong does not produce an obvious failure. The controller
// initialises, accepts commands and returns data - the data is simply wrong,
// intermittently, in a way that looks like a defective memory chip. That is
// worth knowing before blaming the IP.
//
// -----------------------------------------------------------------------------
// WHY THIS IS RTL AND NOT PART OF THE QSYS SYSTEM
// -----------------------------------------------------------------------------
// ALTPLL's second clock output cannot be enabled from a qsys-script: writing
// PORT_clk1 = PORT_USED is silently reverted by the megafunction's own
// validation, and reads back PORT_UNUSED, so c1 never appears as an interface
// that could be exported. Terasic's RTL demo puts its PLL at the top level for
// the same reason. See qsys/build_system.tcl.
//
// compensate_clock = "CLK0" makes the PLL compensate its feedback for c0, so
// the 0-degree output is the one aligned to the input clock and c1's shift is
// measured against it.
// =============================================================================

module sdram_pll (
    input  logic areset,
    input  logic inclk0,        // 50 MHz
    output logic c0,            // 100 MHz, 0 degrees   - system clock
    output logic c1,            // 100 MHz, -1667 ps    - DRAM_CLK
    output logic locked
);

    wire [4:0] pll_clk;
    wire       pll_locked;

    altpll altpll_component (
        .areset             (areset),
        .inclk              ({1'b0, inclk0}),
        .clk                (pll_clk),
        .locked             (pll_locked),
        // Unused inputs tied to their inactive levels, unused outputs left
        // open. ALTPLL has no defaults for these, so they must all appear.
        .clkena             ({6{1'b1}}),
        .extclkena          ({4{1'b1}}),
        .clkswitch          (1'b0),
        .configupdate       (1'b0),
        .fbin               (1'b1),
        .pfdena             (1'b1),
        .phasecounterselect ({4{1'b1}}),
        .phasestep          (1'b1),
        .phaseupdown        (1'b1),
        .pllena             (1'b1),
        .scanaclr           (1'b0),
        .scanclk            (1'b0),
        .scanclkena         (1'b1),
        .scandata           (1'b0),
        .scanread           (1'b0),
        .scanwrite          (1'b0),
        .activeclock        (),
        .clkbad             (),
        .clkloss            (),
        .enable0            (),
        .enable1            (),
        .extclk             (),
        .fbmimicbidir       (),
        .fbout              (),
        .fref               (),
        .icdrclk            (),
        .phasedone          (),
        .scandataout        (),
        .scandone           (),
        .sclkout0           (),
        .sclkout1           (),
        .vcooverrange       (),
        .vcounderrange      ()
    );

    defparam
        altpll_component.bandwidth_type          = "AUTO",
        altpll_component.clk0_divide_by           = 1,
        altpll_component.clk0_duty_cycle          = 50,
        altpll_component.clk0_multiply_by         = 2,
        altpll_component.clk0_phase_shift         = "0",
        altpll_component.clk1_divide_by           = 1,
        altpll_component.clk1_duty_cycle          = 50,
        altpll_component.clk1_multiply_by         = 2,
        altpll_component.clk1_phase_shift         = "-1667",
        altpll_component.compensate_clock         = "CLK0",
        altpll_component.inclk0_input_frequency   = 20000,     // ps -> 50 MHz
        altpll_component.intended_device_family   = "Cyclone IV E",
        altpll_component.lpm_hint                 = "CBX_MODULE_PREFIX=sdram_pll",
        altpll_component.lpm_type                 = "altpll",
        altpll_component.operation_mode           = "NORMAL",
        altpll_component.pll_type                 = "AUTO",
        altpll_component.port_areset              = "PORT_USED",
        altpll_component.port_inclk0              = "PORT_USED",
        altpll_component.port_locked              = "PORT_USED",
        altpll_component.port_clk0                = "PORT_USED",
        altpll_component.port_clk1                = "PORT_USED",
        altpll_component.self_reset_on_loss_lock  = "OFF",
        altpll_component.width_clock              = 5;

    assign c0     = pll_clk[0];
    assign c1     = pll_clk[1];
    assign locked = pll_locked;

endmodule
