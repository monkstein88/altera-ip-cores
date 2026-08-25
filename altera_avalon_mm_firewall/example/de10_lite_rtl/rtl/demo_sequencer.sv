`timescale 1ns/1ps

// =============================================================================
// demo_sequencer.sv
//
// The demo's "software". It plays the part a Nios II driver would: it programs
// the firewall's rule table over `csr`, issues transactions at `s0`, injects
// peripheral faults, checks every response against what the core's register
// map says it should be, and reports pass/fail per scenario.
//
// WHY MICROCODE, AND NOT A STATE MACHINE
// --------------------------------------
// Sixteen scenarios of eight to thirty steps each is several hundred states.
// Written as an FSM that is unreadable and unmaintainable; written as a
// program in a ROM it is a listing you can read top to bottom and diff against
// the register map. The engine below is ~150 lines; the program is the rest of
// the file and is the part worth reading.
//
// Scenarios are addressed by OP_MARK, not by a table of start addresses, so
// inserting a step never silently repoints another scenario's entry.
//
// EVERY SCENARIO IS SELF-CONTAINED. Before each one the engine runs a fixed
// hardware "heal" sequence (peripheral reset, sticky status cleared,
// RECOVERY.UNBLOCK, reset released) so the board's step mode can run them in
// any order, any number of times. Scenarios that need a broken downstream
// break it themselves rather than depending on the previous one.
//
// A note on the heal order, because it is the same subtlety scenarios E and F
// exist to teach: UNBLOCK is issued while the peripheral is still held in
// reset, and the reset is released afterwards. See scenario F for what happens
// when you do it the other way round.
//
// WHAT IS DIFFERENT FROM THE AXI4-LITE SIBLING'S DEMO
// ---------------------------------------------------
// That demo drove single transactions, because AXI4-Lite has no other kind.
// This core exists for bursts, so five of the sixteen scenarios here are about
// burst behaviour that has no AXI4-Lite analogue at all: a burst that runs off
// the end of its window, two abutting permitted windows that deliberately do
// not merge, a window that permits single accesses but refuses bursts, and the
// one-beat-per-cycle throughput claim measured on real silicon.
// =============================================================================

module demo_sequencer #(
    parameter int ADDR_WIDTH      = 32,
    parameter int DATA_WIDTH      = 32,
    parameter int BURST_WIDTH     = 8,
    parameter int CSR_ADDR_WIDTH  = 8,    // in WORDS, as the core's csr port is
    // Progress budget the firewall is programmed with, in clk cycles. The
    // peripheral answers a healthy access in 1-2, so 200 is far outside the
    // noise while still being 4 us at 50 MHz - a fault is reported long before
    // a human could notice a pause.
    parameter int TIMEOUT_CYCLES  = 200,
    // Guard for the burst-throughput scenario: cycles from request to last
    // beat of a BURST_BEATS-beat read. See scenario 5.
    parameter int THRU_GUARD      = 24,
    parameter int BURST_BEATS     = 16,
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

    // ------------------------- firewall csr port (word-addressed) ---------
    output logic [CSR_ADDR_WIDTH-1:0]   c_address,
    output logic                        c_read,
    output logic                        c_write,
    output logic [31:0]                 c_writedata,
    output logic [3:0]                  c_byteenable,
    input  logic [31:0]                 c_readdata,

    // ------------------------- firewall s0 data port ----------------------
    output logic [ADDR_WIDTH-1:0]       d_address,
    output logic                        d_read,
    output logic                        d_write,
    output logic [DATA_WIDTH-1:0]       d_writedata,
    output logic [DATA_WIDTH/8-1:0]     d_byteenable,
    output logic [BURST_WIDTH-1:0]      d_burstcount,
    input  logic                        d_waitrequest,
    input  logic [DATA_WIDTH-1:0]       d_readdata,
    input  logic                        d_readdatavalid,
    input  logic [1:0]                  d_response,
    input  logic                        d_writeresponsevalid
);

    // =====================================================================
    // Firewall register map, in BYTE offsets - the same numbers the user
    // guide quotes and software uses. The csr port is word-addressed in
    // hardware, so the bottom two bits are dropped where the master is wired
    // up; see `c_address` below.
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
    localparam logic [31:0] R3_BASE = 32'h70, R3_LIM = 32'h74, R3_PERM = 32'h78;
    localparam logic [31:0] R4_BASE = 32'h80, R4_LIM = 32'h84, R4_PERM = 32'h88;

    // RULE_PERM bits: 0 = READ_ALLOW, 1 = WRITE_ALLOW, 2 = VALID, 3 = BURST_ALLOW
    localparam logic [31:0] PERM_RWB = 32'hF;   // burst + valid + write + read
    localparam logic [31:0] PERM_ROB = 32'hD;   // burst + valid + read
    localparam logic [31:0] PERM_WOB = 32'hE;   // burst + valid + write
    localparam logic [31:0] PERM_RW  = 32'h7;   // valid + write + read, NO bursts

    // STATUS bits
    localparam logic [31:0] ST_ADDR  = 32'h001;  // sticky, W1C
    localparam logic [31:0] ST_PERM  = 32'h002;  // sticky, W1C
    localparam logic [31:0] ST_TMO   = 32'h004;  // sticky, W1C
    localparam logic [31:0] ST_BURST = 32'h008;  // sticky, W1C
    localparam logic [31:0] ST_ISO   = 32'h010;  // live
    localparam logic [31:0] ST_BLK   = 32'h020;  // live
    localparam logic [31:0] ST_WRB   = 32'h040;  // live: peripheral owes a write completion
    localparam logic [31:0] ST_RDB   = 32'h080;  // live: peripheral owes read beats
    localparam logic [31:0] ST_WRS   = 32'h100;  // live: m0_write never accepted
    localparam logic [31:0] ST_RDS   = 32'h200;  // live: m0_read never accepted
    // Derived, not magic literals: this way every bit named above is
    // referenced, so a bit added to the map cannot be silently left out of
    // the exact-match checks the scenarios rely on.
    localparam logic [31:0] ST_STICKY = ST_ADDR | ST_PERM | ST_TMO | ST_BURST;
    localparam logic [31:0] ST_ALL    = ST_STICKY | ST_ISO | ST_BLK |
                                        ST_WRB | ST_RDB | ST_WRS | ST_RDS;

    localparam logic [31:0] CTRL_SECURE = 32'h3;  // GLOBAL_ENABLE | AUTO_ISOLATE_EN

    // Avalon-MM response codes
    localparam logic [31:0] RSP_OKAY   = 32'd0;
    localparam logic [31:0] RSP_SLVERR = 32'd2;
    localparam logic [31:0] RSP_DECERR = 32'd3;

    // FAULT_INFO.TYPE values (avl_mm_firewall_pkg::fw_code_e)
    localparam logic [31:0] FT_ADDR     = 32'd1;
    localparam logic [31:0] FT_PERM     = 32'd2;
    localparam logic [31:0] FT_TIMEOUT  = 32'd3;
    localparam logic [31:0] FT_BRANGE   = 32'd4;
    localparam logic [31:0] FT_BDENIED  = 32'd5;

    // =====================================================================
    // The demo's address map, as seen at s0. Five windows and one address
    // deliberately covered by no rule. The peripheral itself answers all of
    // them - only the firewall ever says no.
    //
    // Rules 0 and 1 ABUT on purpose, and both permit read, write and bursts.
    // A burst that crosses the boundary is still refused, because permissions
    // are per-window and a crossing burst would have to satisfy both. That is
    // scenario 9, and it is the case a start-address-only firewall gets wrong.
    // =====================================================================
    localparam logic [31:0] AD_RW0  = 32'h0000_0000;  // rule 0: 0x00-0x3F  RW + burst
    localparam logic [31:0] AD_RW1  = 32'h0000_0040;  // rule 1: 0x40-0x7F  RW + burst
    localparam logic [31:0] AD_RO   = 32'h0000_0080;  // rule 2: 0x80-0xAF  read only
    localparam logic [31:0] AD_WO   = 32'h0000_00B0;  // rule 3: 0xB0-0xDF  write only
    localparam logic [31:0] AD_NB   = 32'h0000_00E0;  // rule 4: 0xE0-0xEF  RW, no bursts
    localparam logic [31:0] AD_NONE = 32'h0000_00F0;  // no rule at all -> DECODEERROR

    // A burst that starts inside rule 0 and ends inside rule 1.
    localparam logic [31:0] AD_STRAD = 32'h0000_0030;

    // Peripheral fault-injection control word: {periph_resetn, hang_late, hang}
    localparam logic [31:0] P_RUN    = 32'b100;  // healthy
    localparam logic [31:0] P_STARVE = 32'b101;  // waitrequest stuck   -> *_CMD_STUCK
    localparam logic [31:0] P_SILENT = 32'b111;  // accept, then silent -> *_BUSY
    localparam logic [31:0] P_RESET  = 32'b000;  // held in reset, hang cleared

    // =====================================================================
    // Instruction set
    // =====================================================================
    typedef enum logic [4:0] {
        OP_NOP,     // -
        OP_MARK,    // a0 = scenario index; scenario entry point
        OP_END,     // end of scenario; latch the pass flag
        OP_CW,      // a0 = csr byte offset, a1 = data : write csr
        OP_CR,      // a0 = csr byte offset            : read csr  -> obs
        OP_DW,      // a0 = address, a1 = data seed, bc = beats : write s0
        OP_DR,      // a0 = address,                 bc = beats : read s0
        OP_CHKM,    // a0 = mask, a1 = expected        : (obs & mask) == expected
        OP_CHKR,    // a0 = expected response on the data path
        OP_CHKI,    // a0 = expected firewall irq level
        OP_CHKW,    // a0 = expected "new downstream command seen" flag
        OP_CHKB,    // a0 = expected beat count from the last data transaction
        OP_CHKD,    // a0 = expected data_ok flag (read burst matched the ramp)
        OP_CHKC,    // a0 = cycle budget: the last transaction took <= a0
        OP_CHKS,    // a0 = expected master-watchdog "stuck" flag
        OP_CLRW,    // arm the downstream command watcher
        OP_SET,     // a0 = peripheral fault-injection control word
        OP_WAIT     // a0 = clk cycles to idle
    } op_e;

    typedef struct packed {
        op_e         op;
        logic [7:0]  bc;    // burstcount for OP_DW / OP_DR
        logic [31:0] a0;
        logic [31:0] a1;
    } instr_t;

    // Single-beat instruction.
    function automatic instr_t I(input op_e o, input logic [31:0] a0, input logic [31:0] a1);
        I.op = o;
        I.bc = 8'd1;
        I.a0 = a0;
        I.a1 = a1;
    endfunction

    // Burst instruction.
    function automatic instr_t B(input op_e o, input logic [7:0] bc,
                                 input logic [31:0] a0, input logic [31:0] a1);
        B.op = o;
        B.bc = bc;
        B.a0 = a0;
        B.a1 = a1;
    endfunction

    localparam int PROG_LEN = 232;
    localparam logic [7:0] NB = 8'(BURST_BEATS);

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
        I(OP_CW, R0_BASE, AD_RW0),               // rule 0: 0x00-0x3F  RW + burst
        I(OP_CW, R0_LIM,  AD_RW0 + 32'h3F),
        I(OP_CW, R0_PERM, PERM_RWB),
        I(OP_CW, R1_BASE, AD_RW1),               // rule 1: 0x40-0x7F  RW + burst
        I(OP_CW, R1_LIM,  AD_RW1 + 32'h3F),
        I(OP_CW, R1_PERM, PERM_RWB),
        I(OP_CW, R2_BASE, AD_RO),                // rule 2: 0x80-0xAF  read only
        I(OP_CW, R2_LIM,  AD_RO + 32'h2F),
        I(OP_CW, R2_PERM, PERM_ROB),
        I(OP_CW, R3_BASE, AD_WO),                // rule 3: 0xB0-0xDF  write only
        I(OP_CW, R3_LIM,  AD_WO + 32'h2F),
        I(OP_CW, R3_PERM, PERM_WOB),
        I(OP_CW, R4_BASE, AD_NB),                // rule 4: 0xE0-0xEF  RW, no bursts
        I(OP_CW, R4_LIM,  AD_NB + 32'hF),
        I(OP_CW, R4_PERM, PERM_RW),
        I(OP_CW, FW_TIMEOUT, 32'(TIMEOUT_CYCLES)),
        I(OP_CW, FW_IRQ_EN,  32'hF),
        I(OP_CW, FW_CTRL,    CTRL_SECURE),
        I(OP_CW, FW_STATUS,  ST_STICKY),
        I(OP_CR, FW_CORE_INFO, 32'h0),
        // [31:16] version 0x0100, [15:13] log2 bytes/beat = 2, [12:8] BURST_WIDTH = 8,
        // [7:0] NUM_RULES = 5  ->  0x0100_4805
        I(OP_CHKM, 32'hFFFF_FFFF, 32'h0100_4805),
        I(OP_CHKS, 32'h0, 32'h0),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 1 - W_OK : a permitted single write is forwarded and reports OKAY
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h1, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_RW0, 32'hA5A5_1234),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKB, 32'd1, 32'h0),
        I(OP_CHKI, 32'h0, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, 32'h0),               // nothing set at all
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 2 - R_OK : and it reads back byte-for-byte
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h2, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_RW0, 32'hA5A5_1234),         // self-contained: place the value
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_DR, AD_RW0, 32'h0),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'hA5A5_1234),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 3 - BW_OK : a permitted BURST write. Every beat is accepted and the
        //             burst reports OKAY. Rule 0 spans 0x00-0x3F, which is
        //             exactly BURST_BEATS 32-bit words, so this burst fills
        //             the window and does not cross into rule 1.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h3, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        B(OP_DW, NB, AD_RW0, 32'h1000_0000),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKB, 32'(BURST_BEATS), 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, 32'h0),
        I(OP_CHKS, 32'h0, 32'h0),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 4 - BR_OK : and the burst reads back, beat for beat, in order.
        //             data_ok is the whole ramp compared against what was
        //             written in this scenario - so this is a data-integrity
        //             claim about the pass-through, not just a beat count.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h4, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        B(OP_DW, NB, AD_RW0, 32'h2200_0000),     // self-contained: fill it first
        I(OP_CHKR, RSP_OKAY, 32'h0),
        B(OP_DR, NB, AD_RW0, 32'h2200_0000),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKB, 32'(BURST_BEATS), 32'h0),
        I(OP_CHKD, 32'h1, 32'h0),                // every beat matched the ramp
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, 32'h0),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 5 - THRU : the core's headline claim, measured on silicon.
        //
        // The firewall is a gate, not a buffer: an allowed burst is s0 wired
        // to m0 through the rule lookup, with no storage and no added cycles.
        // A BURST_BEATS-beat read against this zero-wait-state peripheral
        // should therefore cost one cycle per beat plus the peripheral's own
        // read latency, and nothing else. THRU_GUARD is the budget; exceeding
        // it means the core has started inserting bubbles.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h5, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        B(OP_DW, NB, AD_RW0, 32'h3300_0000),
        B(OP_DR, NB, AD_RW0, 32'h3300_0000),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKB, 32'(BURST_BEATS), 32'h0),
        I(OP_CHKD, 32'h1, 32'h0),
        I(OP_CHKC, 32'(THRU_GUARD), 32'h0),      // <- the throughput guard
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 6 - RO_W : writing the read-only window is refused. SLAVEERROR,
        //            PERM_VIOLATION, irq, and the fault registers name the
        //            offending access.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h6, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_RO, 32'hDEAD_0000),
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKI, 32'h1, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_PERM),
        I(OP_CR, FW_FAULT_ADDR, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, AD_RO),
        I(OP_CR, FW_FAULT_INFO, 32'h0),
        // [0] was_write = 1, [3:1] type = PERM
        I(OP_CHKM, 32'hF, (FT_PERM << 1) | 32'h1),
        I(OP_CW, FW_STATUS, ST_STICKY),          // acknowledge -> irq drops
        I(OP_CHKI, 32'h0, 32'h0),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 7 - WO_R : reading the write-only window is refused - and returns
        //            ZEROS, not the stored data. The data never leaves the
        //            peripheral, which is the point of a read permission.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h7, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_WO, 32'hFEED_FACE),          // allowed: the window is write-only
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_DR, AD_WO, 32'h0),
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'h0),        // zeros, not 0xFEEDFACE
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_PERM),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 8 - DEC_R : an address in no rule at all. DECODEERROR, and the
        //             burst still gets every beat it is owed - Avalon-MM has
        //             no way to abort, so "deny" means the firewall answers
        //             for the peripheral, not that it goes quiet.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h8, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_CLRW, 32'h0, 32'h0),
        B(OP_DR, 8'd4, AD_NONE, 32'h0),
        I(OP_CHKR, RSP_DECERR, 32'h0),
        I(OP_CHKB, 32'd4, 32'h0),                // all four beats returned
        I(OP_CHKW, 32'h0, 32'h0),                // and m0 was never touched
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_ADDR),
        I(OP_CR, FW_FAULT_INFO, 32'h0),
        I(OP_CHKM, 32'hF, (FT_ADDR << 1)),       // was_write = 0
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // 9 - STRAD : the scenario a start-address-only firewall fails.
        //
        // The burst starts at 0x30, inside rule 0, and runs eight beats to
        // 0x4F - inside rule 1. BOTH windows permit read, write and bursts,
        // so nothing about this access is forbidden by either rule on its
        // own. It is refused anyway, because permissions are per-window and
        // adjacent windows deliberately do not merge.
        //
        // The watcher proves m0 was never touched: a firewall that checked
        // only s0_address would have forwarded the whole burst, and a DMA
        // engine would have walked straight through the window boundary.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'h9, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_CLRW, 32'h0, 32'h0),
        B(OP_DR, 8'd8, AD_STRAD, 32'h0),
        I(OP_CHKR, RSP_DECERR, 32'h0),           // range violation = decode error
        I(OP_CHKB, 32'd8, 32'h0),                // still owed, still delivered
        I(OP_CHKW, 32'h0, 32'h0),                // nothing reached the peripheral
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_BURST),
        I(OP_CR, FW_FAULT_INFO, 32'h0),
        I(OP_CHKM, 32'hF, (FT_BRANGE << 1)),
        I(OP_CR, FW_FAULT_ADDR, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, AD_STRAD),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // A - NOBST : rule 4 permits reads and writes but clears BURST_ALLOW.
        //             A single access is fine; any burst is refused with
        //             SLAVEERROR and BURST_VIOLATION, and the window's
        //             contents are proven untouched afterwards.
        //
        // This is per-window rather than global because "this peripheral
        // cannot handle bursts" is a property of the peripheral, and a system
        // usually has both kinds behind one firewall.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hA, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DW, AD_NB, 32'h5150_0001),          // single access: allowed
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CLRW, 32'h0, 32'h0),
        B(OP_DW, 8'd4, AD_NB, 32'h9999_0000),    // burst: refused
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKW, 32'h0, 32'h0),                // never reached the peripheral
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, ST_BURST),
        I(OP_CR, FW_FAULT_INFO, 32'h0),
        I(OP_CHKM, 32'hF, (FT_BDENIED << 1) | 32'h1),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_DR, AD_NB, 32'h0),                  // contents untouched by the refused burst
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'h5150_0001),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // b - TMO_W : the peripheral refuses the command outright -
        //             waitrequest stuck high, nothing ever accepted.
        //
        // The master is released with SLAVEERROR rather than left hanging,
        // and the core latches TIMEOUT | ISOLATED | BLOCKED | WR_CMD_STUCK.
        // WR_CMD_STUCK is the bit that matters: the core is holding an
        // m0_write whose waitrequest never fell, and Avalon-MM forbids
        // withdrawing it, so only RECOVERY.UNBLOCK can retract it.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hB, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_STARVE, 32'h0),
        B(OP_DW, 8'd4, AD_RW0, 32'hCAFE_F00D),
        I(OP_CHKR, RSP_SLVERR, 32'h0),           // released, not hung
        I(OP_CHKS, 32'h0, 32'h0),                // and released by the CORE, not the watchdog
        I(OP_CHKI, 32'h1, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_TMO | ST_ISO | ST_BLK | ST_WRS,
                   ST_TMO | ST_ISO | ST_BLK | ST_WRS),
        I(OP_CR, FW_FAULT_INFO, 32'h0),
        I(OP_CHKM, 32'hF, (FT_TIMEOUT << 1) | 32'h1),
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // C - TMO_R : BOTH read-timeout shapes, back to back, because the
        //             difference between them is the whole point.
        //
        // The write channel gets one shape each in b (never accepted). The
        // read channel gets both here, because RD_CMD_STUCK is the only
        // STATUS bit no other scenario sets - and a bit the board can display
        // but nothing ever lights is a bit nobody can trust.
        //
        // Half 1: waitrequest stuck, the command is NEVER accepted. The core
        // is left holding an m0_read it is forbidden to withdraw, so
        // RD_CMD_STUCK sets and only RECOVERY.UNBLOCK clears it.
        //
        // Half 2: the peripheral ACCEPTS the read and then goes silent. It
        // genuinely owes beats, so RD_CMD_STUCK stays CLEAR - the opposite of
        // half 1. That difference is what a driver needs: a peripheral that
        // accepted and then died owes a response forever, so an unbounded poll
        // of the busy bits hangs exactly when recovery matters.
        //
        // Either way the master is released with the full burst's worth of
        // synthesised error beats, because Avalon-MM has no way to abort.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hC, 32'h0),

        // ---- half 1: accepted, then silent ----
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_SILENT, 32'h0),
        B(OP_DR, 8'd4, AD_RW0, 32'h0),
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKB, 32'd4, 32'h0),                // every owed beat synthesised
        I(OP_CHKS, 32'h0, 32'h0),                // released by the CORE, not the watchdog
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_TMO | ST_ISO | ST_BLK, ST_TMO | ST_ISO | ST_BLK),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_RDS, 32'h0),               // NOT stuck: the command WAS accepted

        // ---- recover, so the second half starts from a known state ----
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_RESET, 32'h0),
        I(OP_WAIT, 32'd40, 32'h0),
        I(OP_CW, FW_RECOVERY, 32'h1),            // UNBLOCK while still in reset
        I(OP_WAIT, 32'd8, 32'h0),
        I(OP_SET, P_RUN, 32'h0),
        I(OP_WAIT, 32'd40, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, 32'h0),               // fully clean before half 2

        // ---- half 2: the command is never accepted ----
        //
        // Deliberately LAST. This is the only scenario that sets
        // RD_CMD_STUCK, and leaving it set at the end is what lets SW[5] show
        // STATUS[9] on the board - a bit the display can reach but nothing
        // ever lights is a bit nobody can trust. Scenario b ends the same way
        // with WR_CMD_STUCK, so the two are symmetric.
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_STARVE, 32'h0),
        B(OP_DR, 8'd4, AD_RW0, 32'h0),
        I(OP_CHKR, RSP_SLVERR, 32'h0),           // released, not hung
        I(OP_CHKB, 32'd4, 32'h0),
        I(OP_CHKS, 32'h0, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_TMO | ST_ISO | ST_BLK | ST_RDS,
                   ST_TMO | ST_ISO | ST_BLK | ST_RDS),
        I(OP_CR, FW_FAULT_INFO, 32'h0),
        I(OP_CHKM, 32'hF, (FT_TIMEOUT << 1)),    // was_write = 0: this was the read side
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // d - BLKD : while blocked, traffic is REJECTED, not stalled, and
        //            nothing new reaches the peripheral.
        //
        // There is no window in which the firewall quietly holds traffic, so
        // a driver needs a retry path rather than a wait loop. A rejection
        // while blocked also raises no NEW fault - the timeout already
        // latched one, and re-latching would overwrite the FAULT_ADDR that
        // actually diagnoses the problem.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hD, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_STARVE, 32'h0),
        I(OP_DW, AD_RW0, 32'h1111_2222),         // break it
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_SET, P_RUN, 32'h0),                 // peripheral is healthy again...
        I(OP_CW, FW_STATUS, ST_STICKY),          // ...and the fault acknowledged...
        I(OP_CLRW, 32'h0, 32'h0),
        B(OP_DR, 8'd4, AD_RW0, 32'h0),           // ...but the core is still BLOCKED
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CHKB, 32'd4, 32'h0),                // answered, not stalled
        I(OP_CHKW, 32'h0, 32'h0),                // nothing reached the peripheral
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_BLK, ST_BLK),              // still blocked after the W1C
        I(OP_CHKM, ST_STICKY, 32'h0),            // and no NEW fault was latched
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // E - RCVR : the documented recovery sequence, done correctly.
        //
        // The peripheral is wedged with a write that never lands, then
        // recovered: acknowledge, hold the peripheral in reset, UNBLOCK while
        // it is still in reset, release. Reading the target back afterwards
        // finds ZERO - nothing stale landed - and traffic is healthy again.
        // Compare with scenario F.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hE, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_STARVE, 32'h0),
        I(OP_DW, AD_RW0, 32'hCAFE_F00D),         // this write must never land
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),          // step 2: acknowledge
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_BLK, ST_BLK),              // W1C alone does NOT unblock
        I(OP_SET, P_RESET, 32'h0),               // step 4: hold the peripheral in reset
        I(OP_WAIT, 32'd40, 32'h0),
        I(OP_CW, FW_RECOVERY, 32'h1),            // step 5: UNBLOCK, still in reset
        I(OP_WAIT, 32'd8, 32'h0),
        I(OP_SET, P_RUN, 32'h0),                 // step 6: release
        I(OP_WAIT, 32'd40, 32'h0),
        I(OP_CR, FW_STATUS, 32'h0),
        I(OP_CHKM, ST_ALL, 32'h0),               // fully clean
        I(OP_DR, AD_RW0, 32'h0),                 // step 7: traffic works again
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'h0),        // and NOTHING stale landed
        I(OP_END, 32'h0, 32'h0),

        // -----------------------------------------------------------------
        // F - STALE : the same recovery with the reset released ONE STEP TOO
        //             EARLY, and the hazard it opens.
        //
        // The frozen m0_write is still asserted. Release the peripheral
        // before writing UNBLOCK and it sees a perfectly valid command
        // sitting on the bus, completes the handshake, and commits a write
        // the master was already told had FAILED. Reading back finds
        // 0xCAFEF00D where scenario E found zero.
        //
        // P on this scenario means the BAD thing happened, reproducibly.
        // That is why the core's recovery sequence puts UNBLOCK at step 5 and
        // the reset release at step 6, and why it deviates from AMD's
        // published AXI Firewall flow, which resets and then unblocks.
        // -----------------------------------------------------------------
        I(OP_MARK, 32'hF, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_STARVE, 32'h0),
        I(OP_DW, AD_RW0, 32'hCAFE_F00D),
        I(OP_CHKR, RSP_SLVERR, 32'h0),
        I(OP_CW, FW_STATUS, ST_STICKY),
        I(OP_SET, P_RESET, 32'h0),               // reset the peripheral...
        I(OP_WAIT, 32'd40, 32'h0),
        I(OP_SET, P_RUN, 32'h0),                 // ...and RELEASE IT FIRST - the mistake
        I(OP_WAIT, 32'd40, 32'h0),
        I(OP_CW, FW_RECOVERY, 32'h1),            // UNBLOCK, too late to help
        I(OP_WAIT, 32'd40, 32'h0),
        I(OP_DR, AD_RW0, 32'h0),
        I(OP_CHKR, RSP_OKAY, 32'h0),
        I(OP_CHKM, 32'hFFFF_FFFF, 32'hCAFE_F00D),  // the stale write LANDED
        I(OP_END, 32'h0, 32'h0)
    };

    // =====================================================================
    // Two masters: one at the firewall's csr port, one at its s0 data port.
    // =====================================================================
    logic                    ctl_req, ctl_write, ctl_busy, ctl_done, ctl_done_write;
    logic [31:0]             ctl_addr, ctl_wdata, ctl_rdata;
    logic [1:0]              ctl_resp;

    logic                    dat_req, dat_write, dat_busy, dat_done, dat_done_write;
    logic [ADDR_WIDTH-1:0]   dat_addr;
    logic [DATA_WIDTH-1:0]   dat_wdata, dat_rdata;
    logic [BURST_WIDTH-1:0]  dat_burst;
    logic [1:0]              dat_resp;
    logic [BURST_WIDTH:0]    dat_beats;
    logic                    dat_data_ok, dat_stuck;
    logic [15:0]             dat_cycles;

    // ------------------------------------------------------------------
    // csr adapter.
    //
    // The core's csr port is the dullest possible Avalon-MM slave: word
    // addressed, fixed read latency of 1, and it never asserts waitrequest -
    // it has to stay reachable when the data path is isolated or wedged, so
    // it has no state that could get stuck. The generic master expects
    // waitrequest and readdatavalid, so they are synthesised here rather than
    // giving the demo a second, nearly identical master.
    // ------------------------------------------------------------------
    logic        ctl_m_read, ctl_m_write;
    logic [31:0] ctl_m_address;
    logic [3:0]  ctl_m_byteenable;
    logic        csr_rdv;

    always_ff @(posedge clk) begin
        if (!resetn) csr_rdv <= 1'b0;
        else         csr_rdv <= ctl_m_read;      // fixed read latency of 1
    end

    // The csr port is word-addressed; the program quotes byte offsets, which
    // is what software uses. This is the divide-by-four that the Platform
    // Designer interconnect would do in a real system.
    assign c_address    = ctl_m_address[CSR_ADDR_WIDTH+1:2];
    assign c_read       = ctl_m_read;
    assign c_write      = ctl_m_write;
    assign c_byteenable = ctl_m_byteenable;

    demo_avl_mm_master #(
        .ADDR_WIDTH(32), .DATA_WIDTH(32), .BURST_WIDTH(BURST_WIDTH),
        .USE_WRITE_RESPONSE(0)          // a csr write completes when accepted
    ) u_ctl (
        .clk(clk), .resetn(resetn),
        .req(ctl_req), .req_write(ctl_write), .req_addr(ctl_addr),
        .req_wdata(ctl_wdata), .req_burst(BURST_WIDTH'(1)),
        .busy(ctl_busy), .done(ctl_done), .done_write(ctl_done_write),
        .rdata(ctl_rdata), .resp(ctl_resp),
        .beats(), .data_ok(), .cycles(), .stuck(),
        .m_address(ctl_m_address), .m_read(ctl_m_read), .m_write(ctl_m_write),
        .m_writedata(c_writedata), .m_byteenable(ctl_m_byteenable), .m_burstcount(),
        .m_waitrequest(1'b0),           // csr never stalls
        .m_readdata(c_readdata), .m_readdatavalid(csr_rdv),
        .m_response(2'b00), .m_writeresponsevalid(1'b0)
    );

    demo_avl_mm_master #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .BURST_WIDTH(BURST_WIDTH),
        .USE_WRITE_RESPONSE(1)
    ) u_dat (
        .clk(clk), .resetn(resetn),
        .req(dat_req), .req_write(dat_write), .req_addr(dat_addr),
        .req_wdata(dat_wdata), .req_burst(dat_burst),
        .busy(dat_busy), .done(dat_done), .done_write(dat_done_write),
        .rdata(dat_rdata), .resp(dat_resp),
        .beats(dat_beats), .data_ok(dat_data_ok), .cycles(dat_cycles), .stuck(dat_stuck),
        .m_address(d_address), .m_read(d_read), .m_write(d_write),
        .m_writedata(d_writedata), .m_byteenable(d_byteenable), .m_burstcount(d_burstcount),
        .m_waitrequest(d_waitrequest),
        .m_readdata(d_readdata), .m_readdatavalid(d_readdatavalid),
        .m_response(d_response), .m_writeresponsevalid(d_writeresponsevalid)
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
    logic [9:0]  pc;            // 9 bits addresses the program, 10th is headroom
                                //  so the bounds compare below cannot wrap
    logic [2:0]  heal_step;
    logic [15:0] wait_cnt;
    logic [PACE_BITS-1:0] pace_cnt;
    logic        pass_acc;
    logic [1:0]  last_resp;
    logic [BURST_WIDTH:0] last_beats;
    logic        last_data_ok;
    logic [15:0] last_cycles;
    logic [2:0]  periph_ctl;
    logic [31:0] ctl_addr_issued;
    logic        ctl_is_poll;      // the outstanding csr read is a background poll

    instr_t instr;
    always_comb instr = (pc < 10'(PROG_LEN)) ? PROG[pc[8:0]] : I(OP_NOP, 32'h0, 32'h0);

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
            result_pass     <= 1'b0;
            obs             <= '0;
            status_shadow   <= '0;
            last_resp       <= 2'b00;
            last_beats      <= '0;
            last_data_ok    <= 1'b0;
            last_cycles     <= '0;
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
            dat_burst       <= BURST_WIDTH'(1);
        end else begin
            ctl_req     <= 1'b0;
            dat_req     <= 1'b0;
            watch_clear <= 1'b0;

            // ---- transaction results -------------------------------------
            // last_resp and friends are data-path only, on purpose: OP_CHKR
            // is always a claim about what the protected path answered, and
            // control traffic (which always returns OKAY) must not overwrite
            // it. A polled read refreshes the LEDs but must NOT touch `obs`:
            // `obs` is what the operator sees on HEX3..0 with SW[6]=1, and it
            // has to stay showing whatever the scenario last looked at - the
            // poll runs continuously once a scenario ends, so without this it
            // would overwrite the result within microseconds of it appearing.
            if (ctl_done && !ctl_done_write) begin
                if (!ctl_is_poll) obs <= ctl_rdata;
                if (ctl_addr_issued == FW_STATUS) status_shadow <= ctl_rdata;
            end
            if (dat_done) begin
                last_resp    <= dat_resp;
                last_beats   <= dat_beats;
                last_data_ok <= dat_data_ok;
                last_cycles  <= dat_cycles;
                if (!dat_done_write) obs <= dat_rdata;
            end

            // The csr port is not subject to firewall rules and cannot be
            // blocked by an isolated downstream - that separation is the
            // reason it exists - so it must answer unconditionally. No
            // scenario asserts this explicitly, so assert it everywhere.
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
                                ctl_addr        <= FW_STATUS;
                                ctl_addr_issued <= FW_STATUS;
                                ctl_wdata       <= ST_STICKY;
                                ctl_is_poll     <= 1'b0;
                                heal_step       <= 3'd3;
                            end
                            3'd3: begin
                                ctl_req         <= 1'b1;
                                ctl_write       <= 1'b1;
                                ctl_addr        <= FW_RECOVERY;
                                ctl_addr_issued <= FW_RECOVERY;
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
                    end else if (pc >= 10'(PROG_LEN - 1)) begin
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
                                ctl_addr        <= instr.a0;
                                ctl_addr_issued <= instr.a0;
                                ctl_wdata       <= instr.a1;
                                ctl_is_poll     <= 1'b0;
                            end
                            OP_CR: begin
                                ctl_req         <= 1'b1;
                                ctl_write       <= 1'b0;
                                ctl_addr        <= instr.a0;
                                ctl_addr_issued <= instr.a0;
                                ctl_is_poll     <= 1'b0;
                            end
                            OP_DW: begin
                                dat_req   <= 1'b1;
                                dat_write <= 1'b1;
                                dat_addr  <= instr.a0[ADDR_WIDTH-1:0];
                                dat_wdata <= instr.a1[DATA_WIDTH-1:0];
                                dat_burst <= BURST_WIDTH'(instr.bc);
                            end
                            OP_DR: begin
                                dat_req   <= 1'b1;
                                dat_write <= 1'b0;
                                dat_addr  <= instr.a0[ADDR_WIDTH-1:0];
                                dat_wdata <= instr.a1[DATA_WIDTH-1:0];  // expected ramp seed
                                dat_burst <= BURST_WIDTH'(instr.bc);
                            end
                            OP_CHKM: if ((obs & instr.a0) != instr.a1)   pass_acc <= 1'b0;
                            OP_CHKR: if (last_resp    != instr.a0[1:0])  pass_acc <= 1'b0;
                            OP_CHKI: if (fw_irq       != instr.a0[0])    pass_acc <= 1'b0;
                            OP_CHKW: if (new_cmd_seen != instr.a0[0])    pass_acc <= 1'b0;
                            OP_CHKB: if (32'(last_beats)  != instr.a0)   pass_acc <= 1'b0;
                            OP_CHKD: if (last_data_ok != instr.a0[0])    pass_acc <= 1'b0;
                            OP_CHKC: if (32'(last_cycles) > instr.a0)    pass_acc <= 1'b0;
                            OP_CHKS: if (dat_stuck    != instr.a0[0])    pass_acc <= 1'b0;
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
                ctl_addr        <= FW_STATUS;
                ctl_addr_issued <= FW_STATUS;
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
                OP_CHKB: if (32'(last_beats) != instr.a0)
                    $display("[%0t] scen %0X pc %0d  CHKB FAIL  beats=%0d, expected %0d",
                             $time, scen, pc, last_beats, instr.a0);
                OP_CHKD: if (last_data_ok != instr.a0[0])
                    $display("[%0t] scen %0X pc %0d  CHKD FAIL  data_ok=%0b, expected %0b",
                             $time, scen, pc, last_data_ok, instr.a0[0]);
                OP_CHKC: if (32'(last_cycles) > instr.a0)
                    $display("[%0t] scen %0X pc %0d  CHKC FAIL  cycles=%0d, budget %0d",
                             $time, scen, pc, last_cycles, instr.a0);
                OP_CHKS: if (dat_stuck != instr.a0[0])
                    $display("[%0t] scen %0X pc %0d  CHKS FAIL  stuck=%0b, expected %0b",
                             $time, scen, pc, dat_stuck, instr.a0[0]);
                default: ;
            endcase
        end
    end
`endif

endmodule
