`timescale 1ns/1ps

// =============================================================================
// demo_target_slave.sv
//
// The peripheral being protected. A small Avalon-MM scratchpad - MEM_WORDS
// 32-bit words, byte-enabled, BURST CAPABLE - plus a switchable fault
// injector, because a demo of a fault-isolation firewall needs something that
// can actually fail on demand.
//
// This is the Avalon-MM counterpart of the AXI4-Lite firewall's demo slave.
// The shape is the same and the failure modes mean the same thing, but the
// mechanics differ in the way the two protocols differ: there is no separate
// address channel to leave un-acknowledged, so "refuse the command" is
// waitrequest stuck high, and "accept then go silent" is a burst whose
// readdatavalid beats never arrive.
//
// FAILURE MODES. The firewall reports these through *different* STATUS bits,
// and the difference is the whole reason both exist here:
//
//   hang=0                normal. Zero wait states, one beat per cycle.
//
//   hang=1, hang_late=0   waitrequest stuck high. The command is never
//                         accepted, so the firewall is left holding a
//                         read/write nobody took: STATUS.WR_CMD_STUCK /
//                         RD_CMD_STUCK. Avalon-MM requires a master to hold a
//                         command until waitrequest falls, so the firewall
//                         freezes rather than withdraws it, and only
//                         RECOVERY.UNBLOCK may retract it.
//
//   hang=1, hang_late=1   accept the command, then go silent. A read burst
//                         that is owed N beats gets none of them; a write
//                         burst is fully consumed and its writeresponsevalid
//                         never arrives. The peripheral now owes a response
//                         forever: STATUS.RD_BUSY / WR_BUSY stay set, and the
//                         *_CMD_STUCK bits stay clear. This is the case that
//                         makes an unbounded poll of the busy bits hang.
//
// W_DEAD/R_DEAD are trap states with no exit but a reset. That is deliberate
// and is the point being demonstrated: nothing the firewall does can revive a
// wedged peripheral, which is why resetting it is a step in a software
// sequence rather than something the core does for you.
//
// TWO RESETS, and both are needed:
//
//   resetn        the system reset, like any other component's.
//   soft_resetn   the PERIPHERAL's own reset, under software control. In a
//                 real system this is a reset bridge or a PIO bit; here the
//                 RTL demo's sequencer drives it and the Nios demo drives it
//                 from a PIO, both exactly as a driver would.
//
// They are ANDed internally. Platform Designer needs a genuine reset sink to
// tie into the system reset network, so the software-controlled one cannot
// simply BE `resetn` - that is why there are two rather than one.
//
// Either reset clears the scratchpad, which is what lets the recovery
// scenarios tell "no stale write landed" (reads back 0) from "a stale write
// landed" (reads back the orphaned data) with no ambiguity.
// =============================================================================

module demo_target_slave #(
    parameter int ADDR_WIDTH         = 32,
    parameter int DATA_WIDTH         = 32,
    parameter int BURST_WIDTH        = 8,
    parameter int MEM_WORDS          = 64,
    parameter int USE_WRITE_RESPONSE = 1
) (
    input  logic                     clk,
    input  logic                     resetn,      // system reset
    input  logic                     soft_resetn, // peripheral reset, software-driven
    input  logic                     hang,        // stop responding
    input  logic                     hang_late,   // 0: refuse the command, 1: accept then go silent

    input  logic [ADDR_WIDTH-1:0]    s_address,
    input  logic                     s_read,
    input  logic                     s_write,
    input  logic [DATA_WIDTH-1:0]    s_writedata,
    input  logic [DATA_WIDTH/8-1:0]  s_byteenable,
    input  logic [BURST_WIDTH-1:0]   s_burstcount,
    output logic                     s_waitrequest,
    output logic [DATA_WIDTH-1:0]    s_readdata,
    output logic                     s_readdatavalid,
    output logic [1:0]               s_response,
    output logic                     s_writeresponsevalid
);

    localparam int BYTES    = DATA_WIDTH/8;
    localparam int IDX_BITS = $clog2(MEM_WORDS);
    localparam int SHIFT    = $clog2(BYTES);

    localparam bit HAS_WRESP = (USE_WRITE_RESPONSE != 0);

    // Either reset holds the peripheral down.
    logic rst_n;
    assign rst_n = resetn && soft_resetn;

    // Refuse to accept a command at all. The "accept then go silent" mode
    // still takes the command, so it is not gated here.
    logic refuse_cmd;
    assign refuse_cmd = hang && !hang_late;

    // Go silent after accepting. Latched into the trap states below.
    logic silent_after;
    assign silent_after = hang && hang_late;

    logic [DATA_WIDTH-1:0] mem [MEM_WORDS];

    // The peripheral decodes only the low address bits and ignores the rest.
    // Every address the firewall forwards therefore lands somewhere valid -
    // which is the point: in this demo the firewall is the *only* thing that
    // ever says no, so a DECODEERROR is unambiguously the firewall's doing and
    // not the peripheral running out of decode.
    function automatic logic [IDX_BITS-1:0] word_index(input logic [ADDR_WIDTH-1:0] a);
        return a[IDX_BITS+SHIFT-1:SHIFT];
    endfunction

    // ------------------------------------------------------------------
    // waitrequest
    //
    // Combinational and zero-wait-state in the normal case, which is what lets
    // the firewall's pass-through show its one-beat-per-cycle throughput on
    // real hardware. Stuck high in the refuse-command mode, and stuck high in
    // either trap state so a wedged peripheral cannot quietly start accepting
    // work again.
    // ------------------------------------------------------------------
    logic w_dead, r_dead;
    logic [BURST_WIDTH-1:0] r_left;      // beats still owed on the read channel

    // Held while a read burst is still draining, so only one is ever in
    // flight. The firewall never issues a read and a write together, so
    // sharing one waitrequest across both channels costs nothing here.
    //
    // `!rst_n` is the term that makes the recovery scenarios mean anything. A
    // peripheral held in reset must not complete handshakes: without this it
    // keeps waitrequest low while its state machine is held clear, so a
    // command frozen on the bus by the firewall is handshaked away and
    // silently swallowed. That would make the correct and the incorrect
    // recovery order produce identical results - both "nothing landed" - and
    // the hazard the sequence exists to avoid would be invisible.
    assign s_waitrequest = !rst_n || refuse_cmd || w_dead || r_dead || (r_left != '0);

    // ------------------------------------------------------------------
    // Write channel
    //
    // Avalon-MM burst writes present the address on the first beat only;
    // beats 2..N carry writedata alone. The running address is kept here.
    // ------------------------------------------------------------------
    logic [BURST_WIDTH-1:0] w_left;      // beats still expected after this one
    logic [ADDR_WIDTH-1:0]  w_addr;
    logic                   w_first;
    logic [ADDR_WIDTH-1:0]  w_cur;
    logic                   w_accept;
    logic                   w_last_beat;

    assign w_first    = (w_left == '0);
    assign w_cur      = w_first ? s_address : w_addr;
    assign w_accept   = s_write && !s_waitrequest;
    assign w_last_beat = w_first ? (s_burstcount <= BURST_WIDTH'(1))
                                 : (w_left == BURST_WIDTH'(1));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_left               <= '0;
            w_addr               <= '0;
            w_dead               <= 1'b0;
            s_writeresponsevalid <= 1'b0;
            for (int i = 0; i < MEM_WORDS; i++) mem[i] <= '0;
        end else begin
            s_writeresponsevalid <= 1'b0;

            if (w_accept) begin
                for (int b = 0; b < BYTES; b++)
                    if (s_byteenable[b])
                        mem[word_index(w_cur)][b*8 +: 8] <= s_writedata[b*8 +: 8];

                if (w_first) w_left <= s_burstcount - BURST_WIDTH'(1);
                else         w_left <= w_left - BURST_WIDTH'(1);

                w_addr <= w_cur + ADDR_WIDTH'(BYTES);

                if (w_last_beat) begin
                    // The burst is complete. Either answer it or become a
                    // peripheral that owes an answer forever.
                    if (silent_after) w_dead <= 1'b1;
                    else if (HAS_WRESP) s_writeresponsevalid <= 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Read channel
    //
    // One burst in flight is enough for this demo - the firewall serialises
    // denied reads anyway, and the sequencer never pipelines commands. Beats
    // are produced one per cycle starting the cycle after the command is
    // accepted, which is the read latency the throughput scenario measures.
    // ------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0]  r_addr;
    logic                   r_accept;

    assign r_accept = s_read && !s_waitrequest;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            r_left          <= '0;
            r_addr          <= '0;
            r_dead          <= 1'b0;
            s_readdata      <= '0;
            s_readdatavalid <= 1'b0;
        end else begin
            s_readdatavalid <= 1'b0;

            if (r_accept) begin
                // A read is accepted only when none is outstanding, because
                // waitrequest is held while r_left != 0 - see below.
                // waitrequest above guarantees r_left is 0 here, so nothing
                // in flight can be clobbered.
                if (silent_after) begin
                    r_dead <= 1'b1;          // accepted, and now owes beats forever
                end else begin
                    r_left <= s_burstcount;
                    r_addr <= s_address;
                end
            end else if (r_left != '0) begin
                s_readdata      <= mem[word_index(r_addr)];
                s_readdatavalid <= 1'b1;
                r_addr          <= r_addr + ADDR_WIDTH'(BYTES);
                r_left          <= r_left - BURST_WIDTH'(1);
            end
        end
    end

    // Responses are always OKAY. This peripheral never rejects anything: in
    // this demo every error the master sees is the firewall's doing, which is
    // what makes the scenarios unambiguous.
    assign s_response = 2'b00;

endmodule
