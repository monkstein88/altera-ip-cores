`timescale 1ns/1ps
// =============================================================================
// avalon_mm_sdram_controller_sva.sv
//
// SystemVerilog assertions and cover points, bound into
// avalon_mm_sdram_controller by tb/avalon_mm_sdram_controller_tb.sv. Not part
// of the synthesisable RTL.
//
// WHAT THIS DOES *NOT* COVER, DELIBERATELY
// ----------------------------------------
// JEDEC device timing - tRC, tRAS, tRP, tRCD, tRRD, tWR, tMRD. That is
// sdram_timing_check.sv's job, it is bound to the same command bus, and it has
// its own threshold self-test. Duplicating it here would mean two encodings of
// the same arithmetic, which is exactly how this project shipped the same
// rounding bug twice.
//
// So the properties here are the ones the timing checker cannot see:
//
//   AVALON    - the slave must obey Avalon-MM. A memory that returns the right
//               data through an illegal handshake still hangs the master that
//               is talking to it, and the benchmark's integrity check cannot
//               tell the difference.
//   DEVICE    - the command stream must be structurally legal and the DQ bus
//               must never be driven by both ends at once. Bus contention does
//               not show up in a functional model: the model simply stops
//               driving, and the controller reads back what it drove itself.
//   INTERNAL  - the controller's own bookkeeping must match what it actually
//               issued. row_open[] is the design's central claim; if it ever
//               disagrees with the commands on the wire, every access after it
//               lands in the wrong place, silently.
//
// READ THE PASS COUNTS, NOT JUST THE FAILURE COUNTS. A property that only ever
// passes vacuously has verified nothing while looking green. Questa reports
// non-vacuous pass counts per property, which is what run_sim.tcl collects.
// =============================================================================

module avalon_mm_sdram_controller_sva #(
    parameter int DATA_BITS = 16,
    parameter int ROW_BITS  = 13,
    parameter int BANK_BITS = 2,
    parameter int SA_BITS   = 13,
    parameter int ADDR_W    = 25,
    parameter int CAS_LAT   = 3,
    // The controller's turnaround is CAS_LAT + RD_EXTRA_LAT + 1 +
    // WR_TURNAROUND_EXTRA. The DEVICE's minimum is CAS_LAT + 1 and nothing
    // more, so the two properties below are deliberately different bounds:
    // a_no_write_into_read_data holds the command stream to what the part
    // permits, and a_capture_before_drive holds the controller to what its own
    // read pipeline needs. Collapsing them into one number is how the second
    // one came to be missing.
    parameter int RD_EXTRA_LAT = 0,
    parameter int WR_TURNAROUND_EXTRA = 0,
    parameter int FIFO_DEPTH = 8,
    // The JEDEC postponement allowance, so the bound below tracks the
    // controller's configuration instead of a magic number that happens to
    // match today's default.
    parameter int REF_MAX_PEND = 8
) (
    input logic                    clk,
    input logic                    reset_n,

    // Avalon-MM slave
    input logic [ADDR_W-1:0]       az_addr,
    input logic                    az_cs,
    input logic                    az_rd_n,
    input logic                    az_wr_n,
    input logic                    za_valid,
    input logic                    za_waitrequest,

    // SDRAM command bus
    input logic [SA_BITS-1:0]      zs_addr,
    input logic [BANK_BITS-1:0]    zs_ba,
    input logic                    zs_cas_n,
    input logic                    zs_cke,
    input logic                    zs_cs_n,
    input logic                    zs_ras_n,
    input logic                    zs_we_n,

    // controller internals, for the bookkeeping properties
    input logic                    dq_oe,
    // rd_pipe[0]: this cycle's DQ value is the one the read-return path will
    // latch at the end of it.
    input logic                    rd_capture,
    input logic [3:0]              ref_pend,
    input logic                    init_done,

    // The controller's own row bookkeeping, passed in by the bind. A module
    // bound into a DUT sees only its own ports, so these cannot be reached by
    // hierarchical reference from in here.
    input logic                    row_open [1<<BANK_BITS],
    input logic [ROW_BITS-1:0]     open_row [1<<BANK_BITS]
);

    localparam int BANKS = 1 << BANK_BITS;

    default clocking cb @(posedge clk); endclocking
    default disable iff (!reset_n);

    // ---- command decode ---------------------------------------------------
    logic sel, c_act, c_rd, c_wr, c_pre, c_ref, c_mrs, c_pre_all, c_col;
    assign sel       = zs_cke && !zs_cs_n;
    assign c_act     = sel && !zs_ras_n &&  zs_cas_n &&  zs_we_n;
    assign c_rd      = sel &&  zs_ras_n && !zs_cas_n &&  zs_we_n;
    assign c_wr      = sel &&  zs_ras_n && !zs_cas_n && !zs_we_n;
    assign c_pre     = sel && !zs_ras_n &&  zs_cas_n && !zs_we_n;
    assign c_ref     = sel && !zs_ras_n && !zs_cas_n &&  zs_we_n;
    assign c_mrs     = sel && !zs_ras_n && !zs_cas_n && !zs_we_n;
    assign c_pre_all = c_pre && zs_addr[10];
    assign c_col     = c_rd || c_wr;

    // Independent shadow of the device's row state, rebuilt from the wire
    // rather than read out of the controller. A property comparing the
    // controller's row_open[] against itself would prove nothing.
    logic                open_sh [BANKS];
    logic [ROW_BITS-1:0] row_sh  [BANKS];
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (int b = 0; b < BANKS; b++) begin
                open_sh[b] <= 1'b0;
                row_sh[b]  <= '0;
            end
        end else begin
            if (c_act) begin
                open_sh[zs_ba] <= 1'b1;
                row_sh[zs_ba]  <= zs_addr[ROW_BITS-1:0];
            end
            if (c_pre)
                for (int b = 0; b < BANKS; b++)
                    if (c_pre_all || (BANK_BITS'(b) == zs_ba)) open_sh[b] <= 1'b0;
        end
    end

    logic any_open_sh;
    always_comb begin
        any_open_sh = 1'b0;
        for (int b = 0; b < BANKS; b++) if (open_sh[b]) any_open_sh = 1'b1;
    end

    // Reads owed to the master: incremented when a READ goes to the device,
    // decremented when readdatavalid comes back.
    int unsigned rd_owed;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)                     rd_owed <= 0;
        else if (c_rd && !za_valid)       rd_owed <= rd_owed + 1;
        else if (!c_rd && za_valid)       rd_owed <= rd_owed - 1;
    end

    // =====================================================================
    // AVALON - the slave has to be usable, not merely correct
    // =====================================================================

    // A command is accepted when chipselect is asserted and waitrequest is
    // low. Nothing may be accepted before the device is initialised, or the
    // access goes to a part that has not had its mode register written.
    a_no_accept_before_init: assert property
        (!init_done |-> za_waitrequest);

    // chipselect with neither read nor write is meaningless; the controller
    // must not invent a transfer from it.
    a_cs_has_direction: assert property
        (az_cs && !za_waitrequest |-> (!az_rd_n ^ !az_wr_n));

    // readdatavalid may only appear for a read that was actually issued to the
    // device. An extra one desynchronises every subsequent transfer at the
    // master, which is the classic way a memory controller corrupts a system
    // while returning perfectly good data.
    a_rdv_is_owed: assert property (za_valid |-> rd_owed > 0);

    // Every read issued to the device must come back, and keep coming back.
    //
    // Written as a progress counter rather than `c_rd |-> ##[1:N] za_valid`.
    // The ranged-delay form is the obvious way to say it and is not portable.
    // Under Verilator it reports a failure on the cycle after the READ, long
    // before the data is due, so a correct design fails it. A counter means
    // the same thing, is checked identically by every tool, and reports the
    // stall length when it does fire.
    // (A comment line may not begin with that simulator's name - it is read
    //  as a pragma - which is why this paragraph is worded around it.)
    //
    // The measure is cycles since the last read data WHILE reads are
    // outstanding, so a stream returning a word every cycle never trips it and
    // a controller that stops answering trips it immediately.
    int unsigned rd_age;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)                     rd_age <= 0;
        else if (za_valid || rd_owed == 0) rd_age <= 0;
        else                              rd_age <= rd_age + 1;
    end

    a_read_returns: assert property
        ((rd_owed > 0) |-> (rd_age <= CAS_LAT + 4));

    // =====================================================================
    // DEVICE - the command stream must be structurally legal
    // =====================================================================

    // A column command to a bank with no open row reads or writes whichever
    // row happened to be open last. The functional model will answer it, so
    // only an assertion catches this.
    a_col_needs_open_row: assert property
        (c_col |-> open_sh[zs_ba]);

    // ACTIVATE on a bank that is already open loses the first row's contents
    // on a real device.
    a_act_needs_closed_bank: assert property
        (c_act |-> !open_sh[zs_ba]);

    // AUTO REFRESH requires every bank precharged.
    a_refresh_all_precharged: assert property
        (c_ref |-> !any_open_sh);

    // A10 must be low on a column command: it is the auto-precharge flag, and
    // this controller manages precharge explicitly. Setting it by accident
    // closes the row behind the scheduler's back.
    a_no_auto_precharge: assert property
        (c_col |-> !zs_addr[10]);

    // The mode register must be written before any row is opened, or the
    // device's CAS latency and burst length are whatever power-up left them.
    logic mrs_done;
    always_ff @(posedge clk or negedge reset_n)
        if (!reset_n)     mrs_done <= 1'b0;
        else if (c_mrs)   mrs_done <= 1'b1;

    a_mrs_before_first_act: assert property (c_act |-> mrs_done);

    // The controller may only drive DQ on the cycle it issues a WRITE. Driving
    // it at any other time risks contention with the device's read data, which
    // a functional model cannot show: the model stops driving and the
    // controller reads back its own value.
    a_dq_driven_only_for_write: assert property
        (dq_oe |-> c_wr);

    // A write may not be issued while the device could still be driving read
    // data. CAS_LAT+1 is the datasheet's read-to-write turnaround for a
    // length-1 burst; anything shorter is bus contention on silicon.
    //
    // This is the DEVICE's bound, so it stays at CAS_LAT whatever the
    // controller's own turnaround is set to. A controller that waits longer
    // than the part requires is slow, not illegal, and this property should
    // not be the thing that notices.
    a_no_write_into_read_data: assert property
        (c_rd |=> !c_wr [* CAS_LAT]);

    // The controller may not drive DQ on a cycle whose value it is about to
    // latch as read data. Nothing else says this: a_no_write_into_read_data
    // holds the WIRE to the part's minimum, and is satisfied by a controller
    // that nevertheless clobbers its own read.
    //
    // That is not hypothetical. CYC_WTR was CAS_LAT+1 while the capture point
    // was CAS_LAT+RD_EXTRA_LAT, so with RD_EXTRA_LAT non-zero the DQ drivers
    // came on one cycle before the latch and every read returned the next
    // word, or Hi-Z. The command stream was legal throughout, the timing
    // checker saw nothing, and this property is the one that fires.
    a_capture_before_drive: assert property
        (rd_capture |-> !dq_oe);

    // CKE is held high once the controller is running - this design never
    // uses clock suspend or power-down.
    a_cke_stable: assert property
        (init_done |-> zs_cke);

    // =====================================================================
    // INTERNAL - the bookkeeping must match the wire
    // =====================================================================

    // The design's central claim. If the controller's idea of which row is
    // open ever disagrees with the commands it has actually issued, every
    // access after that point lands somewhere else.
    genvar gb;
    generate
        for (gb = 0; gb < BANKS; gb++) begin : g_row
            // Compared one cycle late, deliberately. The controller's SDRAM
            // outputs are registered, so it updates row_open[] on the cycle it
            // DECIDES to activate and the device sees the ACTIVATE a cycle
            // later. The bookkeeping therefore leads the wire by exactly one
            // cycle, always, by construction - which is itself worth pinning
            // down: if the offset were ever anything other than one, the
            // controller's timing gates would be counting from the wrong
            // event.
            a_row_state_matches: assert property
                (init_done |-> ($past(row_open[gb]) == open_sh[gb]));
            a_open_row_matches: assert property
                ((init_done && open_sh[gb]) |-> ($past(open_row[gb]) == row_sh[gb]));
        end
    endgenerate

    // Postponed refreshes must stay inside the JEDEC allowance.
    a_ref_pend_bounded: assert property (ref_pend <= 4'(REF_MAX_PEND));

    // Exactly one command per cycle. The encoding makes this structural, but
    // an accidental multi-driver on the command pins would show up here.
    a_one_command: assert property
        ($countones({c_act, c_rd, c_wr, c_pre, c_ref, c_mrs}) <= 1);

    // =====================================================================
    // COVER - the states worth knowing were actually reached
    // =====================================================================

    // The feature the core exists for: a read and a write in the same open
    // row, with no row command between them.
    c_write_then_read: cover property (c_wr ##1 c_rd);
    c_read_then_write: cover property (c_rd ##[1:8] c_wr);

    // More than one bank open at once - the other half of the design.
    c_two_banks_open: cover property
        (init_done && (open_sh[0] && open_sh[1]));
    c_all_banks_open: cover property
        (init_done && open_sh[0] && open_sh[1] && open_sh[2] && open_sh[3]);

    // A row actually changed within a bank, so the precharge path ran.
    c_row_change: cover property ((c_pre && !c_pre_all) ##[1:16] c_act);

    // Refresh was postponed rather than taken immediately.
    c_refresh_postponed: cover property (ref_pend >= 4'd2);
    c_refresh_forced:    cover property (ref_pend >= 4'd8);

    // The master was made to wait, so the backpressure path ran.
    c_master_stalled: cover property (init_done && az_cs && za_waitrequest);

    // Back-to-back column commands - the streaming case.
    c_back_to_back_col: cover property (c_col ##1 c_col);

endmodule
