`timescale 1ns/1ps
// =============================================================================
// avalon_mm_sdram_controller.sv
//
// An SDR SDRAM controller for Avalon-MM, with per-bank open-row tracking.
//
// WHAT THIS DOES DIFFERENTLY
// --------------------------
// The controller this replaces tracks ONE open row and requires the access
// direction to match for its fast path:
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
// PARAMETERISED IN NANOSECONDS
// ----------------------------
// Every device timing is a real number of nanoseconds, converted to cycles
// here with ceiling division and never allowed below one cycle. Cycle counts
// are deliberately NOT exposed: a timing parameter rounded the wrong way is
// silent data corruption at temperature months later, not a clean failure, and
// pushing that arithmetic onto the integrator guarantees someone gets it
// wrong. Retarget by changing ns and the clock, not by recomputing cycles.
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

    // ---- device timings, nanoseconds ----
    parameter real T_RC_NS     = 60.0,  // ACT -> ACT, same bank
    parameter real T_RAS_NS    = 37.0,  // ACT -> PRE, same bank
    parameter real T_RP_NS     = 15.0,  // PRE -> ACT, same bank
    parameter real T_RCD_NS    = 15.0,  // ACT -> READ/WRITE, same bank
    parameter real T_RRD_NS    = 14.0,  // ACT -> ACT, different bank
    parameter real T_WR_NS     = 14.0,  // last write data -> PRE
    parameter real T_MRD_NS    = 14.0,  // LOAD MODE -> any command
    parameter real T_RFC_NS    = 60.0,  // REFRESH -> ACT/REFRESH
    parameter real T_INIT_US   = 100.0, // power-on NOP wait
    parameter int  CAS_LAT     = 3,
    parameter int  INIT_REFS   = 8,     // refreshes during initialisation

    // ---- refresh ----
    parameter int  REF_ROWS      = 8192,
    parameter real REF_PERIOD_MS = 64.0,
    // JEDEC permits refreshes to be postponed and issued as a burst. Holding
    // some back lets a streaming burst finish instead of being cut in half.
    parameter int  REF_MAX_PEND  = 8,

    // ---- clock ----
    parameter int  CLK_KHZ     = 100_000,

    // ---- controller options ----
    // ADDR_MAP 0: bank[0] directly above the column, remaining bank bits at
    //             the top - the map the incumbent uses. Interleaves banks
    //             every 2^COL_BITS words, which suits streaming.
    // ADDR_MAP 1: {row, bank, col}, bank bits contiguous.
    parameter int  ADDR_MAP    = 0,
    parameter int  FIFO_DEPTH  = 8,     // buffered commands, power of two
    parameter bit  LOOKAHEAD   = 1,     // open/close the NEXT access's row early

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
    // ns -> cycles.  Always rounds UP, never below 1.
    // =========================================================================
    // NOTE: the familiar `int'((ns*khz + 999_999)/1_000_000)` ceiling is wrong
    // in SystemVerilog. `int'(real)` rounds to NEAREST (IEEE 1800-2017 6.24.1),
    // so the bias and the rounding compound and a whole extra cycle appears
    // whenever the quotient is an integer - tRC 60 ns at 100 MHz became 7
    // cycles instead of 6. Conservative, but it costs a cycle on every row
    // cycle, and it is not what the parameter says.
    function automatic int unsigned cyc(input real ns);
        real c;
        c = $ceil((ns * real'(CLK_KHZ)) / 1_000_000.0 - 1.0e-9);
        return (c < 1.0) ? 1 : int'(c);
    endfunction

    // Counters are loaded with (cycles - 1) because the command outputs are
    // registered: see the header. `gate` is the only place that -1 appears.
    function automatic int unsigned gate(input int unsigned c);
        return (c <= 1) ? 0 : c - 1;
    endfunction

    localparam int unsigned CYC_RC   = cyc(T_RC_NS);
    localparam int unsigned CYC_RAS  = cyc(T_RAS_NS);
    localparam int unsigned CYC_RP   = cyc(T_RP_NS);
    localparam int unsigned CYC_RCD  = cyc(T_RCD_NS);
    localparam int unsigned CYC_RRD  = cyc(T_RRD_NS);
    localparam int unsigned CYC_WR   = cyc(T_WR_NS);
    localparam int unsigned CYC_MRD  = cyc(T_MRD_NS);
    localparam int unsigned CYC_RFC  = cyc(T_RFC_NS);
    localparam int unsigned CYC_INIT = cyc(T_INIT_US * 1000.0);
    // Average interval between AUTO REFRESH commands.
    localparam int unsigned CYC_REFI =
        cyc((REF_PERIOD_MS * 1_000_000.0) / real'(REF_ROWS));

    // Bus turnaround. A READ issued at T has the device driving DQ at T+CAS.
    // A WRITE drives DQ in its own cycle, so the earliest safe write is
    // T+CAS+1. The other direction is free - the datasheet allows write data
    // to be immediately followed by a READ command.
    localparam int unsigned CYC_WTR = CAS_LAT + 1;
    // READ -> PRECHARGE of the same bank. For a length-1 burst the array
    // access has already happened, so one cycle is enough.
    localparam int unsigned CYC_RDP = 1;

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

    typedef struct packed {
        logic                   is_rd;
        logic [ADDR_W-1:0]      addr;
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

    req_t              head;
    logic [ADDR_W-1:0] nxt_addr;      // look-ahead needs the address, nothing else
    assign head     = fifo[rptr[FAW-1:0]];
    assign nxt_addr = fifo[rptr[FAW-1:0] + 1'b1].addr;

    // A full FIFO does not stall the master if it is also popping this cycle;
    // without that, a 1-in/1-out steady state would stall every other cycle
    // and halve throughput. `f_pop` depends on the FIFO head and the bank
    // state, never on `f_push`, so there is no combinational loop.
    assign f_push         = az_cs && (!az_rd_n || !az_wr_n) && !za_waitrequest;
    assign za_waitrequest = !init_done || (f_full && !f_pop);

    initial begin
        for (int i = 0; i < FIFO_DEPTH; i++) fifo[i] = '0;
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wptr <= '0;
            rptr <= '0;
        end else begin
            if (f_push) begin
                fifo[wptr[FAW-1:0]] <= '{is_rd: !az_rd_n,
                                         addr:  az_addr,
                                         wdata: az_data,
                                         be_n:  az_be_n};
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
    logic [TW-1:0] c_rdp [BANKS];   // until PRE allowed after a read
    logic [TW-1:0] c_rrd;           // until any ACT allowed (tRRD)
    logic [TW-1:0] c_rfc;           // until any ACT/REF allowed (tRFC, tMRD)
    logic [TW-1:0] c_wtr;           // until a WRITE may follow a READ

    // A bank may be activated when it is closed and tRP, tRC, tRRD and tRFC
    // all permit it.
    function automatic logic act_ok(input logic [BANK_BITS-1:0] b);
        return !row_open[b] && (c_rp[b] == '0) && (c_rc[b] == '0)
               && (c_rrd == '0) && (c_rfc == '0);
    endfunction

    // A bank may be precharged when the row has been open for tRAS, any write
    // data has settled for tWR, and any read has left the array.
    function automatic logic pre_ok(input logic [BANK_BITS-1:0] b);
        return row_open[b] && (c_ras[b] == '0) && (c_wr[b] == '0)
               && (c_rdp[b] == '0);
    endfunction

    logic any_open, all_pre_ok, all_rp_done;

    always_comb begin
        any_open    = 1'b0;
        all_pre_ok  = 1'b1;
        all_rp_done = 1'b1;
        for (int b = 0; b < BANKS; b++) begin
            if (row_open[b]) begin
                any_open = 1'b1;
                if (!pre_ok(BANK_BITS'(b))) all_pre_ok = 1'b0;
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

    assign h_bank = bank_of(head.addr);
    assign h_row  = row_of(head.addr);
    assign n_bank = bank_of(nxt_addr);
    assign n_row  = row_of(nxt_addr);

    assign h_hit  = row_open[h_bank] && (open_row[h_bank] == h_row);
    assign n_hit  = row_open[n_bank] && (open_row[n_bank] == n_row);
    // The next access wants a different row in a bank that is already open.
    assign n_conflict = row_open[n_bank] && (open_row[n_bank] != n_row);

    // Reads never wait on turnaround; writes wait for the read bus to clear.
    assign h_ready = h_hit && (c_rcd[h_bank] == '0)
                     && (head.is_rd || (c_wtr == '0));

    always_comb begin
        cmd      = C_NOP;
        cmd_ba   = h_bank;
        cmd_addr = '0;
        f_pop    = 1'b0;
        do_wdata = 1'b0;

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
                    cmd_addr = col_addr(head.addr[COL_BITS-1:0]);
                    do_wdata = !head.is_rd;
                    f_pop    = 1'b1;
                end else if (!f_empty && !h_hit && row_open[h_bank]
                             && pre_ok(h_bank)) begin
                    // Wrong row in this bank - close it.
                    cmd      = C_PRE;
                    cmd_ba   = h_bank;
                    cmd_addr = '0;                  // A10 = 0: this bank only
                end else if (!f_empty && !h_hit && act_ok(h_bank)) begin
                    // Bank closed - open the row we need.
                    cmd      = C_ACT;
                    cmd_ba   = h_bank;
                    cmd_addr = SA_BITS'(h_row);
                end else if (LOOKAHEAD && f_two && (n_bank != h_bank)) begin
                    // Nothing to do for the head this cycle. Prepare the one
                    // behind it: this is what turns a bank-to-bank walk from a
                    // series of stalls into a pipeline.
                    if (n_conflict && pre_ok(n_bank)) begin
                        cmd      = C_PRE;
                        cmd_ba   = n_bank;
                        cmd_addr = '0;
                    end else if (!n_hit && act_ok(n_bank)) begin
                        cmd      = C_ACT;
                        cmd_ba   = n_bank;
                        cmd_addr = SA_BITS'(n_row);
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
                c_rdp[b]    <= '0;
            end
        end else begin
            // ---- timing counters tick down ----
            for (int b = 0; b < BANKS; b++) begin
                if (c_rcd[b] != '0) c_rcd[b] <= c_rcd[b] - 1'b1;
                if (c_ras[b] != '0) c_ras[b] <= c_ras[b] - 1'b1;
                if (c_rp [b] != '0) c_rp [b] <= c_rp [b] - 1'b1;
                if (c_rc [b] != '0) c_rc [b] <= c_rc [b] - 1'b1;
                if (c_wr [b] != '0) c_wr [b] <= c_wr [b] - 1'b1;
                if (c_rdp[b] != '0) c_rdp[b] <= c_rdp[b] - 1'b1;
            end
            if (c_rrd != '0) c_rrd <= c_rrd - 1'b1;
            if (c_rfc != '0) c_rfc <= c_rfc - 1'b1;
            if (c_wtr != '0) c_wtr <= c_wtr - 1'b1;

            // ---- refresh timer ----
            if (ref_timer >= 16'(CYC_REFI)) begin
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
                c_rdp[cmd_ba] <= TW'(gate(CYC_RDP));
                c_wtr         <= TW'(gate(CYC_WTR));
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
