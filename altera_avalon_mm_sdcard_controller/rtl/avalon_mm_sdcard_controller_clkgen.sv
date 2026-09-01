`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_clkgen.sv
//
// SPI clock generation: an integer divider off the Avalon clock, plus the two
// edge strobes the rest of the core runs on.
//
// -----------------------------------------------------------------------------
// ONE CLOCK DOMAIN, DELIBERATELY
// -----------------------------------------------------------------------------
// There is no PLL here and no second clock domain. The SD clock is a divided,
// registered version of the Avalon clock, and every flop in this core runs on
// the Avalon clock. Nothing crosses a domain, so there is no CDC to get wrong,
// no synchroniser latency in the data path, and nothing that behaves
// differently in simulation than on hardware.
//
// The cost is that the SPI rate is quantised to clk/(2*N). From a 100 MHz
// system clock that gives 50 MHz, 25 MHz, 16.7 MHz, 12.5 MHz and so on - which
// covers every rate the protocol actually asks for:
//
//   CLKDIV = 1    clk/2    50.0  MHz   fast, if the wiring allows it
//   CLKDIV = 2    clk/4    25.0  MHz   the rate cards are specified to in SPI
//   CLKDIV = 125  clk/250  400   kHz   identification (must be 100-400 kHz)
//
// -----------------------------------------------------------------------------
// CPOL = 0, CPHA = 0
// -----------------------------------------------------------------------------
// SD uses SPI mode 0. The clock idles LOW, the host drives MOSI on the falling
// edge, and both sides capture on the rising edge. This module does not itself
// drive or sample anything - it emits `fall_stb` and `rise_stb`, single-cycle
// strobes in the system clock domain, and avalon_mm_sdcard_controller_spi_phy hangs the shifting
// and sampling off those.
//
// A subtlety worth stating because it is invisible until it bites: `sd_clk` is
// a REGISTERED output, so the edge reaches the pin one system clock after the
// strobe fires. MOSI is registered off the same edge, so clock and data stay
// aligned at the pin and the card sees exactly SPI mode 0. What does NOT stay
// aligned is the return path - see the sampling discussion in
// avalon_mm_sdcard_controller_spi_phy.sv.
//
// -----------------------------------------------------------------------------
// STOPPING CLEANLY
// -----------------------------------------------------------------------------
// `run` may deassert at any time, but the clock may only stop LOW: leaving
// sd_clk parked high would violate CPOL=0 and, worse, would leave the card
// mid-bit. So the divider keeps running until it lands in the low phase and
// only then idles. Callers do not have to align their deassertion to anything.
// =============================================================================

module avalon_mm_sdcard_controller_clkgen #(
    parameter int unsigned CLKDIV_WIDTH = 8
) (
    input  logic                          clk,
    input  logic                          reset_n,

    // Divider value. SPI clock = clk / (2 * clkdiv). Zero is treated as one,
    // so a CSR left at reset produces the fastest clock rather than none at
    // all - which is a far easier failure to diagnose than silence.
    input  logic [CLKDIV_WIDTH-1:0]       clkdiv,

    input  logic                          run,        // generate clocks
    output logic                          sd_clk,     // to the card, CPOL=0
    output logic                          rise_stb,   // capture point
    output logic                          fall_stb,   // drive point
    output logic                          idle        // parked low, safe to stop
);

    logic [CLKDIV_WIDTH-1:0] cnt;
    logic                    sclk_q;
    logic                    tick;

    // Zero would divide by nothing and stop the clock entirely; clamp to one.
    logic [CLKDIV_WIDTH-1:0] div_eff;
    always_comb div_eff = (clkdiv == '0) ? {{(CLKDIV_WIDTH-1){1'b0}}, 1'b1}
                                         : clkdiv;

    // `active` keeps the divider going past a deassertion of `run` until the
    // clock has returned low.
    logic active;
    always_comb active = run || sclk_q;

    // The divider expires. At div_eff == 1 this is true every cycle, which is
    // what makes clk/2 - one SPI bit every two system clocks - reachable.
    always_comb tick = active && (cnt == '0);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cnt    <= '0;
            sclk_q <= 1'b0;
        end else if (!active) begin
            cnt    <= div_eff - 1'b1;
            sclk_q <= 1'b0;
        end else if (tick) begin
            cnt    <= div_eff - 1'b1;
            sclk_q <= ~sclk_q;
        end else begin
            cnt    <= cnt - 1'b1;
        end
    end

    // Strobes name the transition that is ABOUT to appear at the pin, so a
    // consumer registering off them lands aligned with the edge the card sees.
    always_comb begin
        rise_stb = tick && !sclk_q;   // going high: capture point
        fall_stb = tick &&  sclk_q;   // going low:  drive point
    end

    always_comb sd_clk = sclk_q;
    always_comb idle   = !sclk_q && !run;

endmodule : avalon_mm_sdcard_controller_clkgen
