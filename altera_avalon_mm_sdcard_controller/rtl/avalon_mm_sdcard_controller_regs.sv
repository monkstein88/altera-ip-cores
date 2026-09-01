`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_regs.sv
//
// The control/status slave. Register decode, interrupt generation, and the PIO
// data window.
//
// -----------------------------------------------------------------------------
// THE DULLEST POSSIBLE AVALON-MM SLAVE, DELIBERATELY
// -----------------------------------------------------------------------------
// Word-addressed, 32 bits wide, fixed read latency of one cycle, never asserts
// waitrequest, zero pending reads. That is the classic Altera register
// peripheral profile and it is chosen for one reason: this port has to stay
// reachable when everything else is busy or stuck. A control port that can be
// backpressured by the thing it controls is a control port you cannot use to
// recover.
//
// Fixed read latency 1 means readdata is registered and valid exactly one cycle
// after the address - no readdatavalid, nothing to handshake.
//
// -----------------------------------------------------------------------------
// ONE INTERRUPT MASK, NOT TWO
// -----------------------------------------------------------------------------
// IRQ_STATUS records every event unconditionally; IRQ_ENABLE gates only whether
// the pin is driven. SDHCI splits this into a Status Enable and a Signal
// Enable, where the first controls whether the bit is recorded at all. For a
// general-purpose host serving many drivers that flexibility earns its keep;
// here it would mean two mask registers and a class of bug where software polls
// a status bit that can never set. Polling always works here.
//
// Status bits are write-1-to-clear. The interrupt is level, so it stays
// asserted until the causing bit is cleared at the source - the standard Avalon
// peripheral idiom, and what the Nios II HAL ISR pattern expects.
// =============================================================================

module avalon_mm_sdcard_controller_regs
    import avalon_mm_sdcard_controller_pkg::*;
#(
    parameter int unsigned CSR_ADDR_WIDTH  = 5,
    parameter int unsigned ADDR_WIDTH      = 32,
    parameter int unsigned CLKDIV_WIDTH    = 8,
    parameter int unsigned TIMEOUT_WIDTH   = 26,
    parameter int unsigned MAX_BLOCK_BYTES = 512,
    parameter int unsigned BLKCNT_WIDTH    = 16,
    parameter int unsigned FIFO_DEPTH_BYTES= 1024,
    parameter bit          USE_DMA         = 1'b1,
    parameter bit          USE_CARD_DETECT = 1'b1
) (
    input  logic                          clk,
    input  logic                          reset_n,

    // ---- Avalon-MM slave ---------------------------------------------------
    input  logic [CSR_ADDR_WIDTH-1:0]     csr_address,
    input  logic                          csr_read,
    input  logic                          csr_write,
    input  logic [31:0]                   csr_writedata,
    input  logic [3:0]                    csr_byteenable,
    output logic [31:0]                   csr_readdata,

    output logic                          irq,

    // ---- configuration out -------------------------------------------------
    output logic                          cfg_enable,
    output logic                          cfg_cs_manual,
    output logic                          cfg_cs_value,
    output logic                          cfg_crc_en,
    output logic                          cfg_dma_en,
    output logic                          cfg_clk_run,
    output logic                          srst_cmd,
    output logic                          srst_dat,
    output logic [CLKDIV_WIDTH-1:0]       cfg_clkdiv,
    output logic [2:0]                    cfg_sample_dly,
    output logic [TIMEOUT_WIDTH-1:0]      cfg_timeout,
    output logic [$clog2(MAX_BLOCK_BYTES+1)-1:0] cfg_blk_size,
    output logic [BLKCNT_WIDTH-1:0]       cfg_blk_count,
    output logic [ADDR_WIDTH-1:0]         cfg_dma_addr,

    // ---- command issue -----------------------------------------------------
    output logic                          cmd_start,
    output logic [5:0]                    cmd_index,
    output logic [31:0]                   cmd_arg,
    output resp_e                         cmd_resp_type,
    output logic                          cmd_data_en,
    output logic                          cmd_data_dir,
    output logic                          cmd_multi,
    output logic                          cmd_auto_stop,

    // ---- status in ---------------------------------------------------------
    input  logic                          seq_busy,
    input  logic                          seq_dat_busy,
    input  logic                          seq_card_busy,
    input  logic                          seq_cmd_done,
    input  logic                          seq_data_done,
    input  logic [31:0]                   seq_resp0,
    input  logic [31:0]                   seq_resp1,
    input  logic [7:0]                    seq_err_flags,
    input  logic [7:0]                    seq_last_r1,
    input  logic [7:0]                    seq_last_datresp,
    input  logic [7:0]                    seq_last_daterr,
    input  phase_e                        seq_err_phase,

    input  logic                          dma_busy,
    input  logic                          dma_done,

    input  logic [15:0]                   fifo_level_bytes,
    input  logic                          fifo_w_empty,
    input  logic                          fifo_w_full,

    input  logic                          card_present,
    input  logic                          card_wp,

    // ---- PIO data window ---------------------------------------------------
    output logic                          pio_rd,
    output logic                          pio_wr,
    output logic [31:0]                   pio_wdata,
    input  logic [31:0]                   pio_rdata
);

    localparam int unsigned BCW = $clog2(MAX_BLOCK_BYTES + 1);

    logic [31:0] ctrl_q, irq_en_q, irq_st_q, clkdiv_q, timeout_q;
    logic [31:0] arg_q, cmd_q, blksize_q, blkcnt_q, dmaaddr_q, dmactrl_q;

    logic sel;
    always_comb sel = (csr_address < CSR_ADDR_WIDTH'(REG_COUNT));

    // -------------------------------------------------------------------------
    // Writes
    // -------------------------------------------------------------------------
    logic wr_hit;
    always_comb wr_hit = csr_write && sel;

    // Byte-enable-aware update. Software almost always writes whole words, but
    // honouring byteenable costs nothing and a slave that ignores it corrupts
    // the other three bytes on any half-word access an interconnect adapter
    // decides to generate.
    function automatic logic [31:0] bewr(input logic [31:0] old,
                                         input logic [31:0] nw,
                                         input logic [3:0]  be);
        logic [31:0] r;
        begin
            r = old;
            if (be[0]) r[7:0]   = nw[7:0];
            if (be[1]) r[15:8]  = nw[15:8];
            if (be[2]) r[23:16] = nw[23:16];
            if (be[3]) r[31:24] = nw[31:24];
            return r;
        end
    endfunction

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ctrl_q    <= '0;
            irq_en_q  <= '0;
            clkdiv_q  <= 32'd2;                 // clk/4: a safe post-reset rate
            // Reset to the largest timeout the counter can express, so a driver
            // that never writes TIMEOUT gets the most permissive behaviour
            // rather than an instant abort.
            timeout_q <= 32'((1 << TIMEOUT_WIDTH) - 1);
            arg_q     <= '0;
            cmd_q     <= '0;
            blksize_q <= 32'd512;
            blkcnt_q  <= 32'd1;
            dmaaddr_q <= '0;
            dmactrl_q <= '0;
            cmd_start <= 1'b0;
            pio_wr    <= 1'b0;
            pio_wdata <= '0;
        end else begin
            cmd_start <= 1'b0;
            pio_wr    <= 1'b0;

            // Self-clearing bits never persist.
            ctrl_q[CTRL_SRST_CMD] <= 1'b0;
            ctrl_q[CTRL_SRST_DAT] <= 1'b0;
            ctrl_q[CTRL_SRST_ALL] <= 1'b0;

            if (wr_hit) begin
                unique case (csr_address)
                    CSR_ADDR_WIDTH'(REG_CTRL):
                        ctrl_q <= bewr(ctrl_q, csr_writedata, csr_byteenable);

                    CSR_ADDR_WIDTH'(REG_IRQ_ENABLE):
                        irq_en_q <= bewr(irq_en_q, csr_writedata, csr_byteenable);

                    // CLKDIV carries SAMPLE_DLY, which must not move while the
                    // shifter is running: changing the capture point mid-byte
                    // misaligns the bit count for the rest of the transfer.
                    CSR_ADDR_WIDTH'(REG_CLKDIV):
                        if (!seq_busy)
                            clkdiv_q <= bewr(clkdiv_q, csr_writedata, csr_byteenable);

                    CSR_ADDR_WIDTH'(REG_TIMEOUT):
                        timeout_q <= bewr(timeout_q, csr_writedata, csr_byteenable);
                    CSR_ADDR_WIDTH'(REG_CMD_ARG):
                        arg_q <= bewr(arg_q, csr_writedata, csr_byteenable);
                    CSR_ADDR_WIDTH'(REG_BLK_SIZE):
                        blksize_q <= bewr(blksize_q, csr_writedata, csr_byteenable);
                    CSR_ADDR_WIDTH'(REG_BLK_COUNT):
                        blkcnt_q <= bewr(blkcnt_q, csr_writedata, csr_byteenable);
                    CSR_ADDR_WIDTH'(REG_DMA_ADDR):
                        dmaaddr_q <= bewr(dmaaddr_q, csr_writedata, csr_byteenable);
                    CSR_ADDR_WIDTH'(REG_DMA_CTRL):
                        dmactrl_q <= bewr(dmactrl_q, csr_writedata, csr_byteenable);

                    // Writing CMD launches it. Ignored while the sequencer is
                    // busy, so a second write cannot corrupt a transfer in
                    // flight - software polls STATUS.CMD_BUSY or waits for the
                    // interrupt.
                    CSR_ADDR_WIDTH'(REG_CMD): begin
                        if (!seq_busy) begin
                            cmd_q     <= bewr(cmd_q, csr_writedata, csr_byteenable);
                            cmd_start <= csr_writedata[CMD_START];
                        end
                    end

                    CSR_ADDR_WIDTH'(REG_DATA): begin
                        pio_wdata <= csr_writedata;
                        pio_wr    <= 1'b1;
                    end

                    default: ;
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Interrupt status: sticky, write-1-to-clear, set from sequencer events
    // -------------------------------------------------------------------------
    logic [31:0] irq_set;
    always_comb begin
        irq_set = '0;
        irq_set[IRQ_CMD_DONE]      = seq_cmd_done;
        irq_set[IRQ_DATA_DONE]     = seq_data_done;
        irq_set[IRQ_DMA_DONE]      = dma_done;
        irq_set[IRQ_ERR_CMD_TMO]   = seq_err_flags[0];
        irq_set[IRQ_ERR_CMD_CRC]   = seq_err_flags[1];
        irq_set[IRQ_ERR_CMD_ILL]   = seq_err_flags[2];
        irq_set[IRQ_ERR_DAT_TMO]   = seq_err_flags[3];
        irq_set[IRQ_ERR_DAT_CRC]   = seq_err_flags[4];
        irq_set[IRQ_ERR_DAT_TOKEN] = seq_err_flags[5];
        irq_set[IRQ_ERR_WRITE]     = seq_err_flags[6];
        irq_set[IRQ_ERR_DMA]       = seq_err_flags[7];
    end

    logic card_present_q, card_wp_q;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            irq_st_q       <= '0;
            card_present_q <= 1'b0;
            card_wp_q      <= 1'b0;
        end else begin
            card_present_q <= card_present;
            card_wp_q      <= card_wp;

            // Set beats clear: an event arriving in the same cycle as the
            // write that acknowledges the previous one must not be lost.
            if (wr_hit && (csr_address == CSR_ADDR_WIDTH'(REG_IRQ_STATUS)))
                irq_st_q <= (irq_st_q & ~csr_writedata) | irq_set;
            else
                irq_st_q <= irq_st_q | irq_set;

            if (USE_CARD_DETECT) begin
                if ( card_present && !card_present_q) irq_st_q[IRQ_CARD_INSERT] <= 1'b1;
                if (!card_present &&  card_present_q) irq_st_q[IRQ_CARD_REMOVE] <= 1'b1;
            end
        end
    end

    always_comb irq = |(irq_st_q & irq_en_q);

    // -------------------------------------------------------------------------
    // Reads. Fixed latency of one cycle: registered, no waitrequest.
    //
    // The DATA window pops the FIFO, so `pio_rd` must pulse on the ACCESS, not
    // on the registered result - popping when the data is returned would be one
    // cycle late and would drop a word on back-to-back reads.
    // -------------------------------------------------------------------------
    always_comb pio_rd = csr_read && sel &&
                         (csr_address == CSR_ADDR_WIDTH'(REG_DATA));

    logic [31:0] status_w, errinfo_w, coreinfo_w;

    always_comb begin
        status_w = '0;
        status_w[STAT_CMD_BUSY]   = seq_busy;
        status_w[STAT_DAT_BUSY]   = seq_dat_busy;
        status_w[STAT_DMA_BUSY]   = dma_busy;
        status_w[STAT_CARD_BUSY]  = seq_card_busy;
        status_w[STAT_FIFO_EMPTY] = fifo_w_empty;
        status_w[STAT_FIFO_FULL]  = fifo_w_full;
        status_w[STAT_LEVEL_MSB:STAT_LEVEL_LSB] = fifo_level_bytes;
        status_w[STAT_CARD_PRES]  = USE_CARD_DETECT ? card_present_q : 1'b1;
        status_w[STAT_CARD_WP]    = USE_CARD_DETECT ? card_wp_q      : 1'b0;
        status_w[STAT_ERROR]      = |(irq_st_q & IRQ_ERR_MASK);
    end

    always_comb begin
        errinfo_w = '0;
        errinfo_w[ERR_DATRESP_LSB +: 8] = seq_last_datresp;
        errinfo_w[ERR_R1_LSB      +: 8] = seq_last_r1;
        errinfo_w[ERR_DATERR_LSB  +: 8] = seq_last_daterr;
        errinfo_w[ERR_PHASE_LSB   +: 4] = seq_err_phase;
    end

    // Read by the HAL driver at init() to check it is bound to hardware it
    // understands, and to learn the build-time configuration it cannot infer.
    always_comb begin
        coreinfo_w = '0;
        coreinfo_w[7:0]   = CORE_VERSION_MINOR;
        coreinfo_w[15:8]  = CORE_VERSION_MAJOR;
        coreinfo_w[23:16] = 8'(clog2_shift(FIFO_DEPTH_BYTES));
        coreinfo_w[24]    = USE_DMA;
        coreinfo_w[25]    = USE_CARD_DETECT;
        coreinfo_w[26]    = 1'b1;                 // PHY is SPI
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            csr_readdata <= '0;
        end else if (csr_read) begin
            unique case (csr_address)
                CSR_ADDR_WIDTH'(REG_CTRL):       csr_readdata <= ctrl_q;
                CSR_ADDR_WIDTH'(REG_STATUS):     csr_readdata <= status_w;
                CSR_ADDR_WIDTH'(REG_IRQ_ENABLE): csr_readdata <= irq_en_q;
                CSR_ADDR_WIDTH'(REG_IRQ_STATUS): csr_readdata <= irq_st_q;
                CSR_ADDR_WIDTH'(REG_CLKDIV):     csr_readdata <= clkdiv_q;
                CSR_ADDR_WIDTH'(REG_TIMEOUT):    csr_readdata <= timeout_q;
                CSR_ADDR_WIDTH'(REG_CMD_ARG):    csr_readdata <= arg_q;
                CSR_ADDR_WIDTH'(REG_CMD):        csr_readdata <= {seq_busy, cmd_q[30:0]};
                CSR_ADDR_WIDTH'(REG_RESP0):      csr_readdata <= seq_resp0;
                CSR_ADDR_WIDTH'(REG_RESP1):      csr_readdata <= seq_resp1;
                CSR_ADDR_WIDTH'(REG_BLK_SIZE):   csr_readdata <= blksize_q;
                CSR_ADDR_WIDTH'(REG_BLK_COUNT):  csr_readdata <= blkcnt_q;
                CSR_ADDR_WIDTH'(REG_DMA_ADDR):   csr_readdata <= dmaaddr_q;
                CSR_ADDR_WIDTH'(REG_DMA_CTRL):   csr_readdata <= dmactrl_q;
                CSR_ADDR_WIDTH'(REG_DATA):       csr_readdata <= pio_rdata;
                CSR_ADDR_WIDTH'(REG_ERR_INFO):   csr_readdata <= errinfo_w;
                CSR_ADDR_WIDTH'(REG_CORE_INFO):  csr_readdata <= coreinfo_w;
                default:                         csr_readdata <= 32'h0;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Configuration fan-out
    // -------------------------------------------------------------------------
    always_comb begin
        cfg_enable     = ctrl_q[CTRL_ENABLE];
        cfg_cs_manual  = ctrl_q[CTRL_CS_MANUAL];
        cfg_cs_value   = ctrl_q[CTRL_CS_VALUE];
        cfg_crc_en     = ctrl_q[CTRL_CRC_EN];
        cfg_dma_en     = ctrl_q[CTRL_DMA_EN] && USE_DMA;
        cfg_clk_run    = ctrl_q[CTRL_CLK_RUN];
        srst_cmd       = ctrl_q[CTRL_SRST_CMD] || ctrl_q[CTRL_SRST_ALL];
        srst_dat       = ctrl_q[CTRL_SRST_DAT] || ctrl_q[CTRL_SRST_ALL];

        cfg_clkdiv     = clkdiv_q[CLKDIV_DIV_LSB  +: CLKDIV_WIDTH];
        cfg_sample_dly = clkdiv_q[CLKDIV_SMPL_LSB +: 3];
        cfg_timeout    = timeout_q[TIMEOUT_WIDTH-1:0];
        cfg_blk_size   = blksize_q[BCW-1:0];
        cfg_blk_count  = blkcnt_q[BLKCNT_WIDTH-1:0];
        cfg_dma_addr   = dmaaddr_q[ADDR_WIDTH-1:0];

        cmd_index      = cmd_q[CMD_INDEX_LSB +: 6];
        cmd_arg        = arg_q;
        cmd_resp_type  = resp_e'(cmd_q[CMD_RESP_LSB +: 2]);
        cmd_data_en    = cmd_q[CMD_DATA_EN];
        cmd_data_dir   = cmd_q[CMD_DATA_DIR];
        cmd_multi      = cmd_q[CMD_MULTI];
        cmd_auto_stop  = cmd_q[CMD_AUTO_STOP];
    end

endmodule : avalon_mm_sdcard_controller_regs
