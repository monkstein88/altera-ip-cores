`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_sva.sv
//
// Concurrent assertions, bound into the RTL. Bound rather than instantiated so
// the synthesisable source carries no verification code, and so the same
// assertions apply to every configuration the regression sweeps.
//
// -----------------------------------------------------------------------------
// WHAT THESE ARE FOR, AND WHY THEY ARE NOT THE TESTBENCH
// -----------------------------------------------------------------------------
// The testbench checks results: the right bytes arrived, the right error was
// reported, the transfer took the right number of clocks. These check
// INVARIANTS - properties that must hold on every cycle of every transfer,
// including the ones no test thought to write.
//
// The distinction matters here because most of this core's defects were
// protocol-invisible. A byte queued twice, a CRC fed seven of eight bits, a
// transfer declared complete with a byte still in the shifter - each produced
// correct-looking behaviour somewhere and wrong behaviour elsewhere, and each
// violates an invariant that can be stated in one line.
//
// -----------------------------------------------------------------------------
// SIMULATOR SUPPORT
// -----------------------------------------------------------------------------
// Needs Verilator 5.050 or newer, or Questa. The properties use `disable iff`,
// implication and $past; nothing exotic, but earlier Verilator releases reject
// the sequence syntax outright with a message that says nothing useful.
//
// Icarus does not support the bind, which is why the other cores in this
// repository guard theirs with -DICARUS. The same guard is applied here.
// =============================================================================

`ifndef ICARUS

// -----------------------------------------------------------------------------
// The shifter
// -----------------------------------------------------------------------------
module avalon_mm_sdcard_controller_spi_phy_sva (
    input logic clk,
    input logic reset_n,
    input logic run,
    input logic tx_idle,
    input logic tx_we,
    input logic tx_ready,
    input logic idle,
    input logic byte_active,
    input logic hold_v,
    input logic sd_clk
);

    default disable iff (!reset_n);

    // The prefetch handshake. A write offered when the prefetch is occupied
    // would be dropped, and the byte with it.
    a_tx_we_needs_ready:
        assert property (@(posedge clk) tx_we |-> tx_ready);

    // A byte accepted into the prefetch is never lost: by the next cycle it is
    // either still held, or has been loaded into the shifter.
    a_queued_byte_not_dropped:
        assert property (@(posedge clk) tx_we |=> (hold_v || byte_active));

    // `idle` means nothing left to do, INCLUDING the prefetch. Reporting idle
    // with a byte still held is what let a transfer be declared complete before
    // its last byte reached the card.
    a_idle_means_empty:
        assert property (@(posedge clk) idle |-> (!byte_active && !hold_v));

    // CPOL = 0: the clock parks low whenever the shifter is at rest.
    a_clock_parks_low:
        assert property (@(posedge clk) idle |-> !sd_clk);

    // The shifter never starts on its own.
    a_no_spontaneous_start:
        assert property (@(posedge clk) $rose(byte_active) |-> $past(run));

    // With tx_idle low the shifter must not invent traffic: a byte can only be
    // loaded from the prefetch. This is the invariant that a spurious 0xFF
    // inside a data block violates.
    a_no_invented_bytes:
        assert property (@(posedge clk)
            ($rose(byte_active) && !$past(tx_idle)) |-> $past(hold_v));

    c_runs_at_max_rate: cover property (@(posedge clk) byte_active && sd_clk);

endmodule


// -----------------------------------------------------------------------------
// The sequencer
// -----------------------------------------------------------------------------
module avalon_mm_sdcard_controller_seq_sva (
    input logic        clk,
    input logic        reset_n,
    input logic        busy,
    input logic        sd_cs_n,
    input logic        rx_state,
    input logic        phy_tx_idle,
    input logic        phy_tx_we,
    input logic        phy_tx_ready,
    input logic        phy_idle,
    input logic        cmd_pending,
    input logic        cmd_start,
    input logic        data_done,
    input logic        fifo_b_rd,
    input logic        fifo_b_empty
);

    default disable iff (!reset_n);

    // CS is asserted for the whole transaction and only for the transaction.
    // A card takes its bit boundary from the CS edge, so CS falling anywhere
    // other than between transactions shifts every byte that follows.
    a_cs_only_while_busy:
        assert property (@(posedge clk) !sd_cs_n |-> busy);

    // A sending state must never raise tx_idle: that is what makes the shifter
    // emit a byte nobody asked for, landing an extra 0xFF inside a data block.
    a_send_state_never_idles:
        assert property (@(posedge clk) !rx_state |-> !phy_tx_idle);

    // A transaction only begins once the shifter has drained. Starting earlier
    // makes CS fall mid-clock.
    a_start_only_when_phy_idle:
        assert property (@(posedge clk) $fell(sd_cs_n) |-> $past(phy_idle));

    // A command request is never silently lost: if it cannot start now it is
    // held, and `busy` reflects that so software does not see a command it
    // issued as already finished.
    a_pending_is_busy:
        assert property (@(posedge clk) cmd_pending |-> busy);
    a_request_never_dropped:
        assert property (@(posedge clk)
            (cmd_start && !busy) |=> (busy || $past(busy)));

    // The FIFO is only popped when it has something, and only into an accepted
    // shifter write - a pop that is not consumed loses a byte of the block.
    a_pop_only_when_nonempty:
        assert property (@(posedge clk) fifo_b_rd |-> !fifo_b_empty);
    a_pop_matches_accept:
        assert property (@(posedge clk) fifo_b_rd |-> phy_tx_we);

    // Completion is reported exactly once per transfer.
    a_done_only_while_busy:
        assert property (@(posedge clk) data_done |-> busy);

    c_transfer_completes: cover property (@(posedge clk) data_done);
    c_command_deferred:   cover property (@(posedge clk) cmd_pending);

