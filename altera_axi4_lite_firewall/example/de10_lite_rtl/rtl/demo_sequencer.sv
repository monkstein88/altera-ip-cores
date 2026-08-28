`timescale 1ns/1ps

// =============================================================================
// demo_sequencer.sv
//
// The demo's "software". It plays the part a Nios II driver would: it programs
// the firewall's rule table over s_axi_ctrl, issues transactions at s_axi,
// injects peripheral faults, checks every response against what the core's
// register map says it should be, and reports pass/fail per scenario.
//
// WHY MICROCODE, AND NOT A STATE MACHINE
// --------------------------------------
// Sixteen scenarios of eight to twenty-five steps each is roughly two hundred
// states. Written as an FSM that is unreadable and unmaintainable; written as
// a program in a ROM it is a listing you can read top to bottom and diff
// against the register map. The engine below is ~120 lines; the program is the
// rest of the file and is the part worth reading.
//
// Scenarios are addressed by OP_MARK, not by a table of start addresses, so
// inserting a step never silently repoints another scenario's entry.
//
// EVERY SCENARIO IS SELF-CONTAINED. Before each one the engine runs a fixed
// hardware "heal" sequence (peripheral reset, sticky status cleared,
// RECOVERY.UNBLOCK, reset released) so the board's step mode can run them in
// any order, any number of times. Scenarios that need a broken downstream -
// A, b, C, d - break it themselves rather than depending on the previous one.
//
// A note on the heal order, because it is the same subtlety scenarios b and C
// exist to teach: UNBLOCK is issued while the peripheral is still held in
// reset, and the reset is released afterwards. See scenario C for what happens
// when you do it the other way round.
// =============================================================================

module demo_sequencer #(
    parameter int ADDR_WIDTH      = 32,
    parameter int DATA_WIDTH      = 32,
    parameter int CTRL_ADDR_WIDTH = 12,
    // Round-trip budget the firewall is programmed with, in clk cycles. The
    // peripheral answers a healthy access in ~4, so 200 is far outside the
    // noise while still being 4 us at 50 MHz - a fault is reported long before
    // a human could notice a pause.
    parameter int TIMEOUT_CYCLES  = 200,
    // Inter-scenario delay in auto-sweep mode = 2^PACE_BITS clk cycles.
    // 23 gives ~168 ms at 50 MHz, so a full sweep of 16 takes about 2.7 s.
    // The testbench overrides this to keep simulation short.
    parameter int PACE_BITS       = 23
) (
    input  logic                        clk,
    input  logic                        resetn,

    // ------------------------- operator controls --------------------------
    input  logic                        start,       // one-cycle pulse (KEY0)
    input  logic [3:0]                  select,      // scenario, step mode
    input  logic                        auto_mode,
    input  logic                        freeze,

    // ------------------------- display outputs ----------------------------
    output logic [3:0]                  cur_scenario,
    output logic                        running,
    // Increments once per completed scenario, and never decrements.
    //
    // `running` is a LEVEL, and a JTAG host cannot reliably see it: a probe
    // read takes tens of milliseconds while most scenarios finish in
    // microseconds, so the host asks "did it start?" and the answer is
    // already "it finished". A monotonic counter has no such window - the
    // host records it before the request and waits for it to MOVE.
    output logic [3:0]                  done_count,
    output logic                        result_valid,
    output logic                        result_pass,
    output logic [15:0]                 pass_bitmap,
    output logic [31:0]                 obs,
    output logic [31:0]                 status_shadow,

    // ------------------------- peripheral fault injection -----------------
    output logic                        periph_resetn,
    output logic                        periph_hang,
    output logic                        periph_hang_late,

    // ------------------------- downstream command watcher -----------------
    input  logic                        new_cmd_seen,
    output logic                        watch_clear,

    input  logic                        fw_irq,

    // ------------------------- AXI4-Lite: firewall control port -----------
    output logic [CTRL_ADDR_WIDTH-1:0]  c_awaddr,
    output logic [2:0]                  c_awprot,
    output logic                        c_awvalid,
    input  logic                        c_awready,
    output logic [31:0]                 c_wdata,
    output logic [3:0]                  c_wstrb,
    output logic                        c_wvalid,
    input  logic                        c_wready,
    input  logic [1:0]                  c_bresp,
    input  logic                        c_bvalid,
    output logic                        c_bready,
    output logic [CTRL_ADDR_WIDTH-1:0]  c_araddr,
    output logic [2:0]                  c_arprot,
    output logic                        c_arvalid,
    input  logic                        c_arready,
    input  logic [31:0]                 c_rdata,
    input  logic [1:0]                  c_rresp,
    input  logic                        c_rvalid,
    output logic                        c_rready,

    // ------------------------- AXI4-Lite: firewall data port --------------
    output logic [ADDR_WIDTH-1:0]       d_awaddr,
    output logic [2:0]                  d_awprot,
    output logic                        d_awvalid,
    input  logic                        d_awready,
    output logic [DATA_WIDTH-1:0]       d_wdata,
    output logic [DATA_WIDTH/8-1:0]     d_wstrb,
    output logic                        d_wvalid,
    input  logic                        d_wready,
    input  logic [1:0]                  d_bresp,
    input  logic                        d_bvalid,
    output logic                        d_bready,
    output logic [ADDR_WIDTH-1:0]       d_araddr,
    output logic [2:0]                  d_arprot,
    output logic                        d_arvalid,
    input  logic                        d_arready,
    input  logic [DATA_WIDTH-1:0]       d_rdata,
    input  logic [1:0]                  d_rresp,
    input  logic                        d_rvalid,
    output logic                        d_rready
);

    // =====================================================================
    // Firewall register map (see the core's README / user guide)
    // =====================================================================
    localparam logic [31:0] FW_CTRL       = 32'h0000_0000;
    localparam logic [31:0] FW_STATUS     = 32'h0000_0004;
    localparam logic [31:0] FW_IRQ_EN     = 32'h0000_0008;
    localparam logic [31:0] FW_TIMEOUT    = 32'h0000_000C;
    localparam logic [31:0] FW_FAULT_ADDR = 32'h0000_0010;
    localparam logic [31:0] FW_FAULT_INFO = 32'h0000_0014;
    localparam logic [31:0] FW_CORE_INFO  = 32'h0000_0018;
    localparam logic [31:0] FW_RECOVERY   = 32'h0000_001C;

    // Rule i lives at 0x40 + i*0x10, sub-offsets 0/4/8 = base/limit/perm.
    localparam logic [31:0] R0_BASE = 32'h40, R0_LIM = 32'h44, R0_PERM = 32'h48;
    localparam logic [31:0] R1_BASE = 32'h50, R1_LIM = 32'h54, R1_PERM = 32'h58;
    localparam logic [31:0] R2_BASE = 32'h60, R2_LIM = 32'h64, R2_PERM = 32'h68;

    // RULE_PERM bits: 0 = READ_ALLOW, 1 = WRITE_ALLOW, 2 = VALID
    localparam logic [31:0] PERM_RW = 32'h7;   // valid + write + read
    localparam logic [31:0] PERM_RO = 32'h5;   // valid + read
    localparam logic [31:0] PERM_WO = 32'h6;   // valid + write

    // STATUS bits
    localparam logic [31:0] ST_ADDR   = 32'h001;  // sticky, W1C
    localparam logic [31:0] ST_PERM   = 32'h002;  // sticky, W1C
    localparam logic [31:0] ST_TMO    = 32'h004;  // sticky, W1C
    localparam logic [31:0] ST_ISO    = 32'h008;  // live
    localparam logic [31:0] ST_BLK    = 32'h010;  // live
    localparam logic [31:0] ST_WRB    = 32'h020;  // live: peripheral owes a write response
    localparam logic [31:0] ST_RDB    = 32'h040;  // live: peripheral owes a read response
    localparam logic [31:0] ST_WRS    = 32'h080;  // live: AWVALID/WVALID never accepted
    localparam logic [31:0] ST_RDS    = 32'h100;  // live: ARVALID never accepted
    // Derived, not magic literals: this way every bit named above is
    // referenced, so a bit added to the map cannot be silently left out of
    // the exact-match checks the scenarios rely on.
    localparam logic [31:0] ST_STICKY = ST_ADDR | ST_PERM | ST_TMO;
    localparam logic [31:0] ST_ALL    = ST_ADDR | ST_PERM | ST_TMO | ST_ISO | ST_BLK |
                                        ST_WRB  | ST_RDB  | ST_WRS | ST_RDS;

    localparam logic [31:0] CTRL_SECURE = 32'h3;  // GLOBAL_ENABLE | AUTO_ISOLATE_EN
    localparam logic [31:0] CTRL_BYPASS = 32'h2;  // AUTO_ISOLATE_EN only

    // AXI response codes
    localparam logic [31:0] RSP_OKAY   = 32'd0;
    localparam logic [31:0] RSP_SLVERR = 32'd2;
    localparam logic [31:0] RSP_DECERR = 32'd3;

    // =====================================================================
    // The demo's address map, as seen at s_axi. Three 16-byte regions with
    // different permissions, and one address deliberately covered by no rule.
    // The peripheral itself answers all four - only the firewall says no.
    // =====================================================================
    localparam logic [31:0] AD_RW   = 32'h0000_1000;  // rule 0: read + write
    localparam logic [31:0] AD_RO   = 32'h0000_1010;  // rule 1: read only
    localparam logic [31:0] AD_WO   = 32'h0000_1020;  // rule 2: write only
    localparam logic [31:0] AD_NONE = 32'h0000_1030;  // no rule at all -> DECERR

    // Peripheral fault-injection control word: {periph_resetn, hang_late, hang}
    localparam logic [31:0] P_RUN   = 32'b100;  // healthy
    localparam logic [31:0] P_STARVE= 32'b101;  // never accept the command   -> *_CMD_STUCK
    localparam logic [31:0] P_SILENT= 32'b111;  // accept, then go silent     -> *_RESP_BUSY
    localparam logic [31:0] P_RESET = 32'b000;  // held in reset, hang cleared

    // =====================================================================
    // Instruction set
    // =====================================================================
    typedef enum logic [3:0] {
        OP_NOP,     // -
        OP_MARK,    // a0 = scenario index; scenario entry point
        OP_END,     // end of scenario; latch the pass flag
        OP_CW,      // a0 = ctrl offset, a1 = data     : write s_axi_ctrl
        OP_CR,      // a0 = ctrl offset                : read s_axi_ctrl  -> obs
        OP_DW,      // a0 = address,     a1 = data     : write s_axi      -> resp
        OP_DR,      // a0 = address                    : read s_axi       -> resp, obs
        OP_CHKM,    // a0 = mask, a1 = expected        : (obs & mask) == expected
        OP_CHKR,    // a0 = expected AXI response on the data path
        OP_CHKI,    // a0 = expected firewall irq level
        OP_CHKW,    // a0 = expected "new downstream command seen" flag
        OP_CLRW,    // arm the downstream command watcher
        OP_SET,     // a0 = peripheral fault-injection control word
        OP_WAIT     // a0 = clk cycles to idle
    } op_e;

    typedef struct packed {
        op_e         op;
        logic [31:0] a0;
        logic [31:0] a1;
    } instr_t;

    function automatic instr_t I(input op_e o, input logic [31:0] a0, input logic [31:0] a1);
        I.op = o;
        I.a0 = a0;
        I.a1 = a1;
    endfunction

    localparam int PROG_LEN = 200;

    // =====================================================================
    // THE PROGRAM
    //
    // Read this against the core's register map. Every OP_CHK* is a claim
    // about documented behaviour; if the core ever stops honouring one, the
    // corresponding hex digit on the board turns from P to F.
    // =====================================================================
    localparam instr_t PROG [PROG_LEN] = '{

        // -----------------------------------------------------------------
        // 0 - CFG : program the rule table and confirm which core we are on
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h0, 32'h0),
        I(OP_CW, R0_BASE, AD_RW),           // rule 0: 0x1000-0x100F, read+write
        I(OP_CW, R0_LIM,  AD_RW + 32'hF),
        I(OP_CW, R0_PERM, PERM_RW),
        I(OP_CW, R1_BASE, AD_RO),           // rule 1: 0x1010-0x101F, read only
        I(OP_CW, R1_LIM,  AD_RO + 32'hF),
        I(OP_CW, R1_PERM, PERM_RO),
        I(OP_CW, R2_BASE, AD_WO),           // rule 2: 0x1020-0x102F, write only
        I(OP_CW, R2_LIM,  AD_WO + 32'hF),
        I(OP_CW, R2_PERM, PERM_WO),
        I(OP_CW, FW_TIMEOUT, 32'(TIMEOUT_CYCLES)),
        I(OP_CW, FW_IRQ_EN,  32'h7),
        I(OP_CW, FW_CTRL,    CTRL_SECURE),
        I(OP_CW, FW_STATUS,  ST_STICKY),
        I(OP_CR, FW_CORE_INFO, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'h0200_0008),   // v2.0, NUM_RULES = 8
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 1 - W_OK : a permitted write is forwarded and reports OKAY
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h1, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_RW, 32'hA5A5_1234),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKI, 32'h0, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, 32'h0),                  // nothing set at all
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 2 - R_OK : and it reads back byte-for-byte
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h2, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_RW, 32'hA5A5_1234),             // self-contained: place the value
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_DR, AD_RW, 32'h0),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'hA5A5_1234),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 3 - RO_R : reading the read-only region is allowed
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h3, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DR, AD_RO, 32'h0),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, 32'h0),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 4 - RO_W : writing it is not. SLVERR, PERM_VIOLATION, irq, and the
        //            fault registers name the offending access.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h4, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_RO, 32'hDEAD_0000),
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKI, 32'h1, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_PERM),
        I(OP_CR, FW_FAULT_ADDR, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, AD_RO),
        I(OP_CR, FW_FAULT_INFO, 32'h0),
        I(OP_CHKM, 32'hF, 32'h5),                   // type=PERM(2)<<1 | was_write=1
        I(OP_CW, FW_STATUS, ST_STICKY),             // acknowledge -> irq drops
        I(OP_CHKI, 32'h0, 32'h0),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 5 - WO_W : writing the write-only region is allowed
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h5, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_WO, 32'h5555_AAAA),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, 32'h0),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 6 - WO_R : reading it is denied, and the denied read returns zeros
        //            rather than whatever the peripheral happens to hold.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h6, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_WO, 32'h5555_AAAA),             // put something recognisable there
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_DR, AD_WO, 32'h0),
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'h0),           // zeros, not 0x5555AAAA
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_PERM),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 7 - DEC_W : an address matching no rule is DECERR, not SLVERR.
        //             Default-deny - nothing had to be configured to forbid it.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h7, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_NONE, 32'h1234_5678),
        I(OP_CHKR, RSP_DECERR, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_ADDR),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 8 - DEC_R : same on the read side, and FAULT_INFO.WAS_WRITE says so
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h8, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DR, AD_NONE, 32'h0),
        I(OP_CHKR, RSP_DECERR, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_ADDR),
        I(OP_CR, FW_FAULT_ADDR, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, AD_NONE),
        I(OP_CR, FW_FAULT_INFO, 32'h0),
        I(OP_CHKM, 32'hF, 32'h2),                   // type=ADDR(1)<<1 | was_write=0
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 9 - TMO_W : the peripheral refuses the command outright. The master
        //             still gets an answer (SLVERR) instead of hanging, and
        //             the firewall latches TIMEOUT + ISOLATED + BLOCKED.
        //             WR_CMD_STUCK, not WR_RESP_BUSY: nobody took the command,
        //             so the firewall is holding an AWVALID that only
        //             RECOVERY.UNBLOCK can retract.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h9, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_STARVE, 32'h0),
        I(OP_DW, AD_RW, 32'hBAD0_BAD0),
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKI, 32'h1, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_TMO | ST_ISO | ST_BLK | ST_WRS),
        I(OP_CR, FW_FAULT_INFO, 32'h0),
        I(OP_CHKM, 32'hF, 32'h7),                   // type=TIMEOUT(3)<<1 | was_write=1
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // A - BLKD : while blocked, further traffic is REJECTED, not stalled,
        //            and nothing new reaches the peripheral. The watcher is
        //            the load-bearing check: it fails if any new AWVALID or
        //            ARVALID rises downstream. (The AWVALID left over from the
        //            timed-out write stays asserted, as AXI requires, so an
        //            edge detector is the right instrument here, not a level.)
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hA, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_STARVE, 32'h0),
        I(OP_DW, AD_RW, 32'hBAD0_BAD0),             // break the downstream first
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CLRW, 32'h0, 32'h0),
        I(OP_DW, AD_RW, 32'h1111_2222),
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKW, 32'h0, 32'h0),
        I(OP_DR, AD_RW, 32'h0),
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKW, 32'h0, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_BLK, ST_BLK),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // b - RCVR : the documented v2.0 recovery, done correctly.
        //
        //     Note the two claims this makes that no other scenario does:
        //       - acknowledging the fault (W1C) clears the sticky bits and
        //         releases ISOLATED but does NOT reopen the downstream;
        //       - the peripheral is held in reset ACROSS the UNBLOCK write,
        //         so the orphaned command is retracted while there is nothing
        //         downstream able to latch it. Compare scenario C.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hB, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_STARVE, 32'h0),
        I(OP_DW, AD_RW, 32'hCAFE_F00D),             // the command that will be orphaned
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_TMO | ST_ISO | ST_BLK | ST_WRS),
        I(OP_CW, FW_STATUS, ST_STICKY),             // step 2: acknowledge
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_TMO | ST_ISO | ST_BLK, ST_BLK),  // still blocked - W1C is not enough
        I(OP_SET, P_RESET, 32'h0),                  // step 4: reset the peripheral
        I(OP_WAIT, 32'd40, 32'h0),                  //         (>= 16 clocks)
        I(OP_CW, FW_RECOVERY, 32'h1),               // step 5: UNBLOCK, still in reset
        I(OP_SET, P_RUN, 32'h0),                    //         release afterwards
        I(OP_WAIT, 32'd16, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, 32'h0),                  // completely clean
        I(OP_CHKI, 32'h0, 32'h0),
        I(OP_DR, AD_RW, 32'h0),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'h0),           // fresh peripheral, no stale write
        I(OP_DW, AD_RW, 32'h600D_600D),             // step 6: traffic resumes
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_DR, AD_RW, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'h600D_600D),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // C - STALE : the same recovery with steps 4 and 5 the wrong way
        //     round - reset released BEFORE UNBLOCK. The orphaned AWVALID is
        //     still asserted, so the freshly-reset peripheral accepts it and
        //     commits a write the master was already told had FAILED.
        //
        //     This scenario passing means the hazard reproduced, on hardware,
        //     exactly as verification/orphan_response_tb.sv measures it. It is
        //     the one scenario where P means "the bad thing happened".
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hC, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_STARVE, 32'h0),
        I(OP_DW, AD_RW, 32'hCAFE_F00D),
        I(OP_CHKR, RSP_SLVERR, 32'h0),              // the master was told: failed
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_RESET, 32'h0),
        I(OP_WAIT, 32'd40, 32'h0),
        I(OP_SET, P_RUN, 32'h0),                    // <-- released too early
        I(OP_WAIT, 32'd16, 32'h0),                  //     and here it lands
        I(OP_CW, FW_RECOVERY, 32'h1),
        I(OP_DR, AD_RW, 32'h0),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'hCAFE_F00D),   // the failed write is in memory
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // d - TMO_R : the other failure shape - the peripheral ACCEPTS a read
        //     and then goes silent. Same SLVERR upstream, same TIMEOUT, but
        //     RD_RESP_BUSY instead of RD_CMD_STUCK. That distinction is what a
        //     driver uses to decide whether polling can ever succeed: here the
        //     peripheral owes a response forever, which is why the core's
        //     recovery sequence says to bound the poll.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hD, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_SILENT, 32'h0),
        I(OP_DR, AD_RW, 32'h0),
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'h0),           // timed-out read yields zeros
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_TMO | ST_ISO | ST_BLK | ST_RDB),
        I(OP_CR, FW_FAULT_INFO, 32'h0),
        I(OP_CHKM, 32'hF, 32'h6),                   // type=TIMEOUT(3)<<1 | was_write=0
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // E - BYP : clearing CTRL.GLOBAL_ENABLE forwards everything unchecked.
        //     Shown before, during and after, on the same address, so the
        //     bypass is visibly the only thing that changed.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hE, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_NONE, 32'h0BAD_0BAD),
        I(OP_CHKR, RSP_DECERR, 32'h0),              // denied while enforcing
        I(OP_CW, FW_CTRL, CTRL_BYPASS),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_NONE, 32'h0BAD_0BAD),
        I(OP_CHKR, RSP_OKAY, 32'h0),                // forwarded while bypassed
        I(OP_DR, AD_NONE, 32'h0),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'h0BAD_0BAD),   // it really reached the peripheral
        I(OP_CW, FW_CTRL, CTRL_SECURE),
        I(OP_DW, AD_NONE, 32'h0000_0000),
        I(OP_CHKR, RSP_DECERR, 32'h0),              // denied again
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // F - MASK : IRQ_ENABLE gates the interrupt only. STATUS still records
        //     the violation, and unmasking re-raises irq for a fault that is
        //     still pending - the interrupt is a level, not an edge.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hF, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_CW, FW_IRQ_EN, 32'h0),
        I(OP_DW, AD_RO, 32'hDEAD_0000),
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKI, 32'h0, 32'h0),                   // masked: no interrupt
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_PERM),                // but the fault is recorded
        I(OP_CW, FW_IRQ_EN, 32'h7),
        I(OP_CHKI, 32'h1, 32'h0),                   // unmasking raises it now
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_CHKI, 32'h0, 32'h0),
        I(OP_END, 32'h0, 32'h0)
    };

    // =====================================================================
    // Two AXI4-Lite masters: one on the control port, one on the data path
    // =====================================================================
    logic                       ctl_req, ctl_write, ctl_busy, ctl_done, ctl_done_write;
    logic [CTRL_ADDR_WIDTH-1:0] ctl_addr;
    logic [31:0]                ctl_wdata, ctl_rdata;
    logic [1:0]                 ctl_resp;

    logic                       dat_req, dat_write, dat_busy, dat_done, dat_done_write;
    logic [ADDR_WIDTH-1:0]      dat_addr;
    logic [DATA_WIDTH-1:0]      dat_wdata, dat_rdata;
    logic [1:0]                 dat_resp;

    demo_axi_lite_master #(
        .ADDR_WIDTH (CTRL_ADDR_WIDTH),
        .DATA_WIDTH (32)
    ) u_ctl (
        .clk(clk), .resetn(resetn),
        .req(ctl_req), .req_write(ctl_write), .req_addr(ctl_addr), .req_wdata(ctl_wdata),
        .busy(ctl_busy), .done(ctl_done), .done_write(ctl_done_write),
        .rdata(ctl_rdata), .resp(ctl_resp),
        .m_awaddr(c_awaddr), .m_awprot(c_awprot), .m_awvalid(c_awvalid), .m_awready(c_awready),
        .m_wdata(c_wdata), .m_wstrb(c_wstrb), .m_wvalid(c_wvalid), .m_wready(c_wready),
        .m_bresp(c_bresp), .m_bvalid(c_bvalid), .m_bready(c_bready),
        .m_araddr(c_araddr), .m_arprot(c_arprot), .m_arvalid(c_arvalid), .m_arready(c_arready),
        .m_rdata(c_rdata), .m_rresp(c_rresp), .m_rvalid(c_rvalid), .m_rready(c_rready)
    );

    demo_axi_lite_master #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_dat (
        .clk(clk), .resetn(resetn),
        .req(dat_req), .req_write(dat_write), .req_addr(dat_addr), .req_wdata(dat_wdata),
        .busy(dat_busy), .done(dat_done), .done_write(dat_done_write),
        .rdata(dat_rdata), .resp(dat_resp),
        .m_awaddr(d_awaddr), .m_awprot(d_awprot), .m_awvalid(d_awvalid), .m_awready(d_awready),
        .m_wdata(d_wdata), .m_wstrb(d_wstrb), .m_wvalid(d_wvalid), .m_wready(d_wready),
        .m_bresp(d_bresp), .m_bvalid(d_bvalid), .m_bready(d_bready),
        .m_araddr(d_araddr), .m_arprot(d_arprot), .m_arvalid(d_arvalid), .m_arready(d_arready),
        .m_rdata(d_rdata), .m_rresp(d_rresp), .m_rvalid(d_rvalid), .m_rready(d_rready)
    );

    // =====================================================================
    // Engine
    // =====================================================================
    typedef enum logic [2:0] {
        E_HEAL,     // put the system back in a known-good state
        E_SCAN,     // find this scenario's OP_MARK
        E_EXEC,     // execute
        E_DELAY,    // OP_WAIT
        E_FINISH,   // latch the result
        E_PACE,     // inter-scenario delay, auto mode
        E_IDLE      // waiting for the operator
    } eng_state_e;

    eng_state_e  state;
    logic [3:0]  scen;
    logic [8:0]  pc;            // 8 bits addresses the program, 9th is headroom
                                //  so the bounds compare below cannot wrap
    logic [2:0]  heal_step;
    logic [15:0] wait_cnt;
    logic [PACE_BITS-1:0] pace_cnt;
    logic        pass_acc;
    logic [1:0]  last_resp;
    logic [2:0]  periph_ctl;
    logic [CTRL_ADDR_WIDTH-1:0] ctl_addr_issued;
    logic        ctl_is_poll;      // the outstanding ctl read is a background poll

    instr_t instr;
    always_comb instr = (pc < 9'(PROG_LEN)) ? PROG[pc[7:0]] : I(OP_NOP, 32'h0, 32'h0);

    assign periph_resetn    = periph_ctl[2];
    assign periph_hang_late = periph_ctl[1];
    assign periph_hang      = periph_ctl[0];
    assign cur_scenario     = scen;
    // E_PACE is deliberately not "running": in auto mode the pause between
    // scenarios is when a human actually reads HEX4, so the P/F of the
    // scenario that just finished has to be showing then, not a busy dash.
    assign running          = (state != E_IDLE) && (state != E_PACE);

    always_ff @(posedge clk) begin
        if (!resetn) begin
            // Start by configuring the firewall, so that in step mode a
            // scenario selected straight after power-on finds a programmed
            // rule table rather than default-deny everywhere.
            state           <= E_HEAL;
            heal_step       <= '0;
            scen            <= 4'h0;
            pc              <= '0;
            wait_cnt        <= '0;
            pace_cnt        <= '0;
            pass_acc        <= 1'b1;
            pass_bitmap     <= '0;
            result_valid    <= 1'b0;
            done_count      <= 4'd0;
            result_pass     <= 1'b0;
            obs             <= '0;
            status_shadow   <= '0;
            last_resp       <= 2'b00;
            periph_ctl      <= P_RUN[2:0];
            watch_clear     <= 1'b0;
            ctl_req         <= 1'b0;
            ctl_write       <= 1'b0;
            ctl_addr        <= '0;
            ctl_wdata       <= '0;
            ctl_addr_issued <= '0;
            ctl_is_poll     <= 1'b0;
            dat_req         <= 1'b0;
            dat_write       <= 1'b0;
            dat_addr        <= '0;
            dat_wdata       <= '0;
        end else begin
            ctl_req     <= 1'b0;
            dat_req     <= 1'b0;
            watch_clear <= 1'b0;

            // ---- transaction results -------------------------------------
            // last_resp is data-path only, on purpose: OP_CHKR is always a
            // claim about what the protected path answered, and control
            // traffic (which always returns OKAY) must not overwrite it.
            // A polled read refreshes the LEDs but must NOT touch `obs`.
            // `obs` is what the operator sees on HEX3..0 with SW[6]=1, and it
            // has to stay showing whatever the scenario last looked at - the
            // poll runs continuously once a scenario ends, so without this it
            // would overwrite the result within microseconds of it appearing.
            if (ctl_done && !ctl_done_write) begin
                if (!ctl_is_poll) obs <= ctl_rdata;
                if (ctl_addr_issued == FW_STATUS[CTRL_ADDR_WIDTH-1:0])
                    status_shadow <= ctl_rdata;
            end
            if (dat_done) begin
                last_resp <= dat_resp;
                if (!dat_done_write) obs <= dat_rdata;
            end

            // The control port is not subject to firewall rules and cannot be
            // blocked by an isolated downstream - that separation is the
            // reason it exists - so it must answer OKAY unconditionally. No
            // scenario asserts this explicitly, so assert it everywhere: any
            // other response fails whatever scenario is running.
            if (ctl_done && ctl_resp != 2'b00) pass_acc <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                // Return to a known-good state. Same order as the documented
                // recovery: acknowledge, then UNBLOCK with the peripheral
                // held in reset, then release it.
                // ---------------------------------------------------------
                E_HEAL: begin
                    if (!ctl_busy && !dat_busy) begin
                        case (heal_step)
                            3'd0: begin
                                periph_ctl <= P_RESET[2:0];
                                wait_cnt   <= 16'd40;
                                heal_step  <= 3'd1;
                            end
                            3'd1: if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                                  else              heal_step <= 3'd2;
                            3'd2: begin
                                ctl_req         <= 1'b1;
                                ctl_write       <= 1'b1;
                                ctl_addr        <= FW_STATUS[CTRL_ADDR_WIDTH-1:0];
                                ctl_addr_issued <= FW_STATUS[CTRL_ADDR_WIDTH-1:0];
                                ctl_wdata       <= ST_STICKY;
                                ctl_is_poll     <= 1'b0;
                                heal_step       <= 3'd3;
                            end
                            3'd3: begin
                                ctl_req         <= 1'b1;
                                ctl_write       <= 1'b1;
                                ctl_addr        <= FW_RECOVERY[CTRL_ADDR_WIDTH-1:0];
                                ctl_addr_issued <= FW_RECOVERY[CTRL_ADDR_WIDTH-1:0];
                                ctl_wdata       <= 32'h1;
                                heal_step       <= 3'd4;
                            end
                            3'd4: begin
                                periph_ctl  <= P_RUN[2:0];
                                watch_clear <= 1'b1;
                                heal_step   <= 3'd5;
                            end
                            default: begin
                                heal_step <= 3'd0;
                                pc        <= '0;
                                state     <= E_SCAN;
                            end
                        endcase
                    end
                end

                // ---------------------------------------------------------
                // Scenarios are found by scanning for their OP_MARK, so the
                // program can be edited without maintaining an entry table.
                // ---------------------------------------------------------
                E_SCAN: begin
                    if (instr.op == OP_MARK && instr.a0[3:0] == scen) begin
                        pass_acc <= 1'b1;
                        pc       <= pc + 1'b1;
                        state    <= E_EXEC;
                    end else if (pc >= 9'(PROG_LEN - 1)) begin
                        state <= E_IDLE;      // no such scenario; fail safe
                    end else begin
                        pc <= pc + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // One instruction per cycle, whenever no transaction is
                // outstanding. A failed check does not abort the scenario:
                // it clears pass_acc and lets the rest run, so the board ends
                // up showing the state the failure left behind.
                // ---------------------------------------------------------
                E_EXEC: begin
                    if (!ctl_busy && !dat_busy) begin
                        pc <= pc + 1'b1;
                        case (instr.op)
                            OP_CW: begin
                                ctl_req         <= 1'b1;
                                ctl_write       <= 1'b1;
                                ctl_addr        <= instr.a0[CTRL_ADDR_WIDTH-1:0];
                                ctl_addr_issued <= instr.a0[CTRL_ADDR_WIDTH-1:0];
                                ctl_wdata       <= instr.a1;
                                ctl_is_poll     <= 1'b0;
                            end
                            OP_CR: begin
                                ctl_req         <= 1'b1;
                                ctl_write       <= 1'b0;
                                ctl_addr        <= instr.a0[CTRL_ADDR_WIDTH-1:0];
                                ctl_addr_issued <= instr.a0[CTRL_ADDR_WIDTH-1:0];
                                ctl_is_poll     <= 1'b0;
                            end
                            OP_DW: begin
                                dat_req   <= 1'b1;
                                dat_write <= 1'b1;
                                dat_addr  <= instr.a0[ADDR_WIDTH-1:0];
                                dat_wdata <= instr.a1[DATA_WIDTH-1:0];
                            end
                            OP_DR: begin
                                dat_req   <= 1'b1;
                                dat_write <= 1'b0;
                                dat_addr  <= instr.a0[ADDR_WIDTH-1:0];
                            end
                            OP_CHKM: if ((obs & instr.a0) != instr.a1)   pass_acc <= 1'b0;
                            OP_CHKR: if (last_resp    != instr.a0[1:0])  pass_acc <= 1'b0;
                            OP_CHKI: if (fw_irq       != instr.a0[0])    pass_acc <= 1'b0;
                            OP_CHKW: if (new_cmd_seen != instr.a0[0])    pass_acc <= 1'b0;
                            OP_CLRW: watch_clear <= 1'b1;
                            OP_SET:  periph_ctl  <= instr.a0[2:0];
                            OP_WAIT: begin
                                wait_cnt <= instr.a0[15:0];
                                state    <= E_DELAY;
                            end
                            OP_END: state <= E_FINISH;
                            default: ;      // OP_NOP, OP_MARK
                        endcase
                    end
                end

                E_DELAY: if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                         else               state    <= E_EXEC;

                E_FINISH: begin
                    pass_bitmap[scen] <= pass_acc;
                    result_pass       <= pass_acc;
                    result_valid      <= 1'b1;
                    done_count        <= done_count + 4'd1;
                    if (auto_mode) begin
                        pace_cnt <= '1;
                        state    <= E_PACE;
                    end else begin
                        state <= E_IDLE;
                    end
                end

                E_PACE: begin
                    if (!auto_mode) begin
                        state <= E_IDLE;
                    end else if (pace_cnt != 0) begin
                        pace_cnt <= pace_cnt - 1'b1;
                    end else if (!freeze) begin
                        scen      <= scen + 1'b1;
                        heal_step <= 3'd0;
                        state     <= E_HEAL;
                    end
                end

                default: begin      // E_IDLE
                    // Raising the auto-sweep switch starts a fresh sweep from
                    // scenario 0 with a cleared bitmap. Step mode accumulates
                    // instead, so you can walk scenarios one at a time and
                    // watch the bitmap fill in.
                    if (auto_mode) begin
                        scen        <= 4'h0;
                        pass_bitmap <= '0;
                        heal_step   <= 3'd0;
                        state       <= E_HEAL;
                    end else if (start) begin
                        scen      <= select;
                        heal_step <= 3'd0;
                        state     <= E_HEAL;
                    end
                end
            endcase

            // ---- background STATUS polling -------------------------------
            // Nothing else uses the control master while idle or pacing, so
            // this needs no arbitration. It is what keeps LEDR showing the
            // firewall's live state rather than a stale snapshot.
            if ((state == E_IDLE || state == E_PACE) && !ctl_busy && !dat_busy) begin
                ctl_req         <= 1'b1;
                ctl_write       <= 1'b0;
                ctl_addr        <= FW_STATUS[CTRL_ADDR_WIDTH-1:0];
                ctl_addr_issued <= FW_STATUS[CTRL_ADDR_WIDTH-1:0];
                ctl_is_poll     <= 1'b1;
            end
        end
    end

    // ==================================================================
    // Failing-check trace, simulation only.
    //
    // On the board a failed scenario is one letter: F. That is the right
    // amount of information for a demo and the wrong amount for debugging
    // one, so compile the simulation with +define+DEMO_TRACE to have every
    // failing check name itself, with the program counter, what was
    // observed and what was expected.
    //
    // Guarded so it cannot reach synthesis: Quartus never sees a $display.
    // ==================================================================
`ifdef DEMO_TRACE
    always_ff @(posedge clk) begin
        if (resetn && state == E_EXEC && !ctl_busy && !dat_busy) begin
            case (instr.op)
                OP_CHKM: if ((obs & instr.a0) != instr.a1)
                    $display("[%0t] scen %0X pc %0d  CHKM FAIL  obs=%08h & %08h = %08h, expected %08h",
                             $time, scen, pc, obs, instr.a0, obs & instr.a0, instr.a1);
                OP_CHKR: if (last_resp != instr.a0[1:0])
                    $display("[%0t] scen %0X pc %0d  CHKR FAIL  resp=%0d, expected %0d",
                             $time, scen, pc, last_resp, instr.a0[1:0]);
                OP_CHKI: if (fw_irq != instr.a0[0])
                    $display("[%0t] scen %0X pc %0d  CHKI FAIL  irq=%0b, expected %0b",
                             $time, scen, pc, fw_irq, instr.a0[0]);
                OP_CHKW: if (new_cmd_seen != instr.a0[0])
                    $display("[%0t] scen %0X pc %0d  CHKW FAIL  new_cmd_seen=%0b, expected %0b",
                             $time, scen, pc, new_cmd_seen, instr.a0[0]);
                default: ;
            endcase
        end
    end
`endif

endmodule
