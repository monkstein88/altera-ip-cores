`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller.sv
//
// Avalon-MM SD Card Controller, SPI mode. Top level.
//
//   csr  : Avalon-MM SLAVE  - word-addressed, 32-bit, fixed read latency 1,
//          never asserts waitrequest. All control and status.
//   m0   : Avalon-MM MASTER - block data to and from system memory. Present
//          only when USE_DMA.
//   irq  : level interrupt, asserted while any enabled sticky bit in
//          IRQ_STATUS is set. Write 1 to that bit to clear.
//   sd   : conduit to the card. Every signal unidirectional - SPI mode needs
//          no tristates at all, which is one of its few genuine advantages
//          over native mode.
//
// -----------------------------------------------------------------------------
// THE ORGANISING PRINCIPLE: THE SHIFTER MUST NEVER STALL
// -----------------------------------------------------------------------------
// SPI mode gives roughly 3.1 MB/s at 25 MHz and nothing moves that ceiling.
// What is in this design's gift is how much of it is actually reached, and the
// gap between a careless implementation and a careful one is large - typical
// software-driven SPI SD drivers manage 30-60% of line rate.
//
// Every structural decision below serves that one goal:
//
//   spi_phy   shifts with no idle clock between bytes         (8.00 clocks/byte)
//   seq       streams multi-block transfers in hardware, so
//             the card's access latency is paid once per
//             transfer instead of once per block
//   seq       polls write-busy in hardware, PRE-EMPTIVELY -
//             before the next packet rather than after the
//             previous one, overlapping the card's
//             programming time with the host's preparation
//   crc       computed during the shift, never as a second pass
//   fifo+dma  decouple the byte stream from memory, so the
//             shifter never waits for the CPU
//
// -----------------------------------------------------------------------------
// WHAT IS HARDWARE AND WHAT IS NOT
// -----------------------------------------------------------------------------
// This core is the SPI LINK LAYER: framing, CRC, tokens, timing, the data path.
// It is not the card protocol. The identification sequence, OCR/CID/CSD
// parsing, capacity and addressing mode, and the choice of which command to
// send all live in the HAL driver, because that is where every SD
// implementation accumulates its card-specific workarounds - and a workaround
// in a driver is a recompile, not a new bitstream.
// =============================================================================

module avalon_mm_sdcard_controller
    import avalon_mm_sdcard_controller_pkg::*;
#(
    parameter int unsigned FIFO_DEPTH_BYTES = 1024,
    parameter int unsigned M0_BURST_WIDTH   = 8,
    parameter int unsigned CLKDIV_WIDTH     = 8,
    parameter int unsigned TIMEOUT_WIDTH    = 26,
    parameter int unsigned MAX_BLOCK_BYTES  = 512,
    parameter int unsigned CSR_ADDR_WIDTH   = 5,
    parameter int unsigned ADDR_WIDTH       = 32,
    parameter bit          USE_DMA          = 1'b1,
    parameter bit          USE_CARD_DETECT  = 1'b1,
    parameter bit          USE_CRC          = 1'b1
) (
    input  logic                        clk,
    input  logic                        reset_n,

    // ---- csr : Avalon-MM slave --------------------------------------------
    input  logic [CSR_ADDR_WIDTH-1:0]   csr_address,
    input  logic                        csr_read,
    input  logic                        csr_write,
    input  logic [31:0]                 csr_writedata,
    input  logic [3:0]                  csr_byteenable,
    output logic [31:0]                 csr_readdata,

    // ---- irq ---------------------------------------------------------------
    output logic                        irq,

    // ---- m0 : Avalon-MM master ---------------------------------------------
    //
    // Present only when USE_DMA. The port list is fixed - SystemVerilog has no
    // way to remove ports on a parameter - so with USE_DMA off the outputs are
    // driven inactive and the inputs are genuinely unused. The _hw.tcl
    // elaboration callback is what removes m0 from the Platform Designer
    // component, so Qsys never asks you to wire a port that does nothing. That
    // is the same mechanism the firewall core uses to gate its response
    // signals.
    output logic [ADDR_WIDTH-1:0]       m0_address,
    output logic                        m0_read,
    output logic                        m0_write,
    output logic [31:0]                 m0_writedata,
    output logic [3:0]                  m0_byteenable,
    output logic [M0_BURST_WIDTH-1:0]   m0_burstcount,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic                        m0_waitrequest,
    input  logic [31:0]                 m0_readdata,
    input  logic                        m0_readdatavalid,
    input  logic [1:0]                  m0_response,
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- sd : conduit ------------------------------------------------------
    output logic                        sd_clk,
    output logic                        sd_mosi,
    input  logic                        sd_miso,
    output logic                        sd_cs_n,
    input  logic                        sd_cd_n,
    input  logic                        sd_wp_n
);

    localparam int unsigned BCW          = $clog2(MAX_BLOCK_BYTES + 1);
    localparam int unsigned BLKCNT_WIDTH = 16;

    // ---- configuration from the CSR ----------------------------------------
    logic                      cfg_enable, cfg_cs_manual, cfg_cs_value;
    logic                      cfg_crc_en, cfg_dma_en, cfg_clk_run;
    logic                      srst_cmd, srst_dat;
    logic [CLKDIV_WIDTH-1:0]   cfg_clkdiv;
    logic [2:0]                cfg_sample_dly;
    logic [TIMEOUT_WIDTH-1:0]  cfg_timeout;
    logic [BCW-1:0]            cfg_blk_size;
    logic [BLKCNT_WIDTH-1:0]   cfg_blk_count;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [ADDR_WIDTH-1:0]     cfg_dma_addr;   // consumed only when USE_DMA
    /* verilator lint_on UNUSEDSIGNAL */

    logic        cmd_start, cmd_data_en, cmd_data_dir, cmd_multi, cmd_auto_stop;
    logic [5:0]  cmd_index;
    logic [31:0] cmd_arg;
    resp_e       cmd_resp_type;

    // ---- sequencer <-> everything ------------------------------------------
    logic        seq_busy, seq_dat_busy, seq_card_busy, seq_cmd_done, seq_data_done;
    logic [31:0] seq_resp0, seq_resp1;
    logic [7:0]  seq_err_flags, seq_last_r1, seq_last_datresp, seq_last_daterr;
    phase_e      seq_err_phase;

    logic        phy_run_seq, phy_tx_idle_seq, phy_tx_we, phy_tx_ready, phy_rx_valid;
    logic [7:0]  phy_tx_data, phy_rx_data;

    // Gates the start of a transaction: see the sequencer's S_IDLE.
    logic        phy_idle;
    logic        seq_cs_n;

    logic        fifo_clear, fifo_dir_h2c, fifo_b_wr, fifo_b_rd, fifo_flush;
    logic [7:0]  fifo_b_wdata, fifo_b_rdata;
    logic        fifo_b_full, fifo_b_empty;
    logic        fifo_w_wr, fifo_w_rd, fifo_w_empty, fifo_w_full;
    logic [31:0] fifo_w_wdata, fifo_w_rdata;
    logic [15:0] fifo_level_bytes;

    // Unused when USE_DMA is off, by design - the sequencer still generates
    // them, there is simply nothing listening.
    /* verilator lint_off UNUSEDSIGNAL */
    logic                    dma_start, dma_dir_h2c, dma_keep_addr, dma_abort;
    logic [BLKCNT_WIDTH-1:0] dma_len_words;
    /* verilator lint_on UNUSEDSIGNAL */
    logic                    dma_busy, dma_done, dma_err;
    logic                    dma_f_rd, dma_f_wr;
    logic [31:0]             dma_f_wdata;

    logic        pio_rd, pio_wr;
    logic [31:0] pio_wdata;

    // -------------------------------------------------------------------------
    // CSR
    // -------------------------------------------------------------------------
    avalon_mm_sdcard_controller_regs #(
        .CSR_ADDR_WIDTH   (CSR_ADDR_WIDTH),
        .ADDR_WIDTH       (ADDR_WIDTH),
        .CLKDIV_WIDTH     (CLKDIV_WIDTH),
        .TIMEOUT_WIDTH    (TIMEOUT_WIDTH),
        .MAX_BLOCK_BYTES  (MAX_BLOCK_BYTES),
        .BLKCNT_WIDTH     (BLKCNT_WIDTH),
        .FIFO_DEPTH_BYTES (FIFO_DEPTH_BYTES),
        .USE_DMA          (USE_DMA),
        .USE_CARD_DETECT  (USE_CARD_DETECT)
    ) u_regs (
        .clk (clk), .reset_n (reset_n),
        .csr_address (csr_address), .csr_read (csr_read), .csr_write (csr_write),
        .csr_writedata (csr_writedata), .csr_byteenable (csr_byteenable),
        .csr_readdata (csr_readdata),
        .irq (irq),

        .cfg_enable (cfg_enable), .cfg_cs_manual (cfg_cs_manual),
        .cfg_cs_value (cfg_cs_value), .cfg_crc_en (cfg_crc_en),
        .cfg_dma_en (cfg_dma_en), .cfg_clk_run (cfg_clk_run),
        .srst_cmd (srst_cmd), .srst_dat (srst_dat),
        .cfg_clkdiv (cfg_clkdiv), .cfg_sample_dly (cfg_sample_dly),
        .cfg_timeout (cfg_timeout), .cfg_blk_size (cfg_blk_size),
        .cfg_blk_count (cfg_blk_count), .cfg_dma_addr (cfg_dma_addr),

        .cmd_start (cmd_start), .cmd_index (cmd_index), .cmd_arg (cmd_arg),
        .cmd_resp_type (cmd_resp_type), .cmd_data_en (cmd_data_en),
        .cmd_data_dir (cmd_data_dir), .cmd_multi (cmd_multi),
        .cmd_auto_stop (cmd_auto_stop),

        .seq_busy (seq_busy), .seq_dat_busy (seq_dat_busy),
        .seq_card_busy (seq_card_busy), .seq_cmd_done (seq_cmd_done),
        .seq_data_done (seq_data_done), .seq_resp0 (seq_resp0),
        .seq_resp1 (seq_resp1), .seq_err_flags (seq_err_flags),
        .seq_last_r1 (seq_last_r1), .seq_last_datresp (seq_last_datresp),
        .seq_last_daterr (seq_last_daterr), .seq_err_phase (seq_err_phase),

        .dma_busy (dma_busy), .dma_done (dma_done),
        .fifo_level_bytes (fifo_level_bytes),
        .fifo_w_empty (fifo_w_empty), .fifo_w_full (fifo_w_full),
        .card_present (USE_CARD_DETECT ? ~sd_cd_n : 1'b1),
        .card_wp      (USE_CARD_DETECT ? ~sd_wp_n : 1'b0),

        .pio_rd (pio_rd), .pio_wr (pio_wr),
        .pio_wdata (pio_wdata), .pio_rdata (fifo_w_rdata)
    );

    // -------------------------------------------------------------------------
    // Sequencer
    // -------------------------------------------------------------------------
    avalon_mm_sdcard_controller_seq #(
        .MAX_BLOCK_BYTES (MAX_BLOCK_BYTES),
        .TIMEOUT_WIDTH   (TIMEOUT_WIDTH),
        .BLKCNT_WIDTH    (BLKCNT_WIDTH)
    ) u_seq (
        .clk (clk), .reset_n (reset_n), .srst (srst_dat || srst_cmd),

        .cmd_start     (cmd_start && cfg_enable),
        .cmd_index     (cmd_index),
        .cmd_arg       (cmd_arg),
        .cmd_resp_type (cmd_resp_type),
        .cmd_data_en   (cmd_data_en),
        .cmd_data_dir  (cmd_data_dir),
        .cmd_multi     (cmd_multi),
        .cmd_auto_stop (cmd_auto_stop),
        .blk_size      (cfg_blk_size),
        .blk_count     (cfg_blk_count),
        .timeout       (cfg_timeout),
        .crc_en        (cfg_crc_en && USE_CRC),

        .busy (seq_busy), .dat_busy (seq_dat_busy), .card_busy (seq_card_busy),
        .cmd_done (seq_cmd_done), .data_done (seq_data_done),
        .resp0 (seq_resp0), .resp1 (seq_resp1),
        .err_flags (seq_err_flags), .last_r1 (seq_last_r1),
        .last_datresp (seq_last_datresp), .last_daterr (seq_last_daterr),
        .err_phase (seq_err_phase),

        .phy_run (phy_run_seq), .phy_tx_idle (phy_tx_idle_seq),
        .phy_tx_data (phy_tx_data), .phy_tx_we (phy_tx_we),
        .phy_tx_ready (phy_tx_ready), .phy_rx_data (phy_rx_data),
        .phy_rx_valid (phy_rx_valid), .phy_idle (phy_idle),
        .sd_cs_n (seq_cs_n),

        .fifo_clear (fifo_clear), .fifo_dir_h2c (fifo_dir_h2c),
        .fifo_b_wr (fifo_b_wr), .fifo_b_wdata (fifo_b_wdata),
        .fifo_b_full (fifo_b_full), .fifo_b_rd (fifo_b_rd),
        .fifo_b_rdata (fifo_b_rdata), .fifo_b_empty (fifo_b_empty),
        .fifo_flush (fifo_flush),

        .dma_start (dma_start), .dma_dir_h2c (dma_dir_h2c),
        .dma_keep_addr (dma_keep_addr), .dma_abort (dma_abort),
        .dma_len_words (dma_len_words),
        .dma_busy (dma_busy), .dma_err (dma_err)
    );

    // -------------------------------------------------------------------------
    // Shifter
    //
    // CLK_RUN free-runs the clock with CS deasserted, which is what the >=74
    // clock power-up sequence needs (§6.4.1.1) and the one case where the
    // shifter runs without the sequencer asking it to.
    // -------------------------------------------------------------------------
    avalon_mm_sdcard_controller_spi_phy #(
        .CLKDIV_WIDTH (CLKDIV_WIDTH)
    ) u_phy (
        .clk (clk), .reset_n (reset_n),
        .clkdiv (cfg_clkdiv), .sample_dly (cfg_sample_dly),
        .run     (phy_run_seq || cfg_clk_run),
        .tx_idle (phy_tx_idle_seq || cfg_clk_run),
        .idle    (phy_idle),
        .tx_data (phy_tx_data), .tx_we (phy_tx_we), .tx_ready (phy_tx_ready),
        .rx_data (phy_rx_data), .rx_valid (phy_rx_valid),
        .sd_clk (sd_clk), .sd_mosi (sd_mosi), .sd_miso (sd_miso)
    );

    // CS_n: the sequencer owns it during a transaction, software can take it
    // manually for the power-up sequence, where it must be HIGH across at least
    // 74 clocks before CMD0 (§6.4.1.1) - the opposite of what a transaction
    // wants, and impossible to express without an override.
    always_comb sd_cs_n = cfg_cs_manual ? cfg_cs_value : seq_cs_n;

    // -------------------------------------------------------------------------
    // Block buffer
    // -------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] fifo_space_words;   // bounds DMA read bursts; USE_DMA only
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb fifo_space_words =
        16'((FIFO_DEPTH_BYTES / 4)) - (fifo_level_bytes >> 2);

    avalon_mm_sdcard_controller_fifo #(
        .DEPTH_BYTES (FIFO_DEPTH_BYTES)
    ) u_fifo (
        .clk (clk), .reset_n (reset_n), .clear (fifo_clear || srst_dat),
        .dir_host_to_card (fifo_dir_h2c),
        .b_wr (fifo_b_wr), .b_wdata (fifo_b_wdata),
        .b_rd (fifo_b_rd), .b_rdata (fifo_b_rdata),
        .b_empty (fifo_b_empty), .b_full (fifo_b_full), .flush (fifo_flush),
        .w_wr (fifo_w_wr), .w_wdata (fifo_w_wdata),
        .w_rd (fifo_w_rd), .w_rdata (fifo_w_rdata),
        .w_empty (fifo_w_empty), .w_full (fifo_w_full),
        .level_bytes (fifo_level_bytes)
    );

    // The FIFO's word port has two possible clients and exactly one at a time:
    // the DMA when CTRL.DMA_EN is set, the CSR DATA window otherwise. The FIFO
    // itself does not know which, which is what makes USE_DMA cheap.
    always_comb begin
        if (cfg_dma_en) begin
            fifo_w_rd    = dma_f_rd;
            fifo_w_wr    = dma_f_wr;
            fifo_w_wdata = dma_f_wdata;
        end else begin
            fifo_w_rd    = pio_rd;
            fifo_w_wr    = pio_wr;
            fifo_w_wdata = pio_wdata;
        end
    end

    // -------------------------------------------------------------------------
    // DMA
    // -------------------------------------------------------------------------
    generate
    if (USE_DMA) begin : g_dma
        avalon_mm_sdcard_controller_dma #(
            .ADDR_WIDTH     (ADDR_WIDTH),
            .M0_BURST_WIDTH (M0_BURST_WIDTH),
            .LEN_WIDTH      (BLKCNT_WIDTH)
        ) u_dma (
            .clk (clk), .reset_n (reset_n),
            .start (dma_start && cfg_dma_en), .dir_host_to_card (dma_dir_h2c),
            .keep_addr (dma_keep_addr), .addr (cfg_dma_addr),
            .len_words (dma_len_words), .abort_req (srst_dat || dma_abort),
            .busy (dma_busy), .done (dma_done), .err (dma_err),
            .f_rd (dma_f_rd), .f_rdata (fifo_w_rdata), .f_empty (fifo_w_empty),
            .f_wr (dma_f_wr), .f_wdata (dma_f_wdata), .f_space (fifo_space_words),
            .m0_address (m0_address), .m0_read (m0_read), .m0_write (m0_write),
            .m0_writedata (m0_writedata), .m0_byteenable (m0_byteenable),
            .m0_burstcount (m0_burstcount), .m0_waitrequest (m0_waitrequest),
            .m0_readdata (m0_readdata), .m0_readdatavalid (m0_readdatavalid),
            .m0_response (m0_response)
        );
    end else begin : g_no_dma
        // The port list is fixed; the _hw.tcl elaboration callback is what
        // removes m0 from the Platform Designer component when USE_DMA is off,
        // exactly as the firewall core gates its response signals. Driving the
        // outputs inactive here keeps the RTL synthesisable standalone.
        always_comb begin
            m0_address    = '0;
            m0_read       = 1'b0;
            m0_write      = 1'b0;
            m0_writedata  = '0;
            m0_byteenable = '0;
            m0_burstcount = '0;
            dma_f_rd      = 1'b0;
            dma_f_wr      = 1'b0;
            dma_f_wdata   = '0;
            dma_busy      = 1'b0;
            dma_done      = 1'b0;
            dma_err       = 1'b0;
        end
    end
    endgenerate

endmodule : avalon_mm_sdcard_controller
