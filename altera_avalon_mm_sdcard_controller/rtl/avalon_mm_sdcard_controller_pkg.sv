// Carries a `timescale even though it is pure synthesisable RTL with no
// delays. Mixing timescaled and untimescaled modules in one compilation is
// tool-dependent (IEEE 1800 3.14.2.3) - slang rejects it outright, Verilator
// warns (TIMESCALEMOD), Questa accepts it silently. Quartus ignores the
// directive for synthesis, so declaring it costs nothing and removes the
// ambiguity.
`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_pkg.sv
//
// Shared types, register offsets, bit positions and SD-SPI protocol constants
// for the Avalon-MM SD Card Controller.
//
// This file MUST be compiled first - every other module imports it, and the
// _hw.tcl filesets list it ahead of the rest for that reason.
//
// -----------------------------------------------------------------------------
// WHERE THESE CONSTANTS COME FROM
// -----------------------------------------------------------------------------
// Everything in the PROTOCOL section below is from the SD Physical Layer
// Simplified Specification, Version 4.10, chapter 7 (SPI Mode). Section numbers
// are given per constant. The specification is not redistributed with this
// repository - see doc/avalon_mm_sdcard_controller_design.md, which cites the
// same sections and links where to obtain it.
//
// The CRC parameters are the two that are most often got wrong, so they are
// called out here rather than buried in avalon_mm_sdcard_controller_crc.sv:
//
//   CRC7  - x^7 + x^3 + 1, initial value 0, over the five command bytes.
//   CRC16 - CCITT x^16 + x^12 + x^5 + 1, initial value 0x0000.
//
// That CRC16 initial value is NOT the 0xFFFF that "CCITT" usually implies. SD
// uses zero. Both polynomials are verified against the spec's own fixed frames
// (CMD0 -> 0x95, CMD8 with argument 0x1AA -> 0x87) and against 512 bytes of
// 0xFF -> 0x7FA1, in the testbench and in doc/tools/check_facts.py.
// =============================================================================

package avalon_mm_sdcard_controller_pkg;

    // -------------------------------------------------------------------------
    // Core identity, reported in CORE_INFO and checked by the HAL driver at
    // init(). The driver refuses to bind to hardware whose major version it
    // does not recognise: a BSP is far easier to copy between projects than to
    // keep in step with one.
    // -------------------------------------------------------------------------
    localparam logic [7:0] CORE_VERSION_MAJOR = 8'd1;
    localparam logic [7:0] CORE_VERSION_MINOR = 8'd0;

    // =========================================================================
    // REGISTER MAP - word indices as decoded by the RTL
    //
    // The csr port is WORD-addressed, which is Platform Designer's default for
    // an Avalon-MM agent and what every stock Altera register peripheral uses.
    // Software sees BYTE offsets four times these values; inc/*_regs.h gives
    // both, because getting that factor of four wrong is the single easiest
    // mistake to make with this core.
    // =========================================================================
    localparam int unsigned REG_CTRL       = 0;   // 0x00  RW
    localparam int unsigned REG_STATUS     = 1;   // 0x04  RO
    localparam int unsigned REG_IRQ_ENABLE = 2;   // 0x08  RW
    localparam int unsigned REG_IRQ_STATUS = 3;   // 0x0C  RW1C
    localparam int unsigned REG_CLKDIV     = 4;   // 0x10  RW
    localparam int unsigned REG_TIMEOUT    = 5;   // 0x14  RW
    localparam int unsigned REG_CMD_ARG    = 6;   // 0x18  RW
    localparam int unsigned REG_CMD        = 7;   // 0x1C  RW, write starts
    localparam int unsigned REG_RESP0      = 8;   // 0x20  RO
    localparam int unsigned REG_RESP1      = 9;   // 0x24  RO
    localparam int unsigned REG_BLK_SIZE   = 10;  // 0x28  RW
    localparam int unsigned REG_BLK_COUNT  = 11;  // 0x2C  RW
    localparam int unsigned REG_DMA_ADDR   = 12;  // 0x30  RW
    localparam int unsigned REG_DMA_CTRL   = 13;  // 0x34  RW
    localparam int unsigned REG_DATA       = 14;  // 0x38  RW  PIO window
    localparam int unsigned REG_ERR_INFO   = 15;  // 0x3C  RO
    localparam int unsigned REG_CORE_INFO  = 16;  // 0x40  RO

    localparam int unsigned REG_COUNT      = 17;  // CSR_ADDR_WIDTH must cover this

    // ---------------------------------------------------- CTRL (word 0, RW) --
    localparam int CTRL_ENABLE      = 0;   // master enable; 0 idles the sequencer
    localparam int CTRL_CS_MANUAL   = 1;   // software drives CS_n directly
    localparam int CTRL_CS_VALUE    = 2;   // the level driven when CS_MANUAL
    localparam int CTRL_CRC_EN      = 3;   // generate/check CRC16 on data blocks
    localparam int CTRL_DMA_EN      = 4;   // data phase uses m0 rather than DATA
    localparam int CTRL_CLK_RUN     = 5;   // free-run SPI clock with CS_n high

    // Software reset, split into domains the way SDHCI splits its own (see the
    // design document, section 10). One blunt reset would mean losing the
    // card's initialised state to clear a stuck data phase, which is exactly
    // when you least want to redo identification. All three are self-clearing
    // and none of them touch configuration.
    localparam int CTRL_SRST_CMD    = 8;   // command path only
    localparam int CTRL_SRST_DAT    = 9;   // data path and FIFO only
    localparam int CTRL_SRST_ALL    = 10;  // everything except configuration

    // -------------------------------------------------- STATUS (word 1, RO) --
    localparam int STAT_CMD_BUSY    = 0;   // a command is in flight
    localparam int STAT_DAT_BUSY    = 1;   // a data phase is in flight
    localparam int STAT_DMA_BUSY    = 2;   // m0 has a transfer outstanding
    localparam int STAT_CARD_BUSY   = 3;   // card is holding MISO low
    localparam int STAT_FIFO_EMPTY  = 4;
    localparam int STAT_FIFO_FULL   = 5;
    localparam int STAT_LEVEL_LSB   = 8;   // [23:8] FIFO occupancy in bytes
    localparam int STAT_LEVEL_MSB   = 23;
    localparam int STAT_CARD_PRES   = 24;  // from sd_cd_n, if USE_CARD_DETECT
    localparam int STAT_CARD_WP     = 25;  // from sd_wp_n, if USE_CARD_DETECT
    localparam int STAT_ERROR       = 31;  // sticky OR of the IRQ error bits

    // ------------------------- IRQ_ENABLE / IRQ_STATUS (words 2 and 3, RW1C) --
    //
    // One layout for both registers. IRQ_STATUS records every event
    // unconditionally and IRQ_ENABLE gates only the pin - deliberately NOT
    // SDHCI's two-level Status Enable / Signal Enable scheme, which adds a
    // second mask and a class of bug where software polls a bit that can never
    // set. See the design document, section 10.
    localparam int IRQ_CMD_DONE      = 0;  // command and its response complete
    localparam int IRQ_DATA_DONE     = 1;  // the whole BLK_COUNT transfer done
    localparam int IRQ_DMA_DONE      = 2;  // m0 has drained/filled the FIFO

    localparam int IRQ_ERR_CMD_TMO   = 8;  // no response within TIMEOUT
    localparam int IRQ_ERR_CMD_CRC   = 9;  // R1 reported a command CRC error
    localparam int IRQ_ERR_CMD_ILL   = 10; // R1 reported an illegal command
    localparam int IRQ_ERR_DAT_TMO   = 11; // no data token, or busy outlasted TIMEOUT
    localparam int IRQ_ERR_DAT_CRC   = 12; // CRC16 mismatch on a read block
    localparam int IRQ_ERR_DAT_TOKEN = 13; // card sent a data error token
    localparam int IRQ_ERR_WRITE     = 14; // data response token rejected the block
    localparam int IRQ_ERR_DMA       = 15; // m0 returned an error response
    localparam int IRQ_CARD_INSERT   = 16;
    localparam int IRQ_CARD_REMOVE   = 17;

    localparam logic [31:0] IRQ_ERR_MASK = 32'h0003_FF00;  // bits 8..17

    // -------------------------------------------------- CLKDIV (word 4, RW) --
    // SPI clock = clk / (2 * CLKDIV), CLKDIV >= 1.
    //   CLKDIV = 1   -> clk/2   =  50 MHz from a 100 MHz system clock
    //   CLKDIV = 2   -> clk/4   =  25 MHz
    //   CLKDIV = 125 -> clk/250 = 400 kHz, the identification rate
    //
    // SAMPLE_DLY delays MISO capture by N system clocks past the nominal
    // sampling point. It exists because the round trip - our sd_clk edge out to
    // the card, the card's output delay, MISO back - must fit inside half an SPI
    // period, which at CLKDIV=1 is 10 ns. On a socket that is comfortable; on
    // flying leads to a breakout it is not. The specification is no help here:
    // section 7.5, SPI Bus Timing Diagrams, is blank in the Simplified
    // Specification, so this is a tuning knob rather than a derived constant.
    //
    // IT IS BOUNDED BY THE DIVISOR:
    //
    //     SAMPLE_DLY <= CLKDIV - 2
    //
    // The SPI half-period is CLKDIV system clocks wide and the nominal capture
    // point already sits one clock inside it, so a larger delay walks the
    // sample onto the NEXT bit and shifts every byte of the transfer by one.
    // The failure is total and silent - the bus looks alive, the byte count is
    // right, every byte is wrong.
    //
    // The practical consequence is worth knowing before choosing a clock rate:
    // at CLKDIV=1 and CLKDIV=2 the only legal delay is zero. At 50 MHz there is
    // no margin to trade, which is a reason to prefer 25 MHz on anything other
    // than a properly laid out socket. avalon_mm_sdcard_controller_hw.tcl rejects the illegal
    // combinations at generation time, and the shifter's unit testbench sweeps
    // the legal boundary at every divisor.
    localparam int CLKDIV_DIV_LSB   = 0;
    localparam int CLKDIV_SMPL_LSB  = 16;

    // ----------------------------------------------------- CMD (word 7, RW) --
    localparam int CMD_INDEX_LSB    = 0;   // [5:0]  command index
    localparam int CMD_RESP_LSB     = 6;   // [7:6]  resp_e
    localparam int CMD_DATA_EN      = 8;   // this command has a data phase
    localparam int CMD_DATA_DIR     = 9;   // 0 = card->host, 1 = host->card
    localparam int CMD_MULTI        = 10;  // stream BLK_COUNT blocks in hardware
    localparam int CMD_AUTO_STOP    = 11;  // terminate the stream without software
    localparam int CMD_START        = 31;  // write 1 to launch; reads back busy

    // ------------------------------------------------ DMA_CTRL (word 13, RW) --
    // Only mode 0 is defined. The field exists so that an ADMA2-style
    // descriptor mode can be added later as a reserved encoding rather than an
    // ABI break - see the design document, section 10.
    localparam int DMA_MODE_LSB     = 0;   // [1:0]
    localparam logic [1:0] DMA_MODE_CONTIG = 2'd0;

    // ------------------------------------------------ ERR_INFO (word 15, RO) --
    localparam int ERR_DATRESP_LSB  = 0;   // [7:0]   last data response token
    localparam int ERR_R1_LSB       = 8;   // [15:8]  last R1 byte received
    localparam int ERR_DATERR_LSB   = 16;  // [23:16] last data error token
    localparam int ERR_PHASE_LSB    = 24;  // [27:24] phase_e that timed out

    // =========================================================================
    // PROTOCOL CONSTANTS - SD Physical Layer Simplified Specification v4.10
    // =========================================================================

    // Start of every command frame: the two framing bits '01' above the index.
    // Section 7.3.1.1.
    localparam logic [1:0] CMD_FRAME_START = 2'b01;

    // Data tokens, section 7.3.3.2. Note that 0xFE covers single-block read,
    // single-block write AND multiple-block READ; only multiple-block WRITE
    // uses its own 0xFC, and only that form has a stop token.
    localparam logic [7:0] TOKEN_START_BLOCK   = 8'hFE;
    localparam logic [7:0] TOKEN_START_MULTI_W = 8'hFC;
    localparam logic [7:0] TOKEN_STOP_TRAN     = 8'hFD;

    // Data response token, section 7.3.3.1: xxx0sss1.
    // Mask off the don't-care top three bits before comparing.
    localparam logic [7:0] DATRESP_MASK     = 8'h1F;
    localparam logic [7:0] DATRESP_ACCEPTED = 8'h05;  // sss = 010
    localparam logic [7:0] DATRESP_CRC_ERR  = 8'h0B;  // sss = 101
    localparam logic [7:0] DATRESP_WR_ERR   = 8'h0D;  // sss = 110

    // R1, section 7.3.2.1. Bit 7 is always zero, which is how the sequencer
    // recognises the response byte among the 0xFF idle bytes preceding it.
    localparam int R1_IDLE          = 0;
    localparam int R1_ERASE_RESET   = 1;
    localparam int R1_ILLEGAL_CMD   = 2;
    localparam int R1_COM_CRC_ERR   = 3;
    localparam int R1_ERASE_SEQ_ERR = 4;
    localparam int R1_ADDRESS_ERR   = 5;
    localparam int R1_PARAM_ERR     = 6;

    // Data error token, section 7.3.3.3: upper nibble zero, which is what
    // distinguishes it from a start token.
    localparam logic [7:0] DATERR_MASK = 8'hF0;

    // N_CR, section 7.2/7.3.2: the card answers within 0 to 8 byte-times for
    // SD (1 to 8 for MMC). The sequencer shifts 0xFF and watches for a byte
    // with bit 7 clear, giving up after this many. TIMEOUT is the outer bound
    // for everything else.
    localparam int unsigned NCR_MAX_BYTES = 8;

    // The idle level the host drives on MOSI whenever it is not sending a
    // command or write data. Also what it shifts to clock data out of the card.
    localparam logic [7:0] MOSI_IDLE = 8'hFF;

    // =========================================================================
    // TYPES
    // =========================================================================

    // Response format, CMD[7:6]. R2 is two bytes and only CMD13 returns it;
    // R3 and R7 are one byte plus a 32-bit trailer.
    typedef enum logic [1:0] {
        RESP_R1   = 2'd0,
        RESP_R1B  = 2'd1,   // R1 then busy on MISO until it releases
        RESP_R2   = 2'd2,   // two bytes
        RESP_R3R7 = 2'd3    // one byte plus 32-bit trailer
    } resp_e;

    // Which wait timed out, reported in ERR_INFO[27:24]. Distinguishing these
    // is the difference between "the card never answered" and "the card
    // answered and then never finished", which need different recovery.
    typedef enum logic [3:0] {
        PHASE_IDLE     = 4'd0,
        PHASE_CMD      = 4'd1,   // shifting the command frame out
        PHASE_RESP     = 4'd2,   // waiting for the response byte
        PHASE_RESP_TRL = 4'd3,   // shifting the R2/R3/R7 trailer
        PHASE_TOKEN    = 4'd4,   // waiting for a start or error token
        PHASE_DATA     = 4'd5,   // streaming the block
        PHASE_CRC      = 4'd6,   // the block's two CRC bytes
        PHASE_DATRESP  = 4'd7,   // waiting for the data response token
        PHASE_BUSY     = 4'd8,   // card holding MISO low after a write
        PHASE_STOP     = 4'd9    // CMD12 or stop-tran termination
    } phase_e;

    // Direction of a data phase, CMD[9].
    typedef enum logic {
        DIR_CARD_TO_HOST = 1'b0,
        DIR_HOST_TO_CARD = 1'b1
    } dir_e;

    // -------------------------------------------------------------------------
    // Helper: ceiling log2, by shifting rather than by $clog2 on a real.
    //
    // $clog2 is fine and is what this would normally use; it is spelled out
    // here only because the same computation has to be done identically in the
    // _hw.tcl validation callback, where Tcl has no $clog2 and the obvious
    // log(x)/log(2) form depends on the host libm not landing a hair above an
    // integer for exact powers of two. Keeping both as shifts keeps them
    // provably in step.
    // -------------------------------------------------------------------------
    function automatic int unsigned clog2_shift(input int unsigned value);
        int unsigned n;
        begin
            n = 0;
            while ((32'd1 << n) < value) n = n + 1;
            return n;
        end
    endfunction

endpackage : avalon_mm_sdcard_controller_pkg
