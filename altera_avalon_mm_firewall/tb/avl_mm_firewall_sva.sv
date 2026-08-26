`timescale 1ns/1ps

// =============================================================================
// avl_mm_firewall_sva.sv
//
// SystemVerilog assertions and cover points, bound into avl_mm_firewall_top by
// tb/avl_mm_firewall_tb.sv. Not part of the synthesisable RTL.
//
// The properties fall into three groups:
//
//   PROTOCOL  - the core must not itself break Avalon-MM on m0. There is
//               exactly one legal way to drop an unacknowledged command
//               (RECOVERY.UNBLOCK) and the assertions encode that as the only
//               exception, so any other path that learns to drop one shows up
//               here rather than on a bench.
//   SECURITY  - a denied transaction must never reach m0, and a blocked core
//               must never issue anything new. These are the properties the
//               core exists to provide; a bug in them is a silent hole rather
//               than a visible failure, which is why they are assertions and
//               not just tests.
//   LIVENESS  - a denied or abandoned transaction must still be COMPLETED
//               upstream. This is the Avalon-MM-specific hazard: there is no
//               way to refuse a transaction, only to answer it, so every
//               rejection path has to be checked for actually producing the
//               beats it owes.
//
// READ THE PASS COUNTS, NOT JUST THE FAILURE COUNTS. A property that only ever
// passes vacuously has verified nothing while looking green. Questa reports
// non-vacuous pass counts per property; the README quotes them for exactly
// this reason.
// =============================================================================

module avl_mm_firewall_sva
    import avl_mm_firewall_pkg::*;
#(
    parameter int ADDR_WIDTH  = 32,
    parameter int DATA_WIDTH  = 32,
    parameter int BURST_WIDTH = 8,
    parameter int BEATCNT_W   = 11
) (
    input logic clk,
    input logic reset_n,

    // s0
    input logic                   s0_read,
    input logic                   s0_write,
    input logic [BURST_WIDTH-1:0] s0_burstcount,
    input logic                   s0_waitrequest,
    input logic                   s0_readdatavalid,
    input logic                   s0_writeresponsevalid,
    input logic [1:0]             s0_response,

    // m0
    input logic                   m0_read,
    input logic                   m0_write,
    input logic [ADDR_WIDTH-1:0]  m0_address,
    input logic [BURST_WIDTH-1:0] m0_burstcount,
    input logic                   m0_waitrequest,
    input logic                   m0_readdatavalid,

    // internals
    input logic                 downstream_broken,
    input logic                 wr_stuck,
    input logic                 rd_stuck,
    input logic                 unblock,
    input logic [BEATCNT_W-1:0] rd_fwd_beats,
    input logic [BEATCNT_W-1:0] rd_deny_beats,
    input fw_code_e             wr_dec,
    input fw_code_e             rd_dec,
    input logic                 wr_start,
    input logic                 rd_accept,
    input logic                 wr_active,
    // 1 while a registered lookup is resolving. Constant 0 when
    // REGISTER_LOOKUP is off, so every property below is unchanged there.
    input logic                 lk_stall,
    input logic                 wr_allow,
    input logic                 rd_allow
);

    default clocking cb @(posedge clk); endclocking
    default disable iff (!reset_n);

    // ==================================================================
    // PROTOCOL
    // ==================================================================

    // Avalon-MM read and write are mutually exclusive on one port. This is the
    // property that made the "abandon both channels on any timeout" rule
    // necessary: without it a frozen m0_read could coexist with a live
    // m0_write from a burst that was still in flight when the read timed out.
    a_no_concurrent_rw: assert property (!(m0_read && m0_write));

    // burstcount == 0 is illegal in Avalon-MM. The core coerces it to 1 so a
    // misbehaving master cannot underflow the beat counter and wedge the port,
    // but the master is still wrong and should be told so.
    a_s0_burstcount_nonzero: assert property (
        (s0_read || s0_write) |-> (s0_burstcount != '0));

    a_m0_burstcount_nonzero: assert property (
        (m0_read || m0_write) |-> (m0_burstcount != '0));

    // A master must hold read/write asserted until waitrequest falls.
    // RECOVERY.UNBLOCK is the single permitted exception, and it is legitimate
    // only because it means software has reset the peripheral. If any other
    // mechanism ever learns to drop a command, these two catch it.
    a_m0_read_held: assert property (
        (m0_read && m0_waitrequest && !unblock) |=> m0_read);

    a_m0_write_held: assert property (
        (m0_write && m0_waitrequest && !unblock) |=> m0_write);

    // A frozen command must also hold its payload steady - a held command with
    // a moving address is not a held command.
    a_m0_read_addr_stable: assert property (
        (m0_read && m0_waitrequest && !unblock) |=> $stable(m0_address) || !m0_read);

    a_m0_burst_stable: assert property (
        ((m0_read || m0_write) && m0_waitrequest && !unblock)
        |=> $stable(m0_burstcount) || !(m0_read || m0_write));

    // s0_response is shared between read data and write responses, so the two
    // must never be presented together.
    a_resp_exclusive: assert property (!(s0_readdatavalid && s0_writeresponsevalid));

    // ==================================================================
    // SECURITY
    // ==================================================================

    // A denied write must not leak a command downstream. Checked at the burst
    // start, which is the only cycle at which the verdict is formed.
    a_suppress_denied_write: assert property (
        (wr_start && !wr_allow) |-> !m0_write || wr_stuck);

    a_suppress_denied_read: assert property (
        (rd_accept && !rd_allow) |-> !m0_read || rd_stuck);

    // While blocked, no NEW command may be issued. A command frozen by the
    // block itself may legitimately stay asserted - that is the whole point of
    // wr_stuck/rd_stuck - so those are the exceptions.
    a_no_write_while_blocked: assert property (
        (downstream_broken && !wr_stuck) |-> !m0_write);

    a_no_read_while_blocked: assert property (
        (downstream_broken && !rd_stuck) |-> !m0_read);

    // The block latches: only UNBLOCK clears it. In particular, clearing
    // STATUS.TIMEOUT_ERROR must not.
    a_block_holds_until_unblock: assert property (
        (downstream_broken && !unblock) |=> downstream_broken);

    // ==================================================================
    // LIVENESS - the Avalon-MM-specific half
    // ==================================================================

    // Read data is forwarded only while beats are actually owed. This is the
    // orphan filter: a late beat from a timed-out read must be dropped, not
    // handed to a master that is no longer expecting it.
    a_no_orphan_readdata: assert property (
        (m0_readdatavalid && rd_fwd_beats == '0) |-> !s0_readdatavalid || rd_deny_beats != '0);

    // Every beat presented upstream is one the core owes.
    a_rdv_is_owed: assert property (
        s0_readdatavalid |-> (rd_fwd_beats != '0) || (rd_deny_beats != '0));

    // A denied read is accepted immediately - never stalled on the rule check.
    // Stalling it would move the hang from the peripheral into the firewall,
    // which is the failure mode this core exists to prevent.
    // The !wr_active qualifier is not a loophole: a read arriving in the
    // middle of a write burst is already a master protocol violation
    // (a_no_read_during_write_burst below), and the core holds it off rather
    // than interleaving it into the burst.
    // `!lk_stall` is an exclusion, not a loosening. The claim is that the
    // firewall never stalls a transaction ON THE RULE CHECK - that a denial is
    // answered rather than held - and that is what makes the core incapable of
    // becoming the hang it exists to prevent. With REGISTER_LOOKUP the verdict
    // costs one cycle to compute, and during that cycle there is no verdict to
    // act on yet. Every cycle after it is still covered, and
    // a_lookup_stall_bounded below caps the excluded window at exactly one
    // cycle, so nothing can hide in it.
    a_denied_read_not_stalled: assert property (
        (s0_read && !rd_allow && !wr_active && !lk_stall &&
         rd_deny_beats == '0 && rd_fwd_beats == '0)
        |-> !s0_waitrequest);

    // Avalon-MM bursts are atomic on a port: once a write burst starts, its
    // beats are consecutive transfers and no read may be issued between them.
    a_no_read_during_write_burst: assert property (!(wr_active && s0_read));

    // ...and it must then actually produce beats, rather than quietly leaving
    // the master waiting.
    a_denied_read_drains: assert property (
        (rd_accept && !rd_allow) |=> (rd_deny_beats != '0));

    a_deny_drain_progresses: assert property (
        (rd_deny_beats != '0) |-> s0_readdatavalid);

    // A denied write is likewise consumed immediately rather than stalled.
    a_denied_write_not_stalled: assert property (
        (wr_start && !wr_allow && !lk_stall) |-> !s0_waitrequest);

    // The lookup stall is exactly one cycle. Without this the exclusions above
    // would be a hole: a stall that could persist would let the core hold a
    // transaction indefinitely and still satisfy both properties.
    a_lookup_stall_bounded: assert property (lk_stall |=> !lk_stall);

    // And it only ever applies to a command. Beats 2..N of a write burst carry
    // no address and must never be stalled by the lookup, or the one-cycle
    // cost would become per-beat and the burst throughput claim would be lost.
    a_no_lookup_stall_mid_burst: assert property (!(lk_stall && wr_active));

    // ==================================================================
    // COVER - proof the interesting paths were REACHED, not merely never
    // violated. An assertion that was never evaluated is not evidence.
    // ==================================================================
    c_write_denied:   cover property (wr_start  && wr_dec == FW_PERM);
    c_read_denied:    cover property (rd_accept && rd_dec == FW_PERM);
    c_write_decerr:   cover property (wr_start  && wr_dec == FW_ADDR);
    c_read_decerr:    cover property (rd_accept && rd_dec == FW_ADDR);

    // The two burst-specific verdicts - the reason this core exists rather
    // than the AXI4-Lite one being reused.
    c_burst_range_wr: cover property (wr_start  && wr_dec == FW_BURST_RANGE);
    c_burst_range_rd: cover property (rd_accept && rd_dec == FW_BURST_RANGE);
    c_burst_denied:   cover property ((wr_start && wr_dec == FW_BURST_DENIED) ||
                                      (rd_accept && rd_dec == FW_BURST_DENIED));

    // A full block-then-release episode.
    c_block_and_recover: cover property (
        (!downstream_broken ##1 downstream_broken) ##[1:2000] unblock);

    // An unblock that had to discard a command the peripheral never accepted -
    // the case where polling the busy bits alone would never have sufficed.
    c_unblock_with_stuck_cmd: cover property ((wr_stuck || rd_stuck) && unblock);

    // Beats streaming back-to-back: the throughput claim in the README is only
    // meaningful if the bench ever actually achieves it.
    c_burst_streaming: cover property (
        s0_readdatavalid [*8]);

    // A write burst forwarded with no wait states at all.
    c_write_streaming: cover property (
        (m0_write && !m0_waitrequest) [*8]);

endmodule