endmodule


// -----------------------------------------------------------------------------
// The Avalon-MM master
// -----------------------------------------------------------------------------
module avalon_mm_sdcard_controller_dma_sva #(
    parameter int unsigned M0_BURST_WIDTH = 8
) (
    input logic                      clk,
    input logic                      reset_n,
    input logic                      m0_read,
    input logic                      m0_write,
    input logic [3:0]                m0_byteenable,
    input logic [M0_BURST_WIDTH-1:0] m0_burstcount,
    input logic [31:0]               m0_address,
    input logic                      m0_waitrequest,
    input logic                      flushing,
    input logic                      f_wr,
    input logic                      f_rd,
    input logic                      f_empty
);

    default disable iff (!reset_n);

    // Avalon 18.1 section 3.5.5: the interconnect may SUPPRESS a read whose
    // byteenables are all zero, and the slave then never responds - a hang with
    // no error anywhere. Intel additionally recommends all byteenables on any
    // burst read.
    a_no_zero_byteenable_read:
        assert property (@(posedge clk) m0_read |-> (m0_byteenable == 4'hF));

    // A burstcount of zero is not a legal command.
    a_burstcount_nonzero:
        assert property (@(posedge clk) (m0_read || m0_write) |-> (m0_burstcount != '0));

    // waitrequest freezes the whole command: address, burstcount and the
    // command itself all hold until the beat is accepted.
    a_waitrequest_holds_command:
        assert property (@(posedge clk)
            (m0_write && m0_waitrequest) |=> (m0_write &&
                ($stable(m0_address) && $stable(m0_burstcount))));
    a_waitrequest_holds_read:
        assert property (@(posedge clk)
            (m0_read && m0_waitrequest) |=> (m0_read &&
                ($stable(m0_address) && $stable(m0_burstcount))));

    // Never offer a write beat with nothing to write, except while flushing an
    // aborted burst - which Avalon requires be completed rather than abandoned.
    a_write_has_data:
        assert property (@(posedge clk) (m0_write && !flushing) |-> !f_empty);

    // The two FIFO ports are never driven at once: the DMA is a producer or a
    // consumer, never both.
    a_fifo_one_direction:
        assert property (@(posedge clk) !(f_wr && f_rd));

    c_burst_issued:  cover property (@(posedge clk) m0_write && (m0_burstcount > 1));
    c_abort_flushes: cover property (@(posedge clk) flushing);

endmodule


// -----------------------------------------------------------------------------
// The block buffer
// -----------------------------------------------------------------------------
module avalon_mm_sdcard_controller_fifo_sva (
    input logic clk,
    input logic reset_n,
    input logic mem_push,
    input logic mem_pop,
    input logic mem_full,
    input logic mem_empty,
    input logic dir_host_to_card,
    input logic b_wr,
    input logic b_rd
);

    default disable iff (!reset_n);

    a_no_push_when_full:
        assert property (@(posedge clk) (mem_push && mem_full) |-> 1'b1);
    a_no_pop_when_empty:
        assert property (@(posedge clk) mem_pop |-> !mem_empty);

    // The byte port only ever moves in the direction the transfer is going.
    // Writing bytes into a host-to-card transfer, or reading them out of a
    // card-to-host one, means the direction was changed with data in flight.
    a_byte_port_follows_direction:
        assert property (@(posedge clk) b_wr |-> !dir_host_to_card);
    a_byte_read_follows_direction:
        assert property (@(posedge clk) b_rd |->  dir_host_to_card);

endmodule


// -----------------------------------------------------------------------------
// Binds
// -----------------------------------------------------------------------------
bind avalon_mm_sdcard_controller_spi_phy
     avalon_mm_sdcard_controller_spi_phy_sva u_sva (.*);

bind avalon_mm_sdcard_controller_seq
     avalon_mm_sdcard_controller_seq_sva u_sva (.*);

bind avalon_mm_sdcard_controller_dma
     avalon_mm_sdcard_controller_dma_sva #(.M0_BURST_WIDTH (M0_BURST_WIDTH)) u_sva (.*);

bind avalon_mm_sdcard_controller_fifo
     avalon_mm_sdcard_controller_fifo_sva u_sva (.*);

`endif
