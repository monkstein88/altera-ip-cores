`timescale 1ns/1ps

// =============================================================================
// key_debounce.sv
//
// Two-flop synchroniser plus an integrating debouncer for one DE10-Lite push
// button. The buttons are active low and are not Schmitt-conditioned on the
// board, so a single press produces a burst of edges; without this, one press
// would run a scenario several times and the pass bitmap would look random.
//
// The counter only advances while the synchronised input DISAGREES with the
// accepted level, and is cleared whenever it agrees. A new level is therefore
// accepted only after 2^CNT_BITS consecutive clocks of agreement with itself -
// integrating rather than one-shot, so a bounce part-way through restarts the
// count instead of latching a glitch.
//
// `pulse` is one clock wide and fires on the press (the falling edge), never
// on the release.
// =============================================================================

module key_debounce #(
    parameter int CNT_BITS = 17         // 2^17 / 50 MHz = 2.6 ms
) (
    input  logic clk,
    input  logic resetn,
    input  logic key_n,                 // raw pin, active low
    output logic pulse                  // one-cycle press event
);

    logic sync0, sync1;
    logic level;                        // the accepted, debounced level
    logic [CNT_BITS-1:0] cnt;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            sync0 <= 1'b1;
            sync1 <= 1'b1;
            level <= 1'b1;
            cnt   <= '0;
            pulse <= 1'b0;
        end else begin
            sync0 <= key_n;
            sync1 <= sync0;
            pulse <= 1'b0;

            if (sync1 != level) begin
                cnt <= cnt + 1'b1;
                if (&cnt) begin
                    level <= sync1;
                    cnt   <= '0;
                    if (!sync1) pulse <= 1'b1;      // 1 -> 0 is a press
                end
            end else begin
                cnt <= '0;
            end
        end
    end

endmodule
