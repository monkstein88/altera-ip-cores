`timescale 1ns/1ps

// =============================================================================
// spi_card_model.sv
//
// A behavioural SD card in SPI mode. This is the thing every other testbench in
// the core is measured against, so it is written to the specification rather
// than to the DUT: if the two disagree, the model is the one holding the
// specification's position.
//
// Implements, per the SD Physical Layer Simplified Specification v4.10 ch. 7:
//
//   commands   CMD0 CMD8 CMD9 CMD10 CMD12 CMD13 CMD16 CMD17 CMD18
//              CMD24 CMD25 CMD55 CMD58 CMD59, ACMD41
//   responses  R1, R1b (with busy), R2, R3, R7
//   tokens     0xFE start, 0xFC multi-write start, 0xFD stop tran,
//              data response xxx0sss1, data error token 0000xxxx
//   CRC        CRC7 on commands (checked), CRC16 on data (checked and generated)
//   timing     N_CR of 0-8 byte-times, busy on MISO after a write
//   capacity   SDSC byte addressing and SDHC/SDXC block addressing
//
// -----------------------------------------------------------------------------
// IT MUST BE ABLE TO MISBEHAVE
// -----------------------------------------------------------------------------
// A card model that only ever works correctly proves that the DUT handles the
// happy path, which is the part that was never in doubt. The `inj_*` inputs
// make it produce, on demand: no response at all, a response with the CRC error
// or illegal command bit set, a read that returns a data error token instead of
// a block, a block whose CRC16 is wrong, a write rejected with a CRC or write
// error token, and busy that outlasts any timeout.
//
// The truncated-response behaviour of §7.3.2 is NOT an injected fault - it is
// modelled unconditionally, because it is what a real v1.x card does to CMD8:
// when R1 carries Illegal Command or Command CRC Error, the 32-bit trailer of
// an R3 or R7 is never sent. A DUT that reads it anyway desynchronises, and
// this model is what catches that.
//
// -----------------------------------------------------------------------------
// TIMING
// -----------------------------------------------------------------------------
// SPI mode 0 from the card's side: MOSI is sampled on the rising edge of
// sd_clk, MISO changes on the falling edge. MISO is driven combinationally from
// a registered byte and bit index so it is valid before the first rising edge,
// which CPHA=0 requires and which a negedge-only driver would get wrong for
// exactly one bit per transaction.
// =============================================================================

module spi_card_model #(
    parameter bit          HIGH_CAPACITY = 1'b1,   // SDHC: block addressing
    parameter int unsigned NCR_BYTES     = 2,      // response latency, 0..8
    parameter bit          TRACE         = 1'b0    // log every command handled
) (
    input  logic sd_clk,
    input  logic sd_cs_n,
    input  logic sd_mosi,
    output logic sd_miso,

    // ---- fault injection ---------------------------------------------------
    input  logic inj_no_response,     // swallow the next command entirely
    input  logic inj_r1_illegal,      // set Illegal Command in the next R1
    input  logic inj_r1_crc,          // set Com CRC Error in the next R1
    input  logic inj_read_err_token,  // data error token instead of a block
    input  logic inj_bad_data_crc,    // corrupt the CRC16 of the next read block
    input  logic inj_write_crc_err,   // reject the next written block, CRC
    input  logic inj_write_err,       // reject the next written block, write error
    input  logic inj_busy_forever,    // never release busy

    // ---- observation -------------------------------------------------------
    output int unsigned cmds_seen,
    output int unsigned blocks_read,
    output int unsigned blocks_written,
    output logic [5:0]  last_cmd,
    output logic        last_cmd_crc_ok
);

    // -------------------------------------------------------------------------
    // Card state
    // -------------------------------------------------------------------------
    logic [7:0]  card_mem [int unsigned];   // sparse, byte addressed
    logic        is_idle;                   // in_idle_state, cleared by ACMD41
    logic        acmd_next;                 // CMD55 seen, next command is ACMD
    logic        crc_on;                    // CMD59
    logic [31:0] block_len;

    // -------------------------------------------------------------------------
    // Byte-level plumbing
    // -------------------------------------------------------------------------
    logic [7:0] tx_byte;
    logic [2:0] tx_bit;
    logic [7:0] rx_sr;
    logic [2:0] rx_bit;

    logic [7:0] tx_q [$];      // bytes queued to send
    logic [7:0] cmd_buf [$];   // command bytes being collected

    // Busy is modelled as a byte-time count rather than a queue entry, because
    // it is unbounded in principle and the host must tolerate any length.
    int unsigned busy_bytes;

    always_comb sd_miso = sd_cs_n ? 1'b1 : tx_byte[tx_bit];

    // -------------------------------------------------------------------------
    // CRC helpers - the same polynomials the RTL uses, written independently
    // -------------------------------------------------------------------------
    function automatic logic [6:0] crc7_of(input logic [7:0] d []);
        logic [6:0] c; logic fb; int i, b;
        begin
            c = '0;
            for (i = 0; i < d.size(); i++)
                for (b = 7; b >= 0; b--) begin
                    fb = d[i][b] ^ c[6];
                    c  = {c[5:0], 1'b0};
                    if (fb) c = c ^ 7'h09;
                end
            return c;
        end
    endfunction

    function automatic logic [15:0] crc16_of(input logic [7:0] d []);
        logic [15:0] c; logic fb; int i, b;
        begin
            c = '0;
            for (i = 0; i < d.size(); i++)
                for (b = 7; b >= 0; b--) begin
                    fb = d[i][b] ^ c[15];
                    c  = {c[14:0], 1'b0};
                    if (fb) c = c ^ 16'h1021;
                end
            return c;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Transmit: MISO changes on the falling edge
    // -------------------------------------------------------------------------
    always @(negedge sd_clk or posedge sd_cs_n) begin
        if (sd_cs_n) begin
            tx_byte <= 8'hFF;
            tx_bit  <= 3'd7;
        end else begin
            if (tx_bit == 3'd0) begin
                tx_bit <= 3'd7;
                // Queued bytes take priority over busy, and the order matters:
                // §7.2.4 puts the data-response token BEFORE the busy period,
                // and states that internal programming only begins a byte after
                // it. Asserting busy first would put 0x00 where the host
                // expects the response, which a correct host reports as a write
                // error - blaming the controller for a fault in the model.
                if (tx_q.size() > 0) begin
                    tx_byte <= tx_q.pop_front();
                end else if (busy_bytes > 0) begin
                    // Busy: the card holds the line low. Any non-zero byte
                    // means ready, so zero is the only thing that means busy.
                    tx_byte    <= 8'h00;
                    if (!inj_busy_forever) busy_bytes <= busy_bytes - 1;
                end else begin
                    tx_byte <= 8'hFF;
                end
            end else begin
                tx_bit <= tx_bit - 3'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Receive: MOSI sampled on the rising edge
    // -------------------------------------------------------------------------
    logic [7:0] rx_byte;

    // Byte assembly and byte HANDLING must happen on the same clock edge.
    //
    // Registering a "byte complete" strobe and acting on it in a separate
    // always block defers every byte by one clock edge - which is invisible
    // mid-transaction, and badly wrong at the end of one: the final byte is
    // then not processed until the NEXT transaction supplies a ninth edge. A
    // stop-tran token closing a multi-block write appears to arrive during the
    // following command, and the model reports the host as out of sync when it
    // is the model that is late.
    logic byte_done;
    always_comb byte_done = !sd_cs_n && (rx_bit == 3'd7);
    always_comb rx_byte   = {rx_sr[6:0], sd_mosi};

    always @(posedge sd_clk or posedge sd_cs_n) begin
        if (sd_cs_n) begin
            rx_bit <= 3'd0;
            rx_sr  <= '0;
        end else begin
            rx_sr  <= {rx_sr[6:0], sd_mosi};
            rx_bit <= rx_bit + 3'd1;
        end
    end

    // -------------------------------------------------------------------------
    // Protocol engine
    // -------------------------------------------------------------------------
    typedef enum { P_CMD, P_WAIT_WR_TOKEN, P_WR_DATA, P_WR_CRC } pstate_e;
    pstate_e     pstate;
    logic [7:0]  wr_buf [$];
    logic [31:0] wr_addr;
    logic        wr_multi;
    int unsigned wr_count;

    function automatic int unsigned byte_addr(input logic [31:0] arg);
        return HIGH_CAPACITY ? (arg * 512) : arg;
    endfunction

    task automatic push_r1(input logic [7:0] r1);
        int k;
        begin
            for (k = 0; k < int'(NCR_BYTES); k++) tx_q.push_back(8'hFF);
            tx_q.push_back(r1);
        end
    endtask

    // R1 as the card would report it right now, plus any injected error bits.
    function automatic logic [7:0] make_r1();
        logic [7:0] r;
        begin
            r = 8'h00;
            if (is_idle)        r[0] = 1'b1;
            if (inj_r1_illegal) r[2] = 1'b1;
            if (inj_r1_crc)     r[3] = 1'b1;
            return r;
        end
    endfunction

    task automatic send_block(input int unsigned addr, input int unsigned len);
        logic [7:0] blk [];
        logic [15:0] c;
        int k;
        begin
            if (inj_read_err_token) begin
                // §7.3.3.3: upper nibble zero. Sent INSTEAD of a data packet.
                tx_q.push_back(8'h01);
                return;
            end
            blk = new[len];
            for (k = 0; k < len; k++)
                blk[k] = card_mem.exists(addr + k) ? card_mem[addr + k] : 8'hFF;
            c = crc16_of(blk);
            if (inj_bad_data_crc) c = c ^ 16'hFFFF;

            tx_q.push_back(8'hFE);
            for (k = 0; k < len; k++) tx_q.push_back(blk[k]);
            tx_q.push_back(c[15:8]);
            tx_q.push_back(c[7:0]);
            blocks_read++;
        end
    endtask

    task automatic handle_command(input logic [7:0] c []);
        logic [5:0]  idx;
        logic [31:0] arg;
        logic        crc_ok;
        logic [7:0]  r1;
        logic [7:0]  reg16 [];
        logic [15:0] rc;
        int k;
        begin
            idx    = c[0][5:0];
            arg    = {c[1], c[2], c[3], c[4]};
            crc_ok = ({crc7_of('{c[0], c[1], c[2], c[3], c[4]}), 1'b1} == c[5]);

            last_cmd        = idx;
            last_cmd_crc_ok = crc_ok;
            cmds_seen++;
            if (TRACE)
                $display("    [card] t=%0t CMD%0d arg=%08x crc_ok=%b idle=%b inj_ill=%b",
                         $time, idx, arg, crc_ok, is_idle, inj_r1_illegal);

            if (inj_no_response) return;

            // CMD8's CRC is always verified, and CMD0's must be valid because
            // the card is still in SD mode when it arrives (§7.2.2).
            if (!crc_ok && (crc_on || idx == 6'd0 || idx == 6'd8)) begin
                push_r1(make_r1() | 8'h08);   // Com CRC Error
                return;
            end

            r1 = make_r1();

            if (acmd_next) begin
                acmd_next = 1'b0;
                unique case (idx)
                    6'd41: begin                       // ACMD41
                        push_r1(r1);
                        is_idle = 1'b0;                // ready after one poll
                    end
                    default: push_r1(r1 | 8'h04);      // illegal
                endcase
                return;
            end

            unique case (idx)
                6'd0:  begin is_idle = 1'b1; push_r1(8'h01); end
                6'd55: begin acmd_next = 1'b1; push_r1(r1); end
                6'd59: begin crc_on = arg[0]; push_r1(r1); end

                6'd8: begin                            // R7
                    push_r1(r1);
                    // §7.3.2: when R1 reports Illegal Command or Com CRC Error
                    // the card sends ONLY that byte. Modelled unconditionally,
                    // because it is what a v1.x card does to CMD8 and it is the
                    // single easiest way to desynchronise a host.
                    if (!r1[2] && !r1[3]) begin
                        tx_q.push_back(8'h00);
                        tx_q.push_back(8'h00);
                        tx_q.push_back(8'h01);          // voltage accepted
                        tx_q.push_back(arg[7:0]);       // check pattern echo
                    end
                end

                6'd58: begin                            // R3, OCR
                    push_r1(r1);
                    if (!r1[2] && !r1[3]) begin
                        tx_q.push_back(HIGH_CAPACITY ? 8'hC0 : 8'h80);
                        tx_q.push_back(8'hFF);
                        tx_q.push_back(8'h80);
                        tx_q.push_back(8'h00);
                    end
                end

                6'd13: begin                            // R2
                    push_r1(r1);
                    if (!r1[2] && !r1[3]) tx_q.push_back(8'h00);
                end

                6'd16: begin block_len = arg; push_r1(r1); end

                6'd9, 6'd10: begin                      // CSD / CID, 16 bytes
                    push_r1(r1);
                    reg16 = new[16];
                    for (k = 0; k < 16; k++) reg16[k] = 8'(idx) + 8'(k);
                    rc = crc16_of(reg16);
                    tx_q.push_back(8'hFE);
                    for (k = 0; k < 16; k++) tx_q.push_back(reg16[k]);
                    tx_q.push_back(rc[15:8]);
                    tx_q.push_back(rc[7:0]);
                end

                6'd17: begin                            // single block read
                    push_r1(r1);
                    send_block(byte_addr(arg), int'(block_len));
                end

                6'd18: begin                            // multi-block read
                    push_r1(r1);
                    // The host stops this with CMD12; queue several blocks and
                    // let it. Any not consumed are flushed when CMD12 arrives.
                    for (k = 0; k < 8; k++)
                        send_block(byte_addr(arg) + k * int'(block_len),
                                   int'(block_len));
                end

                6'd12: begin                            // STOP_TRANSMISSION
                    tx_q.delete();
                    tx_q.push_back(8'hFF);              // §7.2.3 stuff byte
                    push_r1(r1);
                    busy_bytes = 2;
                end

                6'd24, 6'd25: begin                     // writes
                    push_r1(r1);
                    wr_addr  = byte_addr(arg);
                    wr_multi = (idx == 6'd25);
                    wr_count = 0;
                    pstate   = P_WAIT_WR_TOKEN;
                end

                default: push_r1(r1 | 8'h04);           // illegal command
            endcase
        end
    endtask

    task automatic finish_write_block();
        logic [7:0] dr;
        int k;
        begin
            if (inj_write_crc_err)      dr = 8'h0B;     // sss = 101
            else if (inj_write_err)     dr = 8'h0D;     // sss = 110
            else                        dr = 8'h05;     // sss = 010, accepted

            if (dr == 8'h05) begin
                for (k = 0; k < wr_buf.size(); k++)
                    card_mem[wr_addr + k] = wr_buf[k];
                wr_addr = wr_addr + 32'(wr_buf.size());
                blocks_written++;
            end
            tx_q.push_back(dr);
            // §7.2.4: programming starts a byte AFTER the data response, so
            // busy cannot appear immediately.
            busy_bytes = 4;
            wr_buf.delete();
        end
    endtask

    always @(posedge sd_clk) begin
        if (byte_done) begin
            unique case (pstate)

                P_CMD: begin
                    // A command byte has its top two bits '01'. Everything else
                    // on MOSI between commands is 0xFF padding.
                    if ((cmd_buf.size() > 0) || (rx_byte[7:6] == 2'b01)) begin
                        cmd_buf.push_back(rx_byte);
                        if (cmd_buf.size() == 6) begin
                            handle_command(cmd_buf);
                            cmd_buf.delete();
                        end
                    end
                end

                P_WAIT_WR_TOKEN: begin
                    if (rx_byte == 8'hFE || rx_byte == 8'hFC) begin
                        wr_buf.delete();
                        pstate <= P_WR_DATA;
                    end else if (rx_byte == 8'hFD) begin
                        busy_bytes = 2;
                        pstate     <= P_CMD;
                    end
                end

                P_WR_DATA: begin
                    wr_buf.push_back(rx_byte);
                    if (wr_buf.size() == int'(block_len)) begin
                        wr_count <= 0;
                        pstate   <= P_WR_CRC;
                    end
                end

                P_WR_CRC: begin
                    if (wr_count == 1) begin
                        finish_write_block();
                        pstate <= wr_multi ? P_WAIT_WR_TOKEN : P_CMD;
                    end else begin
                        wr_count <= wr_count + 1;
                    end
                end

                default: pstate <= P_CMD;
            endcase

            if (TRACE && (pstate == P_WAIT_WR_TOKEN) &&
                ((rx_byte == 8'hFE) || (rx_byte == 8'hFC) || (rx_byte == 8'hFD)))
                $display("    [card] t=%0t token %02x in P_WAIT_WR_TOKEN", $time, rx_byte);
        end
    end

    initial begin
        is_idle        = 1'b1;
        acmd_next      = 1'b0;
        crc_on         = 1'b0;
        block_len      = 32'd512;
        busy_bytes     = 0;
        pstate         = P_CMD;
        cmds_seen      = 0;
        blocks_read    = 0;
        blocks_written = 0;
        last_cmd       = '0;
        last_cmd_crc_ok= 1'b0;
        wr_addr        = '0;
        wr_multi       = 1'b0;
        wr_count       = 0;
    end

    // -------------------------------------------------------------------------
    // Test hooks
    // -------------------------------------------------------------------------
    function automatic void preload(input int unsigned addr, input logic [7:0] d);
        card_mem[addr] = d;
    endfunction

    function automatic logic [7:0] peek(input int unsigned addr);
        return card_mem.exists(addr) ? card_mem[addr] : 8'hFF;
    endfunction

endmodule : spi_card_model
