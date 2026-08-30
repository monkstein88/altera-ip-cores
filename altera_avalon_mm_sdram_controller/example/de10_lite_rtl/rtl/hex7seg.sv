`timescale 1ns/1ps

// =============================================================================
// hex7seg.sv
//
// DE10-Lite seven-segment decoder. The board's displays are common-anode and
// active low: driving a segment bit to 0 lights it. HEXn[6:0] are segments
// a..g and HEXn[7] is the decimal point (also active low, so 1 = off).
//
// Codes 0x0-0xF are the hex digits. Above that are the few glyphs the demo
// needs to say something that is not a number: pass, fail, busy, nothing.
// =============================================================================

module hex7seg (
    input  logic [4:0] code,
    output logic [7:0] hex
);

    // Bit index = segment: 0=a 1=b 2=c 3=d 4=e 5=f 6=g. 1 means lit; the
    // inversion to the board's active-low drive happens once, at the bottom.
    logic [6:0] seg;

    always_comb begin
        case (code)
            5'h0:    seg = 7'b0111111;   // 0
            5'h1:    seg = 7'b0000110;   // 1
            5'h2:    seg = 7'b1011011;   // 2
            5'h3:    seg = 7'b1001111;   // 3
            5'h4:    seg = 7'b1100110;   // 4
            5'h5:    seg = 7'b1101101;   // 5
            5'h6:    seg = 7'b1111101;   // 6
            5'h7:    seg = 7'b0000111;   // 7
            5'h8:    seg = 7'b1111111;   // 8
            5'h9:    seg = 7'b1101111;   // 9
            5'hA:    seg = 7'b1110111;   // A
            5'hB:    seg = 7'b1111100;   // b (lower case: an upper-case B is an 8)
            5'hC:    seg = 7'b0111001;   // C
            5'hD:    seg = 7'b1011110;   // d (lower case: an upper-case D is a 0)
            5'hE:    seg = 7'b1111001;   // E
            5'hF:    seg = 7'b1110001;   // F
            5'd17:   seg = 7'b1110011;   // P - scenario passed
            5'd18:   seg = 7'b1110001;   // F - scenario failed (same glyph as hex F,
                                         //     unambiguous because it only ever
                                         //     appears on HEX4, which never shows a digit)
            5'd19:   seg = 7'b1000000;   // - - scenario running
            default: seg = 7'b0000000;   // 5'd16 = blank, and anything unmapped
        endcase
    end

    assign hex = {1'b1, ~seg};           // decimal point off, segments active low

endmodule
