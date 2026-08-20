// Carries a `timescale even though it is pure synthesisable RTL with no
// delays. Mixing timescaled and untimescaled modules in one compilation is
// tool-dependent (IEEE 1800 3.14.2.3) - slang rejects it outright, Verilator
// warns (TIMESCALEMOD), Questa accepts it silently. Quartus ignores the
// directive for synthesis, so declaring it costs nothing and removes the
// ambiguity.
`timescale 1ns/1ps

// =============================================================================
// avl_mm_firewall_top.sv
//
// Avalon-MM Access-Control + Fault-Isolation Firewall, with burst support.
//
//   s0   : Avalon-MM SLAVE  - connects toward the master (Nios II, mSGDMA,
//          anything Platform Designer will wire up). This is the port being
//          "asked". Byte-addressed, bursting, pipelined reads.
//   m0   : Avalon-MM MASTER - connects toward the protected peripheral. This
//          is the port being "protected".
//   csr  : Avalon-MM SLAVE  - separate control/status port, 32-bit,
//          word-addressed, fixed read latency 1, never asserts waitrequest.
//          Kept physically separate from the data path on purpose: control
//          access must never be blockable by a firewall rule or by an
//          isolated/hung downstream peripheral.
//   irq  : level interrupt, asserted while any enabled sticky fault bit in
//          STATUS is set. Clear at the source (write 1 to the relevant STATUS
//          bit) to deassert - the standard Avalon-MM peripheral idiom, which
//          works directly with the Nios II HAL ISR pattern.
//
// -----------------------------------------------------------------------------
// ARCHITECTURE: a gate, not a buffer.
// -----------------------------------------------------------------------------
// The AXI4-Lite sibling of this core (../altera_axi4_lite_firewall) captures a
// transaction into registers, evaluates it, then re-drives it downstream. That
// costs six cycles per transaction, which is fine for a CPU poking registers
// and hopeless for a DMA engine - and it does not generalise to bursts without
// growing a data FIFO.
//
// This core instead evaluates combinationally and passes through:
//
//     ALLOWED  -> m0_read/m0_write are s0_read/s0_write gated by the rule
//                 lookup; s0_waitrequest is m0_waitrequest; read data flows
//                 back untouched. ZERO added latency, full burst throughput,
//                 no data storage anywhere in the core.
//     DENIED   -> m0 is never touched at all, and the firewall answers the
//                 master itself.
//
// The cost is a combinational path from s0_address through NUM_RULES address
// comparators to m0_read/m0_write and s0_waitrequest. That is the critical
// path and it grows with NUM_RULES; see README.md "Performance".
//
// -----------------------------------------------------------------------------
// WHY BURSTS ARE THE HARD PART
// -----------------------------------------------------------------------------
// 1. A DENIED TRANSACTION MUST STILL BE COMPLETED. Avalon-MM has no way to
//    abort. A denied read burst of N beats must still produce N beats of
//    readdatavalid or the master waits forever; a denied write burst must
//    still have all N beats consumed. So "deny" does not mean "ignore" - it
//    means the firewall becomes the responder and synthesises the whole
//    burst's worth of error responses. That is what rd_deny_beats does.
//
// 2. THE WHOLE BURST RANGE MUST BE CHECKED, NOT THE START ADDRESS. A burst
//    beginning one beat inside an allowed window and running for 128 beats
//    ends up well outside it. Checking only s0_address builds a firewall that
//    a DMA engine walks straight through. Both the first and the last byte of
//    every transaction are checked against the SAME matched rule - see
//    chk_*_contain in avl_mm_firewall_regs.sv and FW_BURST_RANGE below.
//
// 3. THE DECISION MUST BE LATCHED FOR THE WHOLE BURST. On beats 2..N of an
//    Avalon-MM write burst the master does not present a meaningful address -
//    only writedata. Re-evaluating the rule per beat would evaluate garbage.
//    wr_fwd holds the burst start's verdict for the burst's duration.
//
// 4. READ DATA CANNOT BE BACKPRESSURED. Avalon-MM readdatavalid has no ready
//    signal, so a late beat from an already-timed-out read cannot be held off
//    - it can only be dropped. rd_fwd_beats is that filter: m0_readdatavalid
//    is forwarded only while beats are actually owed, and orphans from a
//    timed-out or abandoned read are discarded. (The AXI sibling had a
//    discard mechanism too; there it turned out to be unreachable dead code
//    and was removed. Here it is load-bearing, because AXI's RREADY gives you
//    an option Avalon-MM does not.)
//
// -----------------------------------------------------------------------------
// TIMEOUT RECOVERY
// -----------------------------------------------------------------------------
// The Avalon-MM hang mode is waitrequest stuck high, or readdatavalid that
// never arrives. On either, the core:
//
//   (a) completes the upstream transaction immediately - synthesising the
//       remaining read beats as SLAVEERROR, or consuming and discarding the
//       remaining write beats - so the master never hangs;
//   (b) latches `downstream_broken`, which blocks all further forwarding
//       regardless of the ISOLATE bits;
//   (c) FREEZES, rather than withdraws, an m0 command whose waitrequest never
//       fell. Avalon-MM requires a master to hold read/write asserted until
//       waitrequest deasserts; dropping it can wedge the interconnect between
//       this core and the peripheral, not just the peripheral.
//
// Recovery is an explicit software sequence, the same shape AMD document for
// their AXI Firewall (PG293), which has the same requirement:
//
//   1. stop issuing transactions to s0
//   2. write 1 to the sticky STATUS bits (acknowledge; also releases the
//      auto-isolate latch)
//   3. poll STATUS until WR_BUSY and RD_BUSY clear, WITH A BOUND
//   4. ASSERT the protected peripheral's reset and HOLD it (>= 16 clocks)
//   5. write RECOVERY.UNBLOCK  -- while the reset is still asserted
//   6. release the peripheral's reset
//   7. resume
//
// Step 5 is the single point at which downstream state is declared discarded:
// it releases `downstream_broken` and is the only place a frozen m0_read or
// m0_write may be dropped without waitrequest having fallen.
//
// !! ORDERING MATTERS between 5 and 6, and this is where this core deviates
// from AMD's published flow. A frozen command is held asserted on m0. If the
// peripheral is already out of reset when UNBLOCK arrives, it can complete
// that command's handshake first - latching a transaction the core has already
// reported to the master as failed. Withdrawing the command while the
// peripheral is held in reset closes that window completely, and costs
// nothing. The regression covers both the held-in-reset check and the
// UNBLOCK-with-a-stuck-command case (c_unblock_with_stuck_cmd).
//
// !! Step 4 is not optional. Bound the poll in step 3: the busy bits mean "the
// peripheral owes us something", and a peripheral that accepted a command and
// then died owes it forever, so an unbounded poll hangs precisely when
// recovery is needed. WR_CMD_STUCK / RD_CMD_STUCK tell you the other case - a
// command the peripheral never even accepted, which only UNBLOCK can clear.
//
// -----------------------------------------------------------------------------
// TWO KINDS OF PROTOCOL BREAKAGE, AND WHY ONLY ONE IS AVOIDABLE
// -----------------------------------------------------------------------------
// Abandoning a forwarded write burst part-way leaves the downstream slave
// waiting for beats that never come. That is unavoidable: the master upstream
// must be released, and Avalon-MM has no burst-abort. It is also why step 4
// exists.
//
// What IS avoidable is withdrawing a command whose handshake never completed,
// and the core never does that: if waitrequest is still high when a
// transaction is abandoned, the command is frozen into wr_hold_*/rd_hold_* and
// held asserted until UNBLOCK. The distinction matters because the first only
// confuses the peripheral, while the second can wedge the interconnect.
//
// -----------------------------------------------------------------------------
// OTHER DESIGN NOTES
// -----------------------------------------------------------------------------
//   - Default-deny. An address in no valid rule is rejected (DECODEERROR); an
//     address in a rule but not for the requested direction is rejected
//     (SLAVEERROR). Allow-list model, secure at reset.
//   - Rule priority: the lowest-index valid rule containing the START address
//     wins. Rules need not be disjoint; put more specific rules lower.
//   - Decision priority within a rule: direction (PERM) is checked before
//     extent (RANGE), so a write burst into a read-only window reports
//     PERM_VIOLATION rather than a confusing burst error.
//   - Adjacent windows do NOT merge. A burst spanning two abutting rules is a
//     DEC_RANGE violation even if both permit the access, because permissions
//     are per-window and the burst would have to satisfy both.
//   - Bypass mode (CTRL.GLOBAL_ENABLE=0) skips the rule check but NOT the
//     downstream-broken block. A wedged peripheral stays walled off even with
//     the firewall's access control switched off - isolation and access
//     control are separate jobs.
//   - Only one denied read burst is in flight at a time, and no new read is
//     accepted while one is draining. That is what keeps Avalon-MM's in-order
//     read response requirement satisfied without a reorder buffer.
//   - If a read fault and a write fault land in the same cycle, both sticky
//     STATUS bits are set correctly but FAULT_ADDR/FAULT_INFO capture the
//     write side (documented, deterministic tie-break).
//
// LANGUAGE: SystemVerilog (IEEE 1800), synthesisable subset.
// =============================================================================

module avl_mm_firewall_top
    import avl_mm_firewall_pkg::*;
#(
    parameter int ADDR_WIDTH        = 32, // data-path byte address width
    parameter int DATA_WIDTH        = 32, // 8, 16, 32, 64, 128, 256, 512, 1024
    parameter int BURST_WIDTH       = 8,  // burstcount width; max beats = 2**(BURST_WIDTH-1)
    parameter int MAX_PENDING_READS = 4,  // outstanding read bursts the core will track
    parameter int NUM_RULES         = 8,
    parameter int TIMEOUT_WIDTH     = 20,
    parameter int CSR_ADDR_WIDTH    = 8,  // CSR port address width, IN WORDS
    parameter int USE_WRITE_RESPONSE = 0  // 1 => writeresponsevalid/response on writes
) (
    input  logic                       clk,
    input  logic                       reset_n,     // active-low, synchronous

    // ---------------- s0 : protected data-path slave ----------------------
    input  logic [ADDR_WIDTH-1:0]      s0_address,
    input  logic                       s0_read,
    input  logic                       s0_write,
    input  logic [DATA_WIDTH-1:0]      s0_writedata,
    input  logic [DATA_WIDTH/8-1:0]    s0_byteenable,
    input  logic [BURST_WIDTH-1:0]     s0_burstcount,
    output logic                       s0_waitrequest,
    output logic [DATA_WIDTH-1:0]      s0_readdata,
    output logic                       s0_readdatavalid,
    output logic [1:0]                 s0_response,
    output logic                       s0_writeresponsevalid,

    // ---------------- m0 : protected data-path master ---------------------
    output logic [ADDR_WIDTH-1:0]      m0_address,
    output logic                       m0_read,
    output logic                       m0_write,
    output logic [DATA_WIDTH-1:0]      m0_writedata,
    output logic [DATA_WIDTH/8-1:0]    m0_byteenable,
    output logic [BURST_WIDTH-1:0]     m0_burstcount,
    input  logic                       m0_waitrequest,
    input  logic [DATA_WIDTH-1:0]      m0_readdata,
    input  logic                       m0_readdatavalid,
    input  logic [1:0]                 m0_response,
    input  logic                       m0_writeresponsevalid,

    // ---------------- csr : control/status slave --------------------------
    input  logic [CSR_ADDR_WIDTH-1:0]  csr_address,
    input  logic                       csr_read,
    input  logic                       csr_write,
    input  logic [31:0]                csr_writedata,
    input  logic [3:0]                 csr_byteenable,
    output logic [31:0]                csr_readdata,

    output logic                       irq
);

    // ------------------------------------------------------------------
    // Derived sizes
    // ------------------------------------------------------------------
    localparam int BYTES       = DATA_WIDTH/8;
    localparam int BEAT_SHIFT  = $clog2(BYTES);          // 0 when DATA_WIDTH==8
    localparam int MAX_BEATS   = 2**(BURST_WIDTH-1);     // Avalon-MM max burst
    localparam int RD_CAPACITY = MAX_PENDING_READS * MAX_BEATS;
    // +1 bit of headroom so rd_fwd_beats + burstcount cannot overflow while
    // the headroom check is being evaluated.
    localparam int BEATCNT_W   = $clog2(RD_CAPACITY+1) + 1;

    localparam bit HAS_WRESP = (USE_WRITE_RESPONSE != 0);

    // Response encoding, verdict codes (fw_code_e) and fw_resp() all come from
    // avl_mm_firewall_pkg, shared with the register block.

    // ------------------------------------------------------------------
    // Register-block interface
    // ------------------------------------------------------------------
    logic                     global_enable;
    logic                     isolate_effective;
    logic [TIMEOUT_WIDTH-1:0] timeout_value;
    logic                     unblock;

    logic [ADDR_WIDTH-1:0] chk_w_addr, chk_w_last;
    logic                  chk_w_match, chk_w_allow, chk_w_contain, chk_w_burst_en;
    logic [ADDR_WIDTH-1:0] chk_r_addr, chk_r_last;
    logic                  chk_r_match, chk_r_allow, chk_r_contain, chk_r_burst_en;

    // Declared here, above the avl_mm_firewall_regs instantiation, not next to
    // the logic that drives them. Connecting an undeclared identifier to a
    // port creates an implicit net at that point, which then collides with the
    // later explicit declaration - Verilator resolves the forward reference,
    // Questa and slang correctly reject it.
    logic downstream_broken;
    logic wr_stuck, rd_stuck;
    logic wr_busy, rd_busy;

    // Per-direction fault pulses, registered (see the always_ff blocks below).
    logic                   wr_flt_addr, wr_flt_perm, wr_flt_burst, wr_flt_to;
    fw_code_e               wr_flt_type;
    logic [ADDR_WIDTH-1:0]  wr_flt_addr_val;
    logic [BURST_WIDTH-1:0] wr_flt_burstcount;

    logic                   rd_flt_addr, rd_flt_perm, rd_flt_burst, rd_flt_to;
    fw_code_e               rd_flt_type;
    logic [ADDR_WIDTH-1:0]  rd_flt_addr_val;
    logic [BURST_WIDTH-1:0] rd_flt_burstcount;

    // Merged for the register block. The write side wins the address /
    // type / burstcount tie-break when both fire in the same cycle.
    logic                   wr_flt_any;
    logic                   fault_addr_violation, fault_perm_violation;
    logic                   fault_timeout, fault_burst_violation;
    fw_code_e               fault_type_in;
    logic [ADDR_WIDTH-1:0]  fault_addr_value;
    logic                   fault_was_write;
    logic [BURST_WIDTH-1:0] fault_burstcount;

    assign wr_flt_any = wr_flt_addr | wr_flt_perm | wr_flt_burst | wr_flt_to;

    assign fault_addr_violation  = wr_flt_addr  | rd_flt_addr;
    assign fault_perm_violation  = wr_flt_perm  | rd_flt_perm;
    assign fault_timeout         = wr_flt_to    | rd_flt_to;
    assign fault_burst_violation = wr_flt_burst | rd_flt_burst;

    assign fault_was_write  = wr_flt_any;
    assign fault_type_in    = wr_flt_any ? wr_flt_type       : rd_flt_type;
    assign fault_addr_value = wr_flt_any ? wr_flt_addr_val   : rd_flt_addr_val;
    assign fault_burstcount = wr_flt_any ? wr_flt_burstcount : rd_flt_burstcount;

    avl_mm_firewall_regs #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .DATA_WIDTH     (DATA_WIDTH),
        .BURST_WIDTH    (BURST_WIDTH),
        .CSR_ADDR_WIDTH (CSR_ADDR_WIDTH),
        .NUM_RULES      (NUM_RULES),
        .TIMEOUT_WIDTH  (TIMEOUT_WIDTH)
    ) u_regs (
        .clk                   (clk),
        .reset_n               (reset_n),

        .csr_address           (csr_address),
        .csr_read              (csr_read),
        .csr_write             (csr_write),
        .csr_writedata         (csr_writedata),
        .csr_byteenable        (csr_byteenable),
        .csr_readdata          (csr_readdata),

        .irq                   (irq),

        .global_enable         (global_enable),
        .isolate_effective     (isolate_effective),
        .timeout_value         (timeout_value),

        .chk_w_addr            (chk_w_addr),
        .chk_w_last            (chk_w_last),
        .chk_w_match           (chk_w_match),
        .chk_w_allow           (chk_w_allow),
        .chk_w_contain         (chk_w_contain),
        .chk_w_burst_en        (chk_w_burst_en),

        .chk_r_addr            (chk_r_addr),
        .chk_r_last            (chk_r_last),
        .chk_r_match           (chk_r_match),
        .chk_r_allow           (chk_r_allow),
        .chk_r_contain         (chk_r_contain),
        .chk_r_burst_en        (chk_r_burst_en),

        .fault_addr_violation  (fault_addr_violation),
        .fault_perm_violation  (fault_perm_violation),
        .fault_timeout         (fault_timeout),
        .fault_burst_violation (fault_burst_violation),
        .fault_type_in         (fault_type_in),
        .fault_addr_value      (fault_addr_value),
        .fault_was_write       (fault_was_write),
        .fault_burstcount      (fault_burstcount),

        .dstat_blocked         (downstream_broken),
        .dstat_wr_busy         (wr_busy),
        .dstat_rd_busy         (rd_busy),
        .dstat_wr_cmd_stuck    (wr_stuck),
        .dstat_rd_cmd_stuck    (rd_stuck),
        .unblock               (unblock)
    );

    // ==================================================================
    // TRANSACTION EXTENT
    //
    // One adder, shared by both channels, because s0_address and
    // s0_burstcount are shared. The extra bit on burst_last_ext catches a
    // burst that wraps past the top of the address space, which is treated as
    // a range violation rather than silently aliasing to low addresses.
    //
    // Avalon-MM forbids burstcount == 0, but a master that emits it would
    // otherwise underflow wr_beats_left and hang the port, so it is coerced to
    // 1 here and flagged by an assertion in tb/avl_mm_firewall_sva.sv.
    // ==================================================================
    logic [BURST_WIDTH-1:0] bcnt;
    logic                   is_burst;
    logic [ADDR_WIDTH:0]    burst_last_ext;
    logic [ADDR_WIDTH-1:0]  burst_last;
    logic                   burst_wrap;

    assign bcnt     = (s0_burstcount == '0) ? BURST_WIDTH'(1) : s0_burstcount;
    assign is_burst = (bcnt != BURST_WIDTH'(1));

    assign burst_last_ext = {1'b0, s0_address} +
                            (((ADDR_WIDTH+1)'(bcnt)) << BEAT_SHIFT) - (ADDR_WIDTH+1)'(1);
    assign burst_last = burst_last_ext[ADDR_WIDTH-1:0];
    assign burst_wrap = burst_last_ext[ADDR_WIDTH];

    assign chk_w_addr = s0_address;
    assign chk_w_last = burst_last;
    assign chk_r_addr = s0_address;
    assign chk_r_last = burst_last;

    // ==================================================================
    // DECISION
    // ==================================================================
    // `blocked` is checked before `bypass` on purpose: CTRL.GLOBAL_ENABLE=0
    // turns off access control, not fault isolation. A peripheral that has
    // already wedged the bus stays walled off either way.
    function automatic fw_code_e decide(
            input logic blocked, input logic gen_en,
            input logic match, input logic allow,
            input logic contain, input logic burst_en,
            input logic isb, input logic wrap);
        if (blocked)                return FW_BLOCKED;
        if (!gen_en)                return FW_ALLOW;    // bypass mode
        if (!match)                 return FW_ADDR;
        if (!allow)                 return FW_PERM;
        if (wrap || !contain)       return FW_BURST_RANGE;
        if (isb && !burst_en)       return FW_BURST_DENIED;
        return FW_ALLOW;
    endfunction

    logic forward_blocked;
    assign forward_blocked = isolate_effective | downstream_broken;

    fw_code_e wr_dec, rd_dec;
    logic     wr_allow, rd_allow;

    assign wr_dec = decide(forward_blocked, global_enable,
                           chk_w_match, chk_w_allow, chk_w_contain, chk_w_burst_en,
                           is_burst, burst_wrap);
    assign rd_dec = decide(forward_blocked, global_enable,
                           chk_r_match, chk_r_allow, chk_r_contain, chk_r_burst_en,
                           is_burst, burst_wrap);
    assign wr_allow = (wr_dec == FW_ALLOW);
    assign rd_allow = (rd_dec == FW_ALLOW);

    // ==================================================================
    // WRITE CHANNEL STATE
    // ==================================================================
    logic [BURST_WIDTH-1:0]   wr_beats_left;  // beats still to come after the last accepted
    logic                     wr_fwd;         // current burst is being forwarded
    logic [1:0]               wr_resp_code;   // response the current burst will report
    logic [ADDR_WIDTH-1:0]    wr_hold_addr;
    logic [DATA_WIDTH-1:0]    wr_hold_data;
    logic [BYTES-1:0]         wr_hold_be;
    logic [BURST_WIDTH-1:0]   wr_hold_burst;
    logic [TIMEOUT_WIDTH-1:0] wr_to;
    logic                     wr_resp_wait;   // awaiting m0_writeresponsevalid
    logic                     wr_resp_out;    // s0 write response pending emission
    logic [1:0]               wr_resp_out_code;
    logic [ADDR_WIDTH-1:0]    wr_burst_addr;  // start address of the current burst
    logic [BURST_WIDTH-1:0]   wr_burst_cnt;

    // ==================================================================
    // READ CHANNEL STATE
    // ==================================================================
    logic [BEATCNT_W-1:0]     rd_fwd_beats;   // beats owed by m0
    logic [BEATCNT_W-1:0]     rd_deny_beats;  // beats the core must synthesise
    logic [1:0]               rd_deny_resp;
    logic [ADDR_WIDTH-1:0]    rd_hold_addr;
    logic [BURST_WIDTH-1:0]   rd_hold_burst;
    logic [TIMEOUT_WIDTH-1:0] rd_to;
    logic [ADDR_WIDTH-1:0]    rd_burst_addr;
    logic [BURST_WIDTH-1:0]   rd_burst_cnt;

    // ------------------------------------------------------------------
    // Gating and handshakes (all combinational)
    // ------------------------------------------------------------------
    logic wr_active;          // a write burst is in progress on s0
    logic wr_resp_busy;       // a write response is still owed upstream
    logic wr_gate;            // the core is able to start forwarding a write
    logic rd_gate_allow;      // ...able to forward a read command
    logic rd_gate_deny;       // ...able to accept a read it intends to deny
    logic rd_deny_emit;       // synthesising a denied read beat this cycle
    logic rd_headroom;
    logic [BEATCNT_W-1:0] rd_beats_after;

    assign wr_active    = (wr_beats_left != '0);
    assign wr_resp_busy = HAS_WRESP && (wr_resp_wait || wr_resp_out);

    // A frozen command on either channel owns m0 exclusively - Avalon-MM
    // read and write are mutually exclusive - so neither may be issued while
    // the other is stuck. In practice a stuck command implies
    // downstream_broken, which already forces FW_BLOCKED; these terms also
    // cover bypass mode, where FW_BLOCKED is still returned but the belt and
    // braces cost nothing.
    assign wr_gate = !wr_stuck && !rd_stuck && !wr_resp_busy;

    assign rd_beats_after = rd_fwd_beats + BEATCNT_W'(bcnt);
    assign rd_headroom    = (rd_beats_after <= BEATCNT_W'(RD_CAPACITY));

    assign rd_gate_allow = (rd_deny_beats == '0) && rd_headroom &&
                           !rd_stuck && !wr_stuck && !wr_active;
    // Ordering: a denied read is answered by the core, so it must not overtake
    // read data still owed by m0 for earlier commands. Waiting for
    // rd_fwd_beats to drain is what keeps Avalon-MM's in-order read response
    // requirement satisfied without a reorder buffer.
    assign rd_gate_deny  = (rd_deny_beats == '0) && (rd_fwd_beats == '0) && !wr_active;

    assign rd_deny_emit = (rd_deny_beats != '0);

    // ---- m0 command drive ----
    logic m0_write_i, m0_read_i;

    assign m0_write_i = wr_stuck ? 1'b1
                      : (s0_write && (wr_active ? wr_fwd : (wr_allow && wr_gate)));
    assign m0_read_i  = rd_stuck ? 1'b1
                      : (s0_read && rd_allow && rd_gate_allow);

    assign m0_write = m0_write_i;
    assign m0_read  = m0_read_i;

    assign m0_address    = wr_stuck ? wr_hold_addr  : (rd_stuck ? rd_hold_addr  : s0_address);
    assign m0_burstcount = wr_stuck ? wr_hold_burst : (rd_stuck ? rd_hold_burst : bcnt);
    assign m0_writedata  = wr_stuck ? wr_hold_data  : s0_writedata;
    assign m0_byteenable = wr_stuck ? wr_hold_be    : s0_byteenable;

    // ---- s0_waitrequest ----
    //
    // Avalon-MM explicitly permits waitrequest to be a combinational function
    // of read/write, which is what makes the zero-latency pass-through legal.
    //
    // A denied transaction is NEVER stalled on the rule check itself - it is
    // accepted immediately and answered with an error. Stalling it would just
    // move the hang from the peripheral into the firewall.
    logic wr_wait, rd_wait;

    assign wr_wait = wr_active ? (wr_fwd ? m0_waitrequest : 1'b0)
                               : (wr_allow ? (wr_gate ? m0_waitrequest : 1'b1) : 1'b0);
    assign rd_wait = rd_allow  ? (rd_gate_allow ? m0_waitrequest : 1'b1)
                               : (rd_gate_deny  ? 1'b0           : 1'b1);

    always_comb begin
        if (s0_write)     s0_waitrequest = wr_wait;
        else if (s0_read) s0_waitrequest = rd_wait;
        else              s0_waitrequest = 1'b0;
    end

    logic wr_accept, rd_accept, wr_start, wr_last_beat, wr_fwd_now;

    assign wr_accept   = s0_write && !s0_waitrequest;
    assign rd_accept   = s0_read  && !s0_waitrequest;
    assign wr_start    = wr_accept && !wr_active;
    assign wr_fwd_now  = wr_active ? wr_fwd : wr_allow;
    assign wr_last_beat = wr_accept && (wr_active ? (wr_beats_left == BURST_WIDTH'(1))
                                                  : (bcnt == BURST_WIDTH'(1)));

    // ---- s0 response path ----
    //
    // s0_response is shared between read data and write responses, so the two
    // must never be presented in the same cycle. Read data wins and the write
    // response waits a cycle; it is a single pending flag, not a queue,
    // because a new write burst cannot start while one is outstanding.
    logic rd_fwd_valid;
    assign rd_fwd_valid = m0_readdatavalid && (rd_fwd_beats != '0);

    assign s0_readdatavalid = rd_fwd_valid || rd_deny_emit;
    assign s0_readdata      = rd_deny_emit ? '0 : m0_readdata;

    always_comb begin
        if (rd_deny_emit)      s0_response = rd_deny_resp;
        else if (rd_fwd_valid) s0_response = m0_response;
        else                   s0_response = wr_resp_out_code;
    end

    assign s0_writeresponsevalid = HAS_WRESP && wr_resp_out && !s0_readdatavalid;

    // ---- status exported to the register block ----
    assign wr_busy = (wr_active && wr_fwd) || (HAS_WRESP && wr_resp_wait);
    assign rd_busy = (rd_fwd_beats != '0);

    // ==================================================================
    // TIMEOUTS
    //
    // "No progress for N cycles", not "N cycles since the transaction
    // started". A 128-beat burst against a slow peripheral is progress; a
    // peripheral that has not taken a beat or produced one for N cycles is
    // not. Timing a whole burst would force TIMEOUT_VALUE to be scaled by the
    // longest burst, which would make it useless as a hang detector.
    // ==================================================================
    logic wr_to_active, wr_to_reset, wr_to_fire;
    logic rd_to_active, rd_to_reset, rd_to_fire;

    assign wr_to_active = m0_write_i || (HAS_WRESP && wr_resp_wait);
    assign wr_to_reset  = (m0_write_i && !m0_waitrequest) ||
                          (HAS_WRESP && wr_resp_wait && m0_writeresponsevalid);
    assign wr_to_fire   = wr_to_active && !wr_to_reset && (wr_to >= timeout_value);

    assign rd_to_active = m0_read_i || (rd_fwd_beats != '0);
    assign rd_to_reset  = (m0_read_i && !m0_waitrequest) || m0_readdatavalid;
    assign rd_to_fire   = rd_to_active && !rd_to_reset && (rd_to >= timeout_value);

    // A timeout on either channel declares the whole downstream broken and
    // abandons work on BOTH. Letting one channel keep forwarding into a
    // peripheral the other has just given up on would also let a frozen
    // m0_read coexist with a live m0_write, which Avalon-MM forbids.
    logic abandon;
    assign abandon = wr_to_fire || rd_to_fire;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            wr_to <= '0;
            rd_to <= '0;
        end else begin
            if (wr_to_reset || !wr_to_active || abandon) wr_to <= '0;
            else if (wr_to < timeout_value)              wr_to <= wr_to + 1'b1;

            if (rd_to_reset || !rd_to_active || abandon) rd_to <= '0;
            else if (rd_to < timeout_value)              rd_to <= rd_to + 1'b1;
        end
    end

    // ==================================================================
    // DOWNSTREAM BLOCK / UNBLOCK
    //
    // Kept separate from isolate_effective on purpose: blocking after a
    // timeout is required for protocol safety and must not depend on
    // CTRL.AUTO_ISOLATE_EN, which governs only the visible ISOLATED bit.
    // ==================================================================
    always_ff @(posedge clk) begin
        if (!reset_n)     downstream_broken <= 1'b0;
        else if (abandon) downstream_broken <= 1'b1;   // a fresh fault always wins
        else if (unblock) downstream_broken <= 1'b0;
    end

    // ==================================================================
    // WRITE CHANNEL
    // ==================================================================
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            wr_beats_left     <= '0;
            wr_fwd            <= 1'b0;
            wr_resp_code      <= RESP_OKAY;
            wr_stuck          <= 1'b0;
            wr_hold_addr      <= '0;
            wr_hold_data      <= '0;
            wr_hold_be        <= '0;
            wr_hold_burst     <= '0;
            wr_resp_wait      <= 1'b0;
            wr_resp_out       <= 1'b0;
            wr_resp_out_code  <= RESP_OKAY;
            wr_burst_addr     <= '0;
            wr_burst_cnt      <= '0;
            wr_flt_addr       <= 1'b0;
            wr_flt_perm       <= 1'b0;
            wr_flt_burst      <= 1'b0;
            wr_flt_to         <= 1'b0;
            wr_flt_type       <= FW_ALLOW;
            wr_flt_addr_val   <= '0;
            wr_flt_burstcount <= '0;
        end else begin
            // defaults - fault pulses last exactly one cycle
            wr_flt_addr  <= 1'b0;
            wr_flt_perm  <= 1'b0;
            wr_flt_burst <= 1'b0;
            wr_flt_to    <= 1'b0;

            // Track the start address of whatever burst is being presented, so
            // a timeout has something meaningful to report even when the burst
            // never got past its first beat.
            if (s0_write && !wr_active) begin
                wr_burst_addr <= s0_address;
                wr_burst_cnt  <= bcnt;
            end

            // ---- beat accounting ----
            if (wr_accept) begin
                if (!wr_active) begin
                    wr_beats_left <= bcnt - BURST_WIDTH'(1);
                    wr_fwd        <= wr_allow;
                    wr_resp_code  <= wr_allow ? RESP_OKAY : fw_resp(wr_dec);
                end else begin
                    wr_beats_left <= wr_beats_left - BURST_WIDTH'(1);
                end
            end

            // ---- violation reporting, once per burst, at its first beat ----
            // FW_BLOCKED raises no fault: the timeout that caused the block
            // already latched one, and every subsequent rejection would
            // otherwise re-latch FAULT_ADDR and lose the original.
            if (wr_start && !wr_allow && (wr_dec != FW_BLOCKED)) begin
                wr_flt_type       <= wr_dec;
                wr_flt_addr_val   <= s0_address;
                wr_flt_burstcount <= bcnt;
                case (wr_dec)
                    FW_ADDR: wr_flt_addr  <= 1'b1;
                    FW_PERM: wr_flt_perm  <= 1'b1;
                    default:  wr_flt_burst <= 1'b1;   // FW_BURST_RANGE, FW_BURST_DENIED
                endcase
            end

            // ---- write response bookkeeping ----
            if (HAS_WRESP) begin
                if (wr_last_beat) begin
                    if (wr_fwd_now) begin
                        wr_resp_wait <= 1'b1;         // ask the peripheral
                    end else begin
                        wr_resp_out      <= 1'b1;     // answer it ourselves
                        wr_resp_out_code <= wr_active ? wr_resp_code : fw_resp(wr_dec);
                    end
                end
                if (wr_resp_wait && m0_writeresponsevalid) begin
                    wr_resp_wait     <= 1'b0;
                    wr_resp_out      <= 1'b1;
                    wr_resp_out_code <= m0_response;
                end
                if (s0_writeresponsevalid) wr_resp_out <= 1'b0;
            end

            // ---- abandonment ----
            if (abandon) begin
                // Freeze a command whose waitrequest never fell. Withdrawing it
                // is the one protocol violation this core refuses to commit;
                // only RECOVERY.UNBLOCK may drop it.
                if (m0_write_i && m0_waitrequest) begin
                    wr_stuck      <= 1'b1;
                    wr_hold_addr  <= m0_address;
                    wr_hold_data  <= m0_writedata;
                    wr_hold_be    <= m0_byteenable;
                    wr_hold_burst <= m0_burstcount;
                end
                // Stop forwarding the rest of this burst; remaining beats are
                // consumed from s0 and discarded so the master is released.
                wr_fwd       <= 1'b0;
                wr_resp_code <= RESP_SLAVEERROR;
                if (HAS_WRESP && (wr_active || wr_resp_wait)) begin
                    wr_resp_wait     <= 1'b0;
                    wr_resp_out      <= 1'b1;
                    wr_resp_out_code <= RESP_SLAVEERROR;
                end
            end

            if (wr_to_fire) begin
                wr_flt_to         <= 1'b1;
                wr_flt_type       <= FW_TIMEOUT;
                wr_flt_addr_val   <= wr_burst_addr;
                wr_flt_burstcount <= wr_burst_cnt;
            end

            // A completed handshake releases the freeze naturally: the beat
            // finally went, so there is nothing unacknowledged left to hold.
            if (wr_stuck && !m0_waitrequest) wr_stuck <= 1'b0;

            if (unblock) begin
                // The single authorised withdrawal point. Legitimate only
                // because UNBLOCK means "software has reset the peripheral;
                // its Avalon-MM state is gone".
                wr_stuck <= 1'b0;
            end
        end
    end

    // ==================================================================
    // READ CHANNEL
    // ==================================================================
    logic [BEATCNT_W-1:0] rd_fwd_next;

    always_comb begin
        rd_fwd_next = rd_fwd_beats;
        if (rd_accept && rd_allow) rd_fwd_next = rd_fwd_next + BEATCNT_W'(bcnt);
        if (rd_fwd_valid)          rd_fwd_next = rd_fwd_next - BEATCNT_W'(1);
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            rd_fwd_beats      <= '0;
            rd_deny_beats     <= '0;
            rd_deny_resp      <= RESP_OKAY;
            rd_stuck          <= 1'b0;
            rd_hold_addr      <= '0;
            rd_hold_burst     <= '0;
            rd_burst_addr     <= '0;
            rd_burst_cnt      <= '0;
            rd_flt_addr       <= 1'b0;
            rd_flt_perm       <= 1'b0;
            rd_flt_burst      <= 1'b0;
            rd_flt_to         <= 1'b0;
            rd_flt_type       <= FW_ALLOW;
            rd_flt_addr_val   <= '0;
            rd_flt_burstcount <= '0;
        end else begin
            rd_flt_addr  <= 1'b0;
            rd_flt_perm  <= 1'b0;
            rd_flt_burst <= 1'b0;
            rd_flt_to    <= 1'b0;

            if (s0_read && !rd_stuck) begin
                rd_burst_addr <= s0_address;
                rd_burst_cnt  <= bcnt;
            end

            // ---- beat accounting ----
            rd_fwd_beats <= rd_fwd_next;

            if (rd_deny_emit) rd_deny_beats <= rd_deny_beats - BEATCNT_W'(1);

            // A denied read is accepted immediately and the core owes the
            // master the full burst's worth of error beats. This is the part
            // that has no AXI4-Lite analogue: there is no way to say "no".
            if (rd_accept && !rd_allow) begin
                rd_deny_beats <= BEATCNT_W'(bcnt);
                rd_deny_resp  <= fw_resp(rd_dec);
            end

            if (rd_accept && !rd_allow && (rd_dec != FW_BLOCKED)) begin
                rd_flt_type       <= rd_dec;
                rd_flt_addr_val   <= s0_address;
                rd_flt_burstcount <= bcnt;
                case (rd_dec)
                    FW_ADDR: rd_flt_addr  <= 1'b1;
                    FW_PERM: rd_flt_perm  <= 1'b1;
                    default:  rd_flt_burst <= 1'b1;
                endcase
            end

            // ---- abandonment ----
            if (abandon) begin
                if (m0_read_i && m0_waitrequest) begin
                    rd_stuck      <= 1'b1;
                    rd_hold_addr  <= m0_address;
                    rd_hold_burst <= m0_burstcount;
                end
                // Beats the peripheral owes but will never deliver become
                // beats the core delivers itself, as SLAVEERROR. Without this
                // the master waits for readdatavalid forever, which is exactly
                // the hang the firewall exists to prevent.
                if (rd_fwd_next != '0) begin
                    rd_deny_beats <= rd_fwd_next;
                    rd_deny_resp  <= RESP_SLAVEERROR;
                end
                rd_fwd_beats <= '0;
            end

            if (rd_to_fire) begin
                rd_flt_to         <= 1'b1;
                rd_flt_type       <= FW_TIMEOUT;
                rd_flt_addr_val   <= rd_burst_addr;
                rd_flt_burstcount <= rd_burst_cnt;
            end

            if (rd_stuck && !m0_waitrequest) rd_stuck <= 1'b0;

            if (unblock) rd_stuck <= 1'b0;
        end
    end

endmodule
