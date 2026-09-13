`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_drv_top.sv
//
// The hardware half of the driver-in-the-loop harness: the controller, a
// socket with TWO cards that can be swapped in and out of it, and - when the
// core is built with its DMA - a memory slave backed by the host process's own
// address space.
//
// Nothing here drives the core. There is no stimulus and no clock: both come
// from tb/driver/sim_main.cpp, which ticks this model once per CPU bus access
// on behalf of the REAL HAL driver, compiled from HAL/src unmodified. So what
// runs against the RTL is exactly the code a Nios II would run, and the only
// thing standing in for the processor is the bus.
//
// -----------------------------------------------------------------------------
// WHY TWO CARDS
// -----------------------------------------------------------------------------
// One card of each capacity class. Swapping a high-capacity card for a
// standard-capacity one changes the addressing unit from blocks to bytes, so a
// driver that failed to notice the change and kept its old identification
// reads and writes the wrong place - which a swap between two identical cards
// would never show. Each card keeps its flash across removal, so a test can
// swap away and back and find its data where it left it.
//
// -----------------------------------------------------------------------------
// THE MEMORY
// -----------------------------------------------------------------------------
// With the DMA, the driver hands the core a buffer POINTER, and the core's
// master reads and writes through it. The harness arranges for every pointer
// the driver can see to lie below 4 GiB - see sim_main.cpp - so the 32-bit
// address the master drives is the host address itself, and the DPI calls
// below dereference it directly. The Avalon side is still the real memory
// model, with its wait states and read latency.
// =============================================================================

module avalon_mm_sdcard_controller_drv_top #(
    parameter bit          USE_DMA         = 1'b0,
    parameter bit          USE_CARD_DETECT = 1'b1,
    parameter int unsigned FIFO_B          = 1024
) (
    input  logic        clk,
    input  logic        reset_n,

    input  logic [4:0]  csr_address,
    input  logic        csr_read,
    input  logic        csr_write,
    input  logic [31:0] csr_writedata,
    output logic [31:0] csr_readdata,
    output logic        irq,

    // 0: empty socket. 1: the SDHC card. 2: the SDSC card.
    input  logic [1:0]  card_sel,
    input  logic        wp,
    // Fault injection, applied to whichever card is in the socket:
    //   [0] no response    [1] R1 illegal    [2] R1 CRC      [3] read err token
    //   [4] bad data CRC   [5] write CRC err [6] write err    [7] busy forever
    input  logic [7:0]  inj,

    output int unsigned hc_cmds,
    output int unsigned sc_cmds,
    output int unsigned hc_faults,
    output int unsigned sc_faults,
    output int unsigned hc_blocks_wr,
    output int unsigned sc_blocks_wr,
    // Beats the DMA master completed, so a test can tell data that went
    // through the DMA from data that only looked as if it had.
    output int unsigned dma_beats
);

    localparam int unsigned BURST_W = 8;

    logic [31:0] m0_address;
    logic        m0_read, m0_write;
    logic [31:0] m0_writedata, m0_readdata;
    logic [3:0]  m0_byteenable;
    logic [BURST_W-1:0] m0_burstcount;
    logic        m0_waitrequest, m0_readdatavalid;
    logic [1:0]  m0_response;

    logic sd_clk, sd_mosi, sd_miso, sd_cs_n;
    logic miso_hc, miso_sc;

    int unsigned mem_wr_beats, mem_rd_beats;
    always_comb dma_beats = mem_wr_beats + mem_rd_beats;

    /* verilator lint_off UNUSEDSIGNAL */
    int unsigned hc_blocks_rd, sc_blocks_rd;
    logic [5:0]  hc_last_cmd, sc_last_cmd;
    logic        hc_last_crc, sc_last_crc, mem_zero_be;
    /* verilator lint_on UNUSEDSIGNAL */

    avalon_mm_sdcard_controller #(
        .FIFO_DEPTH_BYTES (FIFO_B),
        .M0_BURST_WIDTH   (BURST_W),
        .CSR_ADDR_WIDTH   (5),
        .ADDR_WIDTH       (32),
        .USE_DMA          (USE_DMA),
        .USE_CARD_DETECT  (USE_CARD_DETECT)
    ) dut (
        .clk (clk), .reset_n (reset_n),
        .csr_address (csr_address), .csr_read (csr_read), .csr_write (csr_write),
        .csr_writedata (csr_writedata), .csr_byteenable (4'hF),
        .csr_readdata (csr_readdata), .irq (irq),
        .m0_address (m0_address), .m0_read (m0_read), .m0_write (m0_write),
        .m0_writedata (m0_writedata), .m0_byteenable (m0_byteenable),
        .m0_burstcount (m0_burstcount), .m0_waitrequest (m0_waitrequest),
        .m0_readdata (m0_readdata), .m0_readdatavalid (m0_readdatavalid),
        .m0_response (m0_response),
        .sd_clk (sd_clk), .sd_mosi (sd_mosi), .sd_miso (sd_miso),
        .sd_cs_n (sd_cs_n),
        // The switch closes when a card is fitted. With USE_CARD_DETECT off the
        // pin is not looked at, which is the no-switch socket being modelled.
        .sd_cd_n (card_sel == 2'd0), .sd_wp_n (!wp)
    );

    avalon_mm_mem_model #(
        .ADDR_WIDTH (32), .BURST_WIDTH (BURST_W),
        .MAX_WAIT (1), .READ_LATENCY (2)
    ) u_mem (
        .clk (clk), .reset_n (reset_n),
        .address (m0_address), .read (m0_read), .write (m0_write),
        .writedata (m0_writedata), .byteenable (m0_byteenable),
        .burstcount (m0_burstcount), .waitrequest (m0_waitrequest),
        .readdata (m0_readdata), .readdatavalid (m0_readdatavalid),
        .response (m0_response),
        .wr_beats (mem_wr_beats), .rd_beats (mem_rd_beats),
        .saw_zero_byteenable_read (mem_zero_be)
    );

    // An empty socket floats MISO to its pull-up.
    always_comb sd_miso = (card_sel == 2'd1) ? miso_hc :
                          (card_sel == 2'd2) ? miso_sc : 1'b1;

    // The two cards differ in every way a driver has to notice: capacity class
    // and addressing, response latency, how long ACMD41 takes, and CID. The
    // standard-capacity card answers at N_CR = 8 byte-times, the most the
    // specification allows, so identification and every transfer run at the
    // edge of the response window the core opens.
    spi_card_model #(.HIGH_CAPACITY (1'b1), .NCR_BYTES (2), .ACMD41_POLLS (3),
                     .CID_SERIAL (32'h4843_0001)) u_card_hc (
        .sd_clk (sd_clk), .sd_cs_n (sd_cs_n), .sd_mosi (sd_mosi),
        .sd_miso (miso_hc), .inserted (card_sel == 2'd1),
        .inj_no_response (inj[0]), .inj_r1_illegal (inj[1]),
        .inj_r1_crc (inj[2]), .inj_read_err_token (inj[3]),
        .inj_bad_data_crc (inj[4]), .inj_write_crc_err (inj[5]),
        .inj_write_err (inj[6]), .inj_busy_forever (inj[7]),
        .cmds_seen (hc_cmds), .blocks_read (hc_blocks_rd),
        .blocks_written (hc_blocks_wr), .last_cmd (hc_last_cmd),
        .last_cmd_crc_ok (hc_last_crc), .faults_applied (hc_faults)
    );

    spi_card_model #(.HIGH_CAPACITY (1'b0), .NCR_BYTES (8), .ACMD41_POLLS (5),
                     .CID_SERIAL (32'h5343_0002)) u_card_sc (
        .sd_clk (sd_clk), .sd_cs_n (sd_cs_n), .sd_mosi (sd_mosi),
        .sd_miso (miso_sc), .inserted (card_sel == 2'd2),
        .inj_no_response (inj[0]), .inj_r1_illegal (inj[1]),
        .inj_r1_crc (inj[2]), .inj_read_err_token (inj[3]),
        .inj_bad_data_crc (inj[4]), .inj_write_crc_err (inj[5]),
        .inj_write_err (inj[6]), .inj_busy_forever (inj[7]),
        .cmds_seen (sc_cmds), .blocks_read (sc_blocks_rd),
        .blocks_written (sc_blocks_wr), .last_cmd (sc_last_cmd),
        .last_cmd_crc_ok (sc_last_crc), .faults_applied (sc_faults)
    );

    // ---- backdoor into the cards' flash, for checking what a write did -----
    //
    // Byte addressed on both cards, whatever their command addressing, so a
    // test states where a block must have landed independently of the
    // conversion it is testing.
    export "DPI-C" function drv_card_peek;
    export "DPI-C" function drv_card_poke;
    export "DPI-C" function drv_card_busy;
    export "DPI-C" function drv_card_set_prog;

    function automatic int unsigned drv_card_peek(input int unsigned which,
                                                  input int unsigned addr);
        return (which == 2) ? 32'(u_card_sc.peek(addr)) : 32'(u_card_hc.peek(addr));
    endfunction

    function automatic void drv_card_poke(input int unsigned which,
                                          input int unsigned addr,
                                          input int unsigned data);
        if (which == 2) u_card_sc.preload(addr, data[7:0]);
        else            u_card_hc.preload(addr, data[7:0]);
    endfunction

    // Still programming a block? Busy is internal to a card - it only shows on
    // MISO while the host clocks it - so a test that needs to know whether a
    // sync really waited for it asks the model directly.
    function automatic int unsigned drv_card_busy(input int unsigned which);
        return (which == 2) ? 32'(u_card_sc.busy_bytes != 0)
                            : 32'(u_card_hc.busy_bytes != 0);
    endfunction

    // The card's programming time after each written block, in byte-times.
    function automatic void drv_card_set_prog(input int unsigned which,
                                              input int unsigned n);
        if (which == 2) u_card_sc.prog_bytes = n;
        else            u_card_hc.prog_bytes = n;
    endfunction

endmodule : avalon_mm_sdcard_controller_drv_top
