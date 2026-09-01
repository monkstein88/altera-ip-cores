`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_crc.sv
//
// The two CRCs the SD SPI protocol needs, updated one BYTE at a time.
//
// -----------------------------------------------------------------------------
// WHY BYTE-WISE AND NOT BIT-SERIAL
// -----------------------------------------------------------------------------
// A bit-serial CRC tapped off the shifter is the obvious structure and it is
// subtly wrong here, for a reason worth recording because it cost a debugging
// session.
//
// SPI transmit and receive are offset by half a bit: data is driven on the
// falling edge and captured on the rising one. A byte is therefore "received"
// (rx_valid, the sequencer's tick) one rising edge BEFORE its eighth falling
// edge has driven the last transmitted bit. A transmit CRC fed from falling
// edges and windowed by a state that changes on the tick consumes only seven of
// the eight bits of the final byte of a block - producing a CRC16 that is wrong
// in exactly one block per transfer, on the last byte, which is about the least
// convenient failure to localise.
//
// Feeding whole bytes at the point the sequencer knows they are payload removes
// the coupling completely. The CRC no longer depends on edge timing, on which
// state is active when a strobe lands, or on the half-bit skew between the two
// directions. It costs eight unrolled XOR stages per byte, which is nothing at
// one byte per eight SPI clocks.
//
// -----------------------------------------------------------------------------
// PARAMETERS, AND THE ONE THAT IS ROUTINELY GOT WRONG
// -----------------------------------------------------------------------------
//   CRC7  : x^7  + x^3  + 1        , initial value 0
//   CRC16 : x^16 + x^12 + x^5 + 1  , initial value 0x0000
//
// That CRC16 initial value is the trap. "CCITT" in most other contexts means an
// initial value of 0xFFFF; SD specifies zero. A CRC16 seeded with 0xFFFF
// produces plausible values that every card rejects, and the symptom - writes
// refused with a CRC error token, reads that never verify - looks like a
// signal-integrity problem rather than an arithmetic one.
//
// Both are checked against the specification's own fixed frames in the
// testbench and in verification/models/crc_reference.py:
//
//   CMD0  (40 00 00 00 00) -> CRC7 byte 0x95     quoted verbatim in §7.2.2
//   CMD8  (48 00 00 01 AA) -> CRC7 byte 0x87
//   512 bytes of 0xFF      -> CRC16    0x7FA1
//
// and against the property the receive path relies on: running the CRC over a
// block WITH its two CRC bytes appended returns zero.
// =============================================================================

package avalon_mm_sdcard_controller_crc_pkg;

    // One byte through the CRC7 polynomial, eight stages unrolled.
    function automatic logic [6:0] crc7_byte(input logic [6:0] c,
                                             input logic [7:0] d);
        logic [6:0] r;
        logic       fb;
        int         b;
        begin
            r = c;
            for (b = 7; b >= 0; b--) begin
                fb = d[b] ^ r[6];
                r  = {r[5:0], 1'b0};
                if (fb) r = r ^ 7'h09;
            end
            return r;
        end
    endfunction

    function automatic logic [15:0] crc16_byte(input logic [15:0] c,
                                               input logic [7:0]  d);
        logic [15:0] r;
        logic        fb;
        int          b;
        begin
            r = c;
            for (b = 7; b >= 0; b--) begin
                fb = d[b] ^ r[15];
                r  = {r[14:0], 1'b0};
                if (fb) r = r ^ 16'h1021;
            end
            return r;
        end
    endfunction

endpackage : avalon_mm_sdcard_controller_crc_pkg


// -----------------------------------------------------------------------------
// CRC7 - command frames
//
// Accumulated over the five bytes of the frame: the '01'+index byte and the
// four argument bytes. The transmitted CRC byte is {crc, 1'b1} - seven CRC bits
// with the stop bit filling bit 0.
// -----------------------------------------------------------------------------
module avalon_mm_sdcard_controller_crc7
    import avalon_mm_sdcard_controller_crc_pkg::*;
(
    input  logic       clk,
    input  logic       reset_n,
    input  logic       clear,
    input  logic       en,          // one pulse per byte
    input  logic [7:0] byte_in,
    output logic [6:0] crc
);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)   crc <= '0;
        else if (clear) crc <= '0;
        else if (en)    crc <= crc7_byte(crc, byte_in);
    end

endmodule : avalon_mm_sdcard_controller_crc7


// -----------------------------------------------------------------------------
// CRC16 - data blocks
//
// On transmit, feed the payload only; the value after the last payload byte is
// what to send, MSB first.
//
// On receive, keep feeding through the two incoming CRC bytes as well and check
// that the result is ZERO. That works because the initial value is zero, and it
// is cheaper and less error-prone than latching an expected value and comparing
// - there is no second register to get wrong.
// -----------------------------------------------------------------------------
module avalon_mm_sdcard_controller_crc16
    import avalon_mm_sdcard_controller_crc_pkg::*;
(
    input  logic        clk,
    input  logic        reset_n,
    input  logic        clear,
    input  logic        en,
    input  logic [7:0]  byte_in,
    output logic [15:0] crc
);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)   crc <= '0;
        else if (clear) crc <= '0;
        else if (en)    crc <= crc16_byte(crc, byte_in);
    end

endmodule : avalon_mm_sdcard_controller_crc16
