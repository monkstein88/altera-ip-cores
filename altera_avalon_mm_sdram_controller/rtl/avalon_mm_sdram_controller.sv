`timescale 1ns/1ps
// =============================================================================
// avalon_mm_sdram_controller.sv
//
// An SDR SDRAM controller for Avalon-MM, with per-bank open-row tracking.
//
// WHAT THIS DOES DIFFERENTLY
// --------------------------
// Intel's core (altera_avalon_new_sdram_controller), which this replaces,
// tracks ONE open row and requires the access direction to match for its
// fast path:
//
//     assign pending = csn_match && rnw_match && bank_match && row_match ...
//                                   ^^^^^^^^^
//
// so every read/write turnaround falls out of the fast path into
// PRECHARGE -> tRP -> ACTIVATE -> tRCD. Measurement (see benchmark/) put the
// cost at 8.9x: 194 MB/s streaming in one direction, 21.9 MB/s the moment the
// direction alternates - even when every access is inside a single open row,
// where the device needs no row commands at all.
//
// This design keeps one open row PER BANK and treats a turnaround as what the
// datasheet says it is: free write->read, one cycle read->write. Row commands
// are issued only when the row actually has to change.
//
// PARAMETERISED IN TIME, NOT IN CYCLES
// ------------------------------------
// Every device timing is an integer number of picoseconds, converted to cycles
// here. Cycle counts are deliberately NOT exposed: a timing parameter rounded
// the wrong way is silent data corruption at temperature months later, not a
// clean failure, and pushing that arithmetic onto the integrator guarantees
// someone gets it wrong. Retarget by changing the timings and the clock, not
// by recomputing cycles. The Platform Designer component asks for nanoseconds
// and scales them; picoseconds are the wire format, for the reason given below.
//
// Which way a timing rounds depends on what KIND of limit it is, and getting
// that uniform was a bug:
//
//   * MINIMUM delays - tRC, tRAS, tRP, tRCD, tRRD, tWR, tMRD, tRFC - round UP.
//     A cycle too many costs performance; a cycle too few corrupts.
//   * The MAXIMUM refresh interval rounds DOWN, for exactly the same reason
//     read the other way round. Rounding it up refreshes the part less often
//     than it allows.
//   * Timings the datasheet states in CLOCKS rather than in time - tRRD, tWR
//     and tMRD are 2 clocks on this part at every speed grade - additionally
//     carry a floor in cycles. Below about 71 MHz a 14 ns figure is less than
//     one clock, and without the floor all three collapse to a single cycle.
//
// COMMAND TIMING CONVENTION
// -------------------------
// All SDRAM outputs are registered, so a command decided in cycle k is sampled
// by the device on edge k+1. The timing counters are therefore loaded with
// (cycles - 1): see `gate()`. Getting this off by one is not academic - it is
// either a wasted cycle on every row change, or a violation.
// =============================================================================

module avalon_mm_sdram_controller #(
    // ---- device geometry ----
    parameter int  DATA_BITS   = 16,
    parameter int  ROW_BITS    = 13,
    parameter int  COL_BITS    = 10,
    parameter int  BANK_BITS   = 2,
    parameter int  SA_BITS     = 13,    // SDRAM address pins

    // Avalon word address width. Derived, and not intended to be overridden -
    // it appears in the parameter list only because it sizes a port.
    parameter int  ADDR_W      = ROW_BITS + COL_BITS + BANK_BITS,

    // ---- device timings, PICOSECONDS ----
    //
    // Integers, not `parameter real` in nanoseconds, because Platform Designer
    // emits a FLOAT parameter as a QUOTED STRING - `.T_RC_NS("60.0")`. A string
    // literal assigned to a real parameter is its ASCII bytes read as a number:
    // "60.0" arrives as 909127216.0, and a 60 ns tRC silently becomes 90 million
    // cycles. That is why Intel's own SDRAM component declares every one of its
    // nanosecond parameters HDL_PARAMETER {0} and converts them in Tcl.
    //
    // This core keeps the conversion in the HDL - there is exactly one ceiling
    // division and it should exist exactly once - and takes integer picoseconds
    // so nothing has to cross the tool boundary as a float. The Platform
    // Designer component still asks for nanoseconds and derives these; see
    // altera_avalon_mm_sdram_controller_hw.tcl.
    parameter int  T_RC_PS     = 60_000,  // ACT -> ACT, same bank      (60 ns)
    parameter int  T_RAS_PS    = 37_000,  // ACT -> PRE, same bank      (37 ns)
    parameter int  T_RP_PS     = 15_000,  // PRE -> ACT, same bank      (15 ns)
    parameter int  T_RCD_PS    = 15_000,  // ACT -> READ/WRITE          (15 ns)
    parameter int  T_RRD_PS    = 14_000,  // ACT -> ACT, different bank (14 ns)
    parameter int  T_WR_PS     = 14_000,  // last write data -> PRE     (14 ns)
    parameter int  T_MRD_PS    = 14_000,  // LOAD MODE -> any command   (14 ns)
    parameter int  T_RFC_PS    = 60_000,  // REFRESH -> ACT/REFRESH     (60 ns)
    parameter int  T_INIT_US   = 100,     // power-on NOP wait, microseconds
    parameter int  CAS_LAT     = 3,
    parameter int  INIT_REFS   = 8,     // refreshes during initialisation

    // ---- refresh ----
    parameter int  REF_ROWS      = 8192,
    parameter int  REF_PERIOD_MS = 64,
    // JEDEC permits refreshes to be postponed and issued as a burst. Holding
    // some back lets a streaming burst finish instead of being cut in half.
    parameter int  REF_MAX_PEND  = 8,

    // ---- clock ----
    parameter int  CLK_KHZ     = 100_000,

    // ---- controller options ----
    // ADDR_MAP 0: bank[0] directly above the column, remaining bank bits at
    //             the top - the map Intel's core uses. Interleaves banks
    //             every 2^COL_BITS words, which suits streaming.
    // ADDR_MAP 1: {row, bank, col}, bank bits contiguous.
    parameter int  ADDR_MAP    = 0,
    parameter int  FIFO_DEPTH  = 8,     // buffered commands, power of two
    // Open/close the NEXT access's row early. `int` rather than `bit` so
    // Platform Designer can drive it from an ordinary integer parameter.
    parameter int  LOOKAHEAD   = 1,

    // Extra read-capture delay beyond CAS latency, for a board whose DQ return
    // path is registered (an input register in the pin, a resynchroniser).
    // Zero is correct for a direct connection: see the read-return block.
    parameter int  RD_EXTRA_LAT = 0
) (
    input  logic                    clk,
    input  logic                    reset_n,

    // ---- Avalon-MM slave (legacy az_/za_ naming, so this is a drop-in for
    //      the controller it replaces) ----
    input  logic [ADDR_W-1:0]       az_addr,
    input  logic [DATA_BITS/8-1:0]  az_be_n,
    input  logic                    az_cs,
    input  logic [DATA_BITS-1:0]    az_data,
    input  logic                    az_rd_n,
    input  logic                    az_wr_n,
    output logic [DATA_BITS-1:0]    za_data,
    output logic                    za_valid,
    output logic                    za_waitrequest,

    // ---- SDRAM ----
    output logic [SA_BITS-1:0]      zs_addr,
    output logic [BANK_BITS-1:0]    zs_ba,
    output logic                    zs_cas_n,
    output logic                    zs_cke,
    output logic                    zs_cs_n,
    inout  wire  [DATA_BITS-1:0]    zs_dq,
    output logic [DATA_BITS/8-1:0]  zs_dqm,
    output logic                    zs_ras_n,
    output logic                    zs_we_n
);

    localparam int BANKS = 1 << BANK_BITS;
    localparam int DQM_W = DATA_BITS / 8;

    // =========================================================================
    // Time -> cycles.  INTEGER ARITHMETIC ONLY.
    // =========================================================================
    // These were `real` until Quartus was pointed at them. Analysis & Synthesis
    // in Quartus Standard rejects a `real` VARIABLE outright - "Error (10172):
    // real variable data type values are not supported" - even inside a
    // function that is only ever evaluated at elaboration. The core did not
    // synthesise at all, and no simulation flow could have told us: Verilator
    // lints it clean with -Wall and nothing waived.
    //
    // So the conversion is integer picoseconds throughout. cycles =
    // ps * CLK_KHZ / 1e9, because ps*1e-12 s x kHz*1e3 Hz = ps*kHz*1e-9.
    //
    // EVERY intermediate must be 64-bit and every literal explicitly sized. An
    // unsized decimal literal is only guaranteed 32 bits, so `1_000_000_000_000`
    // silently truncates - which is the same class of unit bug as the quoted
    // FLOAT parameter this core already carries scar tissue from.
    //
    // Range: T_*_PS is at most 2^31 ps (2.1 ms); at 1 GHz that is 2.1e15,
    // comfortably inside a 64-bit product.
    localparam longint unsigned PS_PER_CYC_DIV = 64'd1_000_000_000;

    // Minimum timings: ACT->RD, PRE->ACT and friends. Rounding UP is the safe
    // direction - a cycle too many costs performance, a cycle too few is
    // silent corruption at temperature.
    function automatic int unsigned cyc_ps(input longint unsigned ps);
        longint unsigned num;
        num = ps * longint'(CLK_KHZ);
        return (num == 0) ? 1
             : int'((num + PS_PER_CYC_DIV - 1) / PS_PER_CYC_DIV);
    endfunction

    // MAXIMUM timings - so far only the refresh interval. Rounding up here is
    // the WRONG direction: it refreshes less often than the part requires.
    // This is the one conversion in the core that floors.
    function automatic int unsigned cyc_ps_max(input longint unsigned ps);
        longint unsigned c;
        c = (ps * longint'(CLK_KHZ)) / PS_PER_CYC_DIV;
        return (c < 1) ? 1 : int'(c);
    endfunction

    // Some SDR timings are specified in CLOCKS, not in time. On the ISSI
    // IS42S16320D the cycle column is 2 for tRRD, tDPL(tWR) and tMRD at every
    // speed grade, while the nanosecond column tracks the grade's tCK - which
    // is what "2 clocks" means when written out in ns.
    //
    // Converting those back to cycles is exact only while tCK is at or below
    // the figure the datasheet quoted. Below roughly 71 MHz, 14 ns is less
    // than one clock and all three collapse to a single cycle - an illegal
    // command stream that the timing checker used to agree with, because it
    // derived the same number from the same nanoseconds.
    localparam int unsigned MIN_CYC_RRD = 2;   // JEDEC SDR: tRRD >= 2 clocks
    localparam int unsigned MIN_CYC_WR  = 2;   // tDPL      >= 2 clocks
    localparam int unsigned MIN_CYC_MRD = 2;   // tMRD      >= 2 clocks

    function automatic int unsigned at_least(input int unsigned c,
                                             input int unsigned floor_c);
        return (c < floor_c) ? floor_c : c;
    endfunction

    // Counters are loaded with (cycles - 1) because the command outputs are
    // registered: see the header. `gate` is the only place that -1 appears.
    function automatic int unsigned gate(input int unsigned c);
        return (c <= 1) ? 0 : c - 1;
    endfunction

    localparam int unsigned CYC_RC   = cyc_ps(longint'(T_RC_PS));
    localparam int unsigned CYC_RAS  = cyc_ps(longint'(T_RAS_PS));
    localparam int unsigned CYC_RP   = cyc_ps(longint'(T_RP_PS));
    localparam int unsigned CYC_RCD  = cyc_ps(longint'(T_RCD_PS));
    localparam int unsigned CYC_RRD  = at_least(cyc_ps(longint'(T_RRD_PS)),
                                                MIN_CYC_RRD);
    localparam int unsigned CYC_WR   = at_least(cyc_ps(longint'(T_WR_PS)),
                                                MIN_CYC_WR);
    localparam int unsigned CYC_MRD  = at_least(cyc_ps(longint'(T_MRD_PS)),
                                                MIN_CYC_MRD);
    localparam int unsigned CYC_RFC  = cyc_ps(longint'(T_RFC_PS));
    localparam int unsigned CYC_INIT = cyc_ps(longint'(T_INIT_US) * 64'd1_000_000);
    // Average interval between AUTO REFRESH commands. REF_PERIOD_MS ms in ps
    // is x 1e9, and that product needs 64 bits well before REF_PERIOD_MS gets
    // interesting.
    localparam int unsigned CYC_REFI =
        cyc_ps_max((longint'(REF_PERIOD_MS) * 64'd1_000_000_000)
                   / longint'(REF_ROWS));

    // Bus turnaround. A READ issued at T has the device driving DQ at T+CAS.
    // A WRITE drives DQ in its own cycle, so the earliest safe write is
    // T+CAS+1. The other direction is free - the datasheet allows write data
    // to be immediately followed by a READ command.
    localparam int unsigned CYC_WTR = CAS_LAT + 1;
    // READ -> PRECHARGE of the same bank needs no counter.
    //
    // The datasheet puts the earliest non-truncating PRECHARGE at (CAS-1)
    // cycles before the last data element. For a length-1 burst that is
    // T+CAS-(CAS-1) = T+1, for CAS 2 and CAS 3 alike. The command outputs are
    // registered, so the soonest any command can follow a READ is already one
    // cycle - the constraint is met by construction.
    //
    // There used to be a c_rdp counter here. It was loaded with gate(1) = 0
    // on every read and therefore never held a non-zero value: Questa's
    // statement coverage reported its decrement as unreachable, which is what
    // sent us back to the datasheet to confirm the reasoning above.

    localparam int TW        = 8;       // timing counter width, cycles
    localparam int RD_PIPE_D = CAS_LAT + RD_EXTRA_LAT;

    localparam logic [RD_PIPE_D:0] RD_SEED = {1'b1, {RD_PIPE_D{1'b0}}};

    // Mode register: burst length 1, sequential, CAS latency, programmed
    // write burst length.  A12:A10=000  A9=0  A8:A7=00  A6:A4=CAS  A3=0  A2:A0=000
    localparam logic [SA_BITS-1:0] MODE_REG =
        SA_BITS'({3'b000, 1'b0, 2'b00, 3'(CAS_LAT), 1'b0, 3'b000});

    initial begin
        if (SA_BITS < 11)
            $fatal(1, "SA_BITS must be >= 11: A10 is the precharge-all bit");
        if (COL_BITS > 11)
            $fatal(1, "COL_BITS > 11 is not supported by this address encoding");
        if (CAS_LAT < 1 || CAS_LAT > 7)
            $fatal(1, "CAS_LAT out of range");
        if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH-1)) != 0)
            $fatal(1, "FIFO_DEPTH must be a power of two, >= 2");
        if (ADDR_W != ROW_BITS + COL_BITS + BANK_BITS)
            $fatal(1, "ADDR_W is derived; do not override it");
        $display("[sdram] @%0d kHz: tRC=%0d tRAS=%0d tRP=%0d tRCD=%0d tRRD=%0d tWR=%0d tRFC=%0d CAS=%0d tREFI=%0d",
                 CLK_KHZ, CYC_RC, CYC_RAS, CYC_RP, CYC_RCD, CYC_RRD, CYC_WR,
                 CYC_RFC, CAS_LAT, CYC_REFI);
    end

    // =========================================================================
    // Address decode
    // =========================================================================
    function automatic logic [BANK_BITS-1:0] bank_of(input logic [ADDR_W-1:0] a);
        logic [BANK_BITS-1:0] b;
        b = '0;
        if (ADDR_MAP == 0) begin
            b[0] = a[COL_BITS];
            for (int i = 1; i < BANK_BITS; i++)
                b[i] = a[COL_BITS + ROW_BITS + i];
        end else begin
            for (int i = 0; i < BANK_BITS; i++)
                b[i] = a[COL_BITS + i];
        end
        return b;
    endfunction

    function automatic logic [ROW_BITS-1:0] row_of(input logic [ADDR_W-1:0] a);
        logic [ROW_BITS-1:0] r;
        r = '0;
        for (int i = 0; i < ROW_BITS; i++)
            r[i] = (ADDR_MAP == 0) ? a[COL_BITS + 1 + i]
                                   : a[COL_BITS + BANK_BITS + i];
        return r;
    endfunction

    // The column is the low bits of the address under both maps, so it needs
    // no accessor - see `col_addr` below, which is where it becomes a bus
    // value.

    // Column command address. A10 must be 0 - it is the auto-precharge bit,
    // and this controller manages precharge explicitly, so column bit 10 (on
    // the few parts that have one) steps over it to A11.
    function automatic logic [SA_BITS-1:0] col_addr(input logic [COL_BITS-1:0] c);
        logic [SA_BITS-1:0] a;
        a = '0;
        for (int i = 0; i < COL_BITS; i++)
            a[(i < 10) ? i : i + 1] = c[i];
        a[10] = 1'b0;
        return a;
    endfunction

    // =========================================================================
    // Command FIFO
    //
    // Buffering is what lets the scheduler look past the access being served
    // and open the next row early. Depth 8 covers a row change (tRP + tRCD) at
    // 100 MHz without the master ever stalling.
    // =========================================================================
    localparam int FAW = $clog2(FIFO_DEPTH);

    // The entry carries the access ALREADY DECODED into bank, row and column.
    // Decoding on the way in rather than on the way out keeps the address map
    // off the scheduler's critical path, which runs from the read pointer,
    // through this array's output multiplexer, through the whole S_RUN
    // priority chain, and into the timing counters. That path is what sets
    // f_MAX for the whole core.
    typedef struct packed {
        logic                   is_rd;
        logic [BANK_BITS-1:0]   bank;
        logic [ROW_BITS-1:0]    row;
        logic [COL_BITS-1:0]    col;
        logic [DATA_BITS-1:0]   wdata;
        logic [DQM_W-1:0]       be_n;
    } req_t;

    req_t             fifo [FIFO_DEPTH];
    logic [FAW:0]     wptr, rptr;
    logic             f_empty, f_full, f_two;
    logic             f_push, f_pop;
    logic             init_done;

    assign f_empty = (wptr == rptr);
    assign f_full  = (wptr[FAW-1:0] == rptr[FAW-1:0]) && (wptr[FAW] != rptr[FAW]);
    // At least two entries queued, so look-ahead has something to look at.
    assign f_two   = ((wptr - rptr) > (FAW+1)'(1));

    // A full FIFO does not stall the master if it is also popping this cycle;
    // without that, a 1-in/1-out steady state would stall every other cycle
    // and halve throughput. `f_pop` depends on the registered FIFO head and
    // the bank state, never on `f_push`, so there is no combinational loop.
    assign f_push         = az_cs && (!az_rd_n || !az_wr_n) && !za_waitrequest;
    assign za_waitrequest = !init_done || (f_full && !f_pop);

    req_t push_ent;
    assign push_ent = '{is_rd: !az_rd_n,
                        bank:  bank_of(az_addr),
                        row:   row_of(az_addr),
                        col:   az_addr[COL_BITS-1:0],
                        wdata: az_data,
                        be_n:  az_be_n};

    // =========================================================================
    // Registered FIFO output
    //
    // `head` and the look-ahead entry are REGISTERS, not multiplexer outputs.
    //
    // Something has to select the entry the read pointer names, but it does
    // not have to happen in the same cycle as the scheduler. With `head`
    // combinational the critical path ran from rptr, through a FIFO_DEPTH-way
    // multiplexer, through the entire S_RUN priority chain, and into the
    // timing counters and row bookkeeping - eighteen levels of logic, and
    // f_MAX 83 MHz for a core whose every published figure assumes 100.
    //
    // The three candidate entries are read from the array using rptr ALONE, so
    // those multiplexers start settling at the clock edge. `f_pop` arrives
    // late, from the scheduler, but only ever selects between values that are
    // already resolved. Getting that ordering the wrong way round - computing
    // the next index first and then indexing the array with it - puts the
    // multiplexer back downstream of the scheduler and buys nothing.
    // =========================================================================
    localparam logic [FAW-1:0] IDX1 = FAW'(1);
    localparam logic [FAW-1:0] IDX2 = FAW'(2);

    logic [FAW-1:0] r0, r1, r2;
    assign r0 = rptr[FAW-1:0];
    assign r1 = rptr[FAW-1:0] + IDX1;
    assign r2 = rptr[FAW-1:0] + IDX2;

    // Write-to-read bypass: the entry being pushed this cycle is not in the
    // array yet, so a read pointer that lands on the slot being written has to
    // take it from the input instead.
    logic byp0, byp1, byp2;
    assign byp0 = f_push && (wptr[FAW-1:0] == r0);
    assign byp1 = f_push && (wptr[FAW-1:0] == r1);
    assign byp2 = f_push && (wptr[FAW-1:0] == r2);

    // Only the head is needed in full. Look-ahead asks where the next access
    // lives, never what it carries, so the deeper two multiplexers are just
    // bank and row.
    req_t                 ent0, ent1;
    logic [BANK_BITS-1:0] ent2_bank;
    logic [ROW_BITS-1:0]  ent2_row;
    assign ent0      = byp0 ? push_ent      : fifo[r0];
    assign ent1      = byp1 ? push_ent      : fifo[r1];
    assign ent2_bank = byp2 ? push_ent.bank : fifo[r2].bank;
    assign ent2_row  = byp2 ? push_ent.row  : fifo[r2].row;

    req_t                 head;
    logic [BANK_BITS-1:0] nxt_bank;
    logic [ROW_BITS-1:0]  nxt_row;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            head     <= '0;
            nxt_bank <= '0;
            nxt_row  <= '0;
        end else begin
            head     <= f_pop ? ent1      : ent0;
            nxt_bank <= f_pop ? ent2_bank : ent1.bank;
            nxt_row  <= f_pop ? ent2_row  : ent1.row;
        end
    end

    // The FIFO body is cleared from the reset branch, NOT from an initial
    // block. A variable assigned in an always_ff may not be written by any
    // other process (IEEE 1800-2017 9.2.2.4); Questa rejects the combination
    // outright - "(vopt-7061) Variable 'fifo' driven in an always_ff block,
    // may not be driven by any other process" - and no simulation ever ran
    // because of it. Clearing here costs nothing: the entries are already
    // unreachable until wptr moves.
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wptr <= '0;
            rptr <= '0;
            for (int i = 0; i < FIFO_DEPTH; i++) fifo[i] <= '0;
        end else begin
            if (f_push) begin
                fifo[wptr[FAW-1:0]] <= push_ent;
                wptr <= wptr + 1'b1;
            end
            if (f_pop) rptr <= rptr + 1'b1;
        end
    end

    // =========================================================================
    // Bank state and timing gates
    // =========================================================================
    logic                row_open [BANKS];
    logic [ROW_BITS-1:0] open_row [BANKS];

    logic [TW-1:0] c_rcd [BANKS];   // until RD/WR allowed   (tRCD)
    logic [TW-1:0] c_ras [BANKS];   // until PRE allowed     (tRAS)
    logic [TW-1:0] c_rp  [BANKS];   // until ACT allowed     (tRP)
    logic [TW-1:0] c_rc  [BANKS];   // until ACT allowed     (tRC)
    logic [TW-1:0] c_wr  [BANKS];   // until PRE allowed     (tWR)
    logic [TW-1:0] c_rrd;           // until any ACT allowed (tRRD)
    logic [TW-1:0] c_rfc;           // until any ACT/REF allowed (tRFC, tMRD)
    logic [TW-1:0] c_wtr;           // until a WRITE may follow a READ

    // Readiness is evaluated for EVERY bank in parallel and selected
    // afterwards, rather than selecting the bank and then evaluating it.
    // Both forms describe the same function, but only this one lets the
    // counter comparisons - which depend on nothing but registers - settle
    // while the FIFO output multiplexer is still resolving. Written as
    // functions of a late-arriving bank index they were serialised behind it,
    // and the whole chain showed up as the critical path.
    logic act_ok_v [BANKS];   // closed, and tRP/tRC/tRRD/tRFC all permit ACT
    logic pre_ok_v [BANKS];   // open, and tRAS/tWR have elapsed
    logic rcd_ok_v [BANKS];   // tRCD elapsed, so a column command is legal

    logic any_open, all_pre_ok, all_rp_done;

    always_comb begin
        any_open    = 1'b0;
        all_pre_ok  = 1'b1;
        all_rp_done = 1'b1;
        for (int b = 0; b < BANKS; b++) begin
            act_ok_v[b] = !row_open[b] && (c_rp[b] == '0) && (c_rc[b] == '0)
                          && (c_rrd == '0) && (c_rfc == '0);
            pre_ok_v[b] = row_open[b] && (c_ras[b] == '0) && (c_wr[b] == '0);
            rcd_ok_v[b] = (c_rcd[b] == '0);

            if (row_open[b]) begin
                any_open = 1'b1;
                if (!pre_ok_v[b]) all_pre_ok = 1'b0;
            end
            if (c_rp[b] != '0) all_rp_done = 1'b0;
        end
    end

    // =========================================================================
    // Refresh accounting
    //
    // Refreshes accumulate on a timer and are spent either opportunistically -
    // when there is no traffic - or under duress once REF_MAX_PEND have piled
    // up. This is the point of postponement: a refresh taken in an idle cycle
    // costs nothing, and one taken mid-burst costs tRP + tRFC + tRCD.
    // =========================================================================
    logic [15:0] ref_timer;
    logic [3:0]  ref_pend;
    logic        ref_hold;

    // When holding, S_RUN issues nothing new, so the command stream drains
    // into the refresh sequence instead of being interrupted part-way.
    assign ref_hold = (ref_pend != '0)
                      && ((ref_pend >= 4'(REF_MAX_PEND)) || f_empty);

    // =========================================================================
    // Sequencer
    // =========================================================================
    typedef enum logic [3:0] {
        S_RST, S_INIT_WAIT, S_INIT_PRE, S_INIT_TRP, S_INIT_REF, S_INIT_RFC,
        S_INIT_MRS, S_INIT_MRD, S_RUN, S_REF_PRE, S_REF_TRP, S_REF_CMD
    } state_e;

    typedef enum logic [2:0] {
        C_NOP, C_ACT, C_RD, C_WR, C_PRE, C_REF, C_MRS
    } cmd_e;

    state_e      state;
    logic [23:0] init_cnt;
    logic [3:0]  init_ref_cnt;

    // ---- combinational decision ----
    cmd_e                 cmd;
    logic [BANK_BITS-1:0] cmd_ba;
    logic [SA_BITS-1:0]   cmd_addr;
    logic                 do_wdata;         // drive DQ this cycle

    logic [BANK_BITS-1:0] h_bank, n_bank;
    logic [ROW_BITS-1:0]  h_row,  n_row;
    logic                 h_hit,  n_hit, n_conflict, h_ready;

    assign h_bank = head.bank;
    assign h_row  = head.row;
    assign n_bank = nxt_bank;
    assign n_row  = nxt_row;

    // =========================================================================
    // Registered row match
    //
    // "Is the row this access wants the row this bank has open?" is a
    // ROW_BITS-wide equality followed by a BANKS-way multiplexer, and both
    // used to sit inside the scheduler loop: open_row -> compare -> select by
    // bank -> h_hit -> the S_RUN priority chain -> row_open and back. On a
    // MAX 10 -7 that measured nine levels of logic and 7.6 ns of the 10 ns
    // budget in interconnect alone, and the 100 MHz constraint missed by
    // 0.030 ns.
    //
    // Every operand of that comparison is a register, so none of it has to
    // happen in the cycle that uses it. The answer is computed one cycle
    // ahead, from the values the registers are ABOUT to take, and the
    // scheduler reads a bit.
    //
    // The trick is the same one the FIFO output uses above: the comparisons
    // are made against candidates that depend on nothing but registers, and
    // the late-arriving scheduler signals - f_pop, issue_act, cmd_ba - only
    // ever SELECT between answers that have already settled. Comparing
    // against the selected value instead would put the equality back
    // downstream of the scheduler and buy nothing.
    //
    // The cases, for the value each register takes next:
    //
    //   open_row[b] changes only when an ACT issues to bank b, and then it
    //   becomes the row that ACT carried - h_row from the head branch, n_row
    //   from the look-ahead branch. Otherwise it holds.
    //
    //   head.row becomes ent0.row or ent1.row, chosen by f_pop; nxt_row
    //   becomes ent1.row or ent2_row. An ACT never pops (f_pop is set only in
    //   the column-command branch), so on an ACT cycle those are ent0.row and
    //   ent1.row.
    //
    // Hence: after an ACT to bank b, the bank holds exactly the row that ACT
    // carried, so the match is that row against the next head - and that is a
    // comparison between two registers, available now.
    // =========================================================================
    logic h_match_q [BANKS];      // open_row[b] == head.row, this cycle
    logic n_match_q [BANKS];      // open_row[b] == nxt_row,  this cycle

    logic act_from_n;             // the ACT being issued came from look-ahead

    // Candidates. Comparisons between registers, and nothing else.
    //
    // TWO families of late signal have to be kept out of them, not one.
    // `f_pop` is the scheduler's own output and is obviously late. `byp0`,
    // `byp1` and `byp2` are barely better: the write-to-read bypass fires on
    // f_push, which is gated by za_waitrequest, which is gated by f_pop. So
    // ent0/ent1/ent2_row are NOT register values, and comparing against them
    // puts a ROW_BITS equality downstream of the entire priority chain.
    //
    // That is not a hypothetical. Doing exactly that measured 95.2 MHz
    // standalone against the 100.9 MHz it was meant to improve on, with the
    // critical path running c_rcd -> rcd_ok -> the S_RUN chain -> f_pop ->
    // za_waitrequest -> f_push -> byp2 -> ent2_row -> a 13-bit compare.
    // Splitting the bypass out, so byp* only ever picks between two settled
    // answers, is what makes the idea pay.
    logic mp  [BANKS];            // bank's row == the row being pushed now
    logic m0f [BANKS];            // bank's row == fifo[r0]
    logic m1f [BANKS];            // bank's row == fifo[r1]
    logic p2f [BANKS];            // bank's row == fifo[r2]
    logic m0  [BANKS], m1 [BANKS], p2 [BANKS];
    logic hp, np, h0f, h1f, n0f, n1f;
    logic mh0, mn0, qh1, qn1;     // bank takes the row the ACT carries

    always_comb begin
        for (int b = 0; b < BANKS; b++) begin
            mp [b] = (open_row[b] == push_ent.row);
            m0f[b] = (open_row[b] == fifo[r0].row);
            m1f[b] = (open_row[b] == fifo[r1].row);
            p2f[b] = (open_row[b] == fifo[r2].row);
            m0 [b] = byp0 ? mp[b] : m0f[b];     // byp* only selects
            m1 [b] = byp1 ? mp[b] : m1f[b];
            p2 [b] = byp2 ? mp[b] : p2f[b];
        end
        hp  = (h_row == push_ent.row);
        np  = (n_row == push_ent.row);
        h0f = (h_row == fifo[r0].row);
        h1f = (h_row == fifo[r1].row);
        n0f = (n_row == fifo[r0].row);
        n1f = (n_row == fifo[r1].row);

        mh0 = byp0 ? hp : h0f;    // ACT carried h_row, head takes ent0
        mn0 = byp0 ? np : n0f;    // ACT carried n_row, head takes ent0
        qh1 = byp1 ? hp : h1f;    // ACT carried h_row, nxt takes ent1
        qn1 = byp1 ? np : n1f;    // ACT carried n_row, nxt takes ent1
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (int b = 0; b < BANKS; b++) begin
                h_match_q[b] <= 1'b0;
                n_match_q[b] <= 1'b0;
            end
        end else begin
            // `cmd == C_ACT` rather than `issue_act`: that alias is declared
            // with the rest of the command decode, below. Verilator accepts
            // the forward reference and Questa does not (vlog-2730).
            for (int b = 0; b < BANKS; b++) begin
                if ((cmd == C_ACT) && (cmd_ba == BANK_BITS'(b))) begin
                    h_match_q[b] <= act_from_n ? mn0 : mh0;
                    n_match_q[b] <= act_from_n ? qn1 : qh1;
                end else begin
                    h_match_q[b] <= f_pop ? m1[b] : m0[b];
                    n_match_q[b] <= f_pop ? p2[b] : m1[b];
                end
            end
        end
    end

    // A stale match is unreachable rather than merely harmless: every use is
    // gated by row_open[b], which is false out of reset and can only become
    // true through the ACT branch above, which sets the match in the same
    // cycle. PRECHARGE clears row_open and leaves open_row alone, so it
    // cannot leave a match asserted against a bank that has no row.
    assign h_hit  = row_open[h_bank] && h_match_q[h_bank];
    assign n_hit  = row_open[n_bank] && n_match_q[n_bank];
    // The next access wants a different row in a bank that is already open.
    assign n_conflict = row_open[n_bank] && !n_match_q[n_bank];

    // Reads never wait on turnaround; writes wait for the read bus to clear.
    assign h_ready = h_hit && rcd_ok_v[h_bank]
                     && (head.is_rd || (c_wtr == '0));

    always_comb begin
        cmd        = C_NOP;
        cmd_ba     = h_bank;
        cmd_addr   = '0;
        f_pop      = 1'b0;
        do_wdata   = 1'b0;
        act_from_n = 1'b0;

        case (state)
            // ---------------- initialisation ----------------
            S_INIT_PRE: begin
                cmd = C_PRE;  cmd_addr = '0;  cmd_addr[10] = 1'b1;  // all banks
            end
            S_INIT_REF: cmd = C_REF;
            S_INIT_MRS: begin
                cmd = C_MRS;  cmd_ba = '0;  cmd_addr = MODE_REG;
            end

            // ---------------- refresh ----------------
            S_REF_PRE: if (any_open && all_pre_ok) begin
                cmd = C_PRE;  cmd_addr = '0;  cmd_addr[10] = 1'b1;
            end
            S_REF_CMD: if (c_rfc == '0) cmd = C_REF;

            // ---------------- normal operation ----------------
            S_RUN: if (!ref_hold) begin
                if (!f_empty && h_ready) begin
                    // The row is open and the column command is legal: go.
                    cmd      = head.is_rd ? C_RD : C_WR;
                    cmd_ba   = h_bank;
                    cmd_addr = col_addr(head.col);
                    do_wdata = !head.is_rd;
                    f_pop    = 1'b1;
                end else if (!f_empty && !h_hit && row_open[h_bank]
                             && pre_ok_v[h_bank]) begin
                    // Wrong row in this bank - close it.
                    cmd      = C_PRE;
                    cmd_ba   = h_bank;
                    cmd_addr = '0;                  // A10 = 0: this bank only
                end else if (!f_empty && !h_hit && act_ok_v[h_bank]) begin
                    // Bank closed - open the row we need.
                    cmd      = C_ACT;
                    cmd_ba   = h_bank;
                    cmd_addr = SA_BITS'(h_row);
                end else if ((LOOKAHEAD != 0) && f_two && (n_bank != h_bank)) begin
                    // Nothing to do for the head this cycle. Prepare the one
                    // behind it: this is what turns a bank-to-bank walk from a
                    // series of stalls into a pipeline.
                    if (n_conflict && pre_ok_v[n_bank]) begin
                        cmd      = C_PRE;
                        cmd_ba   = n_bank;
                        cmd_addr = '0;
                    end else if (!n_hit && act_ok_v[n_bank]) begin
                        cmd        = C_ACT;
                        cmd_ba     = n_bank;
                        cmd_addr   = SA_BITS'(n_row);
                        act_from_n = 1'b1;   // this ACT carries n_row
                    end
                end
            end

            default: cmd = C_NOP;
        endcase
    end

    // =========================================================================
    // Command output registers
    // =========================================================================
    logic [DATA_BITS-1:0] dq_out;
    logic                 dq_oe;

    assign zs_dq = dq_oe ? dq_out : {DATA_BITS{1'bz}};

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            zs_cs_n  <= 1'b1;
            zs_ras_n <= 1'b1;
            zs_cas_n <= 1'b1;
            zs_we_n  <= 1'b1;
            zs_cke   <= 1'b0;
            zs_addr  <= '0;
            zs_ba    <= '0;
            zs_dqm   <= '1;
            dq_out   <= '0;
            dq_oe    <= 1'b0;
        end else begin
            zs_cke  <= 1'b1;
            zs_addr <= cmd_addr;
            zs_ba   <= cmd_ba;
            zs_cs_n <= 1'b0;

            // DQM masks write bytes and enables the read output. Held low
            // except where a write's byte enables say otherwise; SDR enables
            // the read output two cycles ahead, which low-always satisfies.
            zs_dqm  <= do_wdata ? head.be_n : '0;
            dq_out  <= head.wdata;
            dq_oe   <= do_wdata;

            case (cmd)
                C_ACT: begin zs_ras_n <= 1'b0; zs_cas_n <= 1'b1; zs_we_n <= 1'b1; end
                C_RD:  begin zs_ras_n <= 1'b1; zs_cas_n <= 1'b0; zs_we_n <= 1'b1; end
                C_WR:  begin zs_ras_n <= 1'b1; zs_cas_n <= 1'b0; zs_we_n <= 1'b0; end
                C_PRE: begin zs_ras_n <= 1'b0; zs_cas_n <= 1'b1; zs_we_n <= 1'b0; end
                C_REF: begin zs_ras_n <= 1'b0; zs_cas_n <= 1'b0; zs_we_n <= 1'b1; end
                C_MRS: begin zs_ras_n <= 1'b0; zs_cas_n <= 1'b0; zs_we_n <= 1'b0; end
                default: begin zs_ras_n <= 1'b1; zs_cas_n <= 1'b1; zs_we_n <= 1'b1; end
            endcase
        end
    end

    // =========================================================================
    // Bank state, timing counters, refresh accounting, sequencing
    // =========================================================================
    logic issue_act, issue_rd, issue_wr, issue_pre, issue_ref, issue_mrs;
    logic pre_all;

    assign issue_act = (cmd == C_ACT);
    assign issue_rd  = (cmd == C_RD);
    assign issue_wr  = (cmd == C_WR);
    assign issue_pre = (cmd == C_PRE);
    assign issue_ref = (cmd == C_REF);
    assign issue_mrs = (cmd == C_MRS);
    assign pre_all   = issue_pre && cmd_addr[10];

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state        <= S_RST;
            init_cnt     <= '0;
            init_ref_cnt <= '0;
            ref_timer    <= '0;
            ref_pend     <= '0;
            c_rrd        <= '0;
            c_rfc        <= '0;
            c_wtr        <= '0;
            for (int b = 0; b < BANKS; b++) begin
                row_open[b] <= 1'b0;
                open_row[b] <= '0;
                c_rcd[b]    <= '0;
                c_ras[b]    <= '0;
                c_rp [b]    <= '0;
                c_rc [b]    <= '0;
                c_wr [b]    <= '0;
            end
        end else begin
            // ---- timing counters tick down ----
            for (int b = 0; b < BANKS; b++) begin
                if (c_rcd[b] != '0) c_rcd[b] <= c_rcd[b] - 1'b1;
                if (c_ras[b] != '0) c_ras[b] <= c_ras[b] - 1'b1;
                if (c_rp [b] != '0) c_rp [b] <= c_rp [b] - 1'b1;
                if (c_rc [b] != '0) c_rc [b] <= c_rc [b] - 1'b1;
                if (c_wr [b] != '0) c_wr [b] <= c_wr [b] - 1'b1;
            end
            if (c_rrd != '0) c_rrd <= c_rrd - 1'b1;
            if (c_rfc != '0) c_rfc <= c_rfc - 1'b1;
            if (c_wtr != '0) c_wtr <= c_wtr - 1'b1;

            // ---- refresh timer ----
            // (CYC_REFI - 1) so the timer spans exactly CYC_REFI cycles:
            // counting 0..CYC_REFI inclusive is CYC_REFI+1 of them, which
            // stretched the interval past tREFI in the one direction that
            // loses data. Measured 783 cycles where the part allows 781.25.
            if (ref_timer >= 16'(CYC_REFI - 1)) begin
                ref_timer <= '0;
                if (ref_pend != 4'hF) ref_pend <= ref_pend + 1'b1;
            end else begin
                ref_timer <= ref_timer + 1'b1;
            end

            // ---- effects of the command actually issued ----
            if (issue_act) begin
                row_open[cmd_ba] <= 1'b1;
                open_row[cmd_ba] <= cmd_addr[ROW_BITS-1:0];
                c_rcd[cmd_ba]    <= TW'(gate(CYC_RCD));
                c_ras[cmd_ba]    <= TW'(gate(CYC_RAS));
                c_rc [cmd_ba]    <= TW'(gate(CYC_RC));
                c_rrd            <= TW'(gate(CYC_RRD));
            end
            if (issue_rd) begin
                c_wtr <= TW'(gate(CYC_WTR));
            end
            if (issue_wr) begin
                c_wr[cmd_ba] <= TW'(gate(CYC_WR));
            end
            if (issue_pre) begin
                for (int b = 0; b < BANKS; b++)
                    if (pre_all || (BANK_BITS'(b) == cmd_ba)) begin
                        row_open[b] <= 1'b0;
                        c_rp[b]     <= TW'(gate(CYC_RP));
                    end
            end
            if (issue_ref) c_rfc <= TW'(gate(CYC_RFC));
            // tMRD gates the next command; c_rfc is the global command gate.
            if (issue_mrs) c_rfc <= TW'(gate(CYC_MRD));

            // ---- sequencing ----
            case (state)
                S_RST: begin
                    init_cnt <= '0;
                    state    <= S_INIT_WAIT;
                end
                S_INIT_WAIT:
                    // The device needs a long quiet period with CKE high
                    // before any command is legal.
                    if (init_cnt >= 24'(CYC_INIT)) state    <= S_INIT_PRE;
                    else                           init_cnt <= init_cnt + 1'b1;

                S_INIT_PRE: state <= S_INIT_TRP;
                S_INIT_TRP: if (all_rp_done) begin
                    init_ref_cnt <= '0;
                    state        <= S_INIT_REF;
                end
                S_INIT_REF: begin
                    init_ref_cnt <= init_ref_cnt + 1'b1;
                    state        <= S_INIT_RFC;
                end
                S_INIT_RFC: if (c_rfc == '0)
                    state <= (init_ref_cnt >= 4'(INIT_REFS)) ? S_INIT_MRS
                                                             : S_INIT_REF;
                S_INIT_MRS: state <= S_INIT_MRD;
                S_INIT_MRD: if (c_rfc == '0) begin
                    ref_pend <= '0;
                    state    <= S_RUN;
                end

                S_RUN: if (ref_hold) state <= S_REF_PRE;

                S_REF_PRE: if (issue_pre || !any_open) state <= S_REF_TRP;
                S_REF_TRP: if (all_rp_done)             state <= S_REF_CMD;
                S_REF_CMD: if (issue_ref) begin
                    if (ref_pend != '0) ref_pend <= ref_pend - 1'b1;
                    state <= S_RUN;
                end

                default: state <= S_RST;
            endcase
        end
    end

    assign init_done = (state == S_RUN) || (state == S_REF_PRE)
                       || (state == S_REF_TRP) || (state == S_REF_CMD);

    // =========================================================================
    // Read return
    //
    // A READ decided in cycle k reaches the device on edge k+1, and the device
    // drives DQ for one cycle ending on edge k+1+CAS_LAT - so that is the edge
    // to capture on. Seeding the shift register at bit CAS_LAT does exactly
    // that: the marker reaches bit 0 during the interval the device is driving,
    // and the capture happens on the edge that closes it.
    //
    // The shift register carries only a "data is coming back" marker and stores
    // no address: SDRAM returns read data strictly in order, so the master's
    // own ordering is enough to know which access it belongs to.
    // =========================================================================
    logic [RD_PIPE_D:0] rd_pipe;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rd_pipe  <= '0;
            za_valid <= 1'b0;
            za_data  <= '0;
        end else begin
            rd_pipe  <= {1'b0, rd_pipe[RD_PIPE_D:1]} | (issue_rd ? RD_SEED : '0);
            za_valid <= rd_pipe[0];
            if (rd_pipe[0]) za_data <= zs_dq;
        end
    end

endmodule
