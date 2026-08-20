`timescale 1ns/1ps

// =============================================================================
// wave_capture_tb.sv
//
// Drives the four scenarios the user guide's timing figures are rendered from,
// and dumps a VCD. It is NOT part of the regression - it checks nothing. Its
// only job is to produce a recording that doc/tools/waveforms/mkwaves.py cuts
// figures out of.
//
// The point of generating figures from a real VCD rather than drawing them is
// that they cannot drift away from the RTL. Change the design and either the
// figure changes with it, or the scenario stops matching and mkwaves.py fails
// loudly. A hand-drawn timing diagram just quietly becomes fiction.
//
// `marker` tags the windows the renderer cuts:
//   1  permitted write burst, passing straight through
//   2  refused read burst, answered by the firewall
//   3  read timeout against a peripheral with waitrequest stuck high
//   4  the recovery sequence
//
// TIMEOUT_VALUE is set to 10 cycles here purely so the timeout figure fits on
// a page. A real system uses thousands.
//
// Build and run it with the script next to it:
//
//   ./capture.sh                        # writes wave.vcd
//
// (A comment line here must not begin with the tool's own name - the lexer
// reads such a comment as a pragma and rejects the line that follows.)
// =============================================================================

module wave_capture_tb;

    localparam int AW = 32, DW = 32, BW = 8, NR = 4, TW = 20, CAW = 8;

    localparam int W_CTRL = 0, W_STATUS = 1, W_TIMEOUT = 3, W_RECOVERY = 7;
    localparam int W_RULE = 'h10;
    localparam int P_RD = 1, P_WR = 2, P_VALID = 4, P_BURST = 8;

    localparam logic [31:0] A_RW = 32'h0000_1000;   // read/write, bursts OK
    localparam logic [31:0] A_WO = 32'h0000_2000;   // write-only

    int marker = 0;

    logic clk = 0, reset_n = 0;
    always #5 clk = ~clk;

    // ---- s0, driven as the master ----
    logic [AW-1:0] s_addr = 0;
    logic          s_read = 0, s_write = 0;
    logic [DW-1:0] s_wdata = 0;
    logic [DW/8-1:0] s_be = '1;
    logic [BW-1:0] s_burst = 1;
    logic          s_wait;
    logic [DW-1:0] s_rdata;
    logic          s_rdv;
    logic [1:0]    s_resp;
    logic          s_wresp;

    // ---- m0, toward the peripheral model ----
    logic [AW-1:0] m_addr;
    logic          m_read, m_write;
    logic [DW-1:0] m_wdata;
    logic [DW/8-1:0] m_be;
    logic [BW-1:0] m_burst;
    logic          m_wait;
    logic [DW-1:0] m_rdata = 0;
    logic          m_rdv = 0;
    logic [1:0]    m_resp;
    logic          m_wresp = 0;

    // ---- csr, driven as management software ----
    logic [CAW-1:0] c_addr = 0;
    logic           c_read = 0, c_write = 0;
    logic [31:0]    c_wdata = 0;
    logic [3:0]     c_be = 4'hF;
    logic [31:0]    c_rdata;

    logic irq;

    // The peripheral reset the system integrator owns. The core does not drive
    // it; the figures show it as an external signal for exactly that reason.
    logic periph_rst_n = 1;

    avl_mm_firewall_top #(
        .ADDR_WIDTH(AW), .DATA_WIDTH(DW), .BURST_WIDTH(BW),
        .MAX_PENDING_READS(4), .NUM_RULES(NR), .TIMEOUT_WIDTH(TW),
        .CSR_ADDR_WIDTH(CAW), .USE_WRITE_RESPONSE(0)
    ) dut (
        .clk(clk), .reset_n(reset_n),
        .s0_address(s_addr), .s0_read(s_read), .s0_write(s_write),
        .s0_writedata(s_wdata), .s0_byteenable(s_be), .s0_burstcount(s_burst),
        .s0_waitrequest(s_wait), .s0_readdata(s_rdata), .s0_readdatavalid(s_rdv),
        .s0_response(s_resp), .s0_writeresponsevalid(s_wresp),
        .m0_address(m_addr), .m0_read(m_read), .m0_write(m_write),
        .m0_writedata(m_wdata), .m0_byteenable(m_be), .m0_burstcount(m_burst),
        .m0_waitrequest(m_wait), .m0_readdata(m_rdata), .m0_readdatavalid(m_rdv),
        .m0_response(m_resp), .m0_writeresponsevalid(m_wresp),
        .csr_address(c_addr), .csr_read(c_read), .csr_write(c_write),
        .csr_writedata(c_wdata), .csr_byteenable(c_be), .csr_readdata(c_rdata),
        .irq(irq)
    );

    // ------------------------------------------------------------------
    // Minimal bursting peripheral. hang=1 makes waitrequest stick high, which
    // is the Avalon-MM hang mode the timeout figure is about.
    // ------------------------------------------------------------------
    logic hang = 0;
    logic [BW:0] rd_left = 0;
    logic [AW-1:0] rd_addr = 0;

    assign m_wait = hang || !periph_rst_n;
    assign m_resp = 2'b00;

    always_ff @(posedge clk) begin
        if (!reset_n || !periph_rst_n) begin
            rd_left <= 0;
            m_rdv   <= 1'b0;
            m_rdata <= '0;
        end else begin
            m_rdv <= 1'b0;
            if (m_read && !m_wait) begin
                rd_left <= {1'b0, m_burst};
                rd_addr <= m_addr;
            end else if (rd_left != 0) begin
                m_rdv   <= 1'b1;
                m_rdata <= 32'hC0DE_0000 | rd_addr[15:0];
                rd_addr <= rd_addr + 4;
                rd_left <= rd_left - 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // BFM. Same discipline as the regression bench: drive one delta after an
    // edge, and sample handshakes through registered flags rather than reading
    // a combinational output in the timestep that drove its input.
    // ------------------------------------------------------------------
    logic wr_hs = 0, rd_hs = 0;
    always @(posedge clk) begin
        wr_hs <= reset_n && s_write && !s_wait;
        rd_hs <= reset_n && s_read  && !s_wait;
    end

    task automatic tick; @(posedge clk); #1; endtask
    task automatic ticks(input int n); for (int i = 0; i < n; i++) tick; endtask

    task automatic csr_wr(input int wa, input logic [31:0] d);
        tick; c_addr = CAW'(wa); c_wdata = d; c_be = 4'hF; c_write = 1'b1;
        tick; c_write = 1'b0;
    endtask

    task automatic wr_burst(input logic [31:0] a, input int n, input logic [31:0] seed);
        int got;
        tick;
        s_addr = a; s_burst = BW'(n); s_be = '1; s_write = 1'b1; s_wdata = seed;
        got = 0;
        while (got < n) begin
            tick;
            if (wr_hs) begin got++; s_wdata = seed + got; end
        end
        s_write = 1'b0;
    endtask

    task automatic rd_cmd(input logic [31:0] a, input int n);
        tick;
        s_addr = a; s_burst = BW'(n); s_read = 1'b1;
        do tick; while (!rd_hs);
        s_read = 1'b0;
    endtask

    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, wave_capture_tb);

        reset_n = 0; ticks(4); reset_n = 1; ticks(2);

        // Rule 0: read/write with bursts.  Rule 1: write-only.
        csr_wr(W_RULE + 0*4 + 0, A_RW);
        csr_wr(W_RULE + 0*4 + 1, A_RW + 32'hFFF);
        csr_wr(W_RULE + 0*4 + 2, P_VALID|P_RD|P_WR|P_BURST);
        csr_wr(W_RULE + 1*4 + 0, A_WO);
        csr_wr(W_RULE + 1*4 + 1, A_WO + 32'hFFF);
        csr_wr(W_RULE + 1*4 + 2, P_VALID|P_WR|P_BURST);
        csr_wr(W_TIMEOUT, 32'd10);           // short, so the figure fits
        ticks(4);

        // ---- 1: permitted write burst, straight through ----
        marker = 1; ticks(1);
        wr_burst(A_RW, 4, 32'hA000_0001);
        ticks(6);
        marker = 0; ticks(2);

        // ---- 2: refused read burst - the firewall answers ----
        marker = 2; ticks(1);
        rd_cmd(A_WO, 4);                     // read from a write-only window
        ticks(10);
        marker = 0; ticks(2);
        csr_wr(W_STATUS, 32'hF);             // acknowledge
        ticks(4);

        // ---- 3: read timeout, waitrequest stuck high ----
        marker = 3; ticks(1);
        hang = 1;
        rd_cmd(A_RW, 4);
        ticks(16);
        marker = 0; ticks(2);

        // ---- 4: the recovery sequence ----
        marker = 4; ticks(1);
        hang = 0;
        csr_wr(W_STATUS, 32'hF);             // step 2: acknowledge
        ticks(2);
        periph_rst_n = 0;                    // step 4: hold the peripheral in reset
        ticks(6);
        csr_wr(W_RECOVERY, 32'h1);           // step 5: unblock, still in reset
        ticks(2);
        periph_rst_n = 1;                    // step 6: release
        ticks(4);
        wr_burst(A_RW, 2, 32'hB000_0001);    // step 7: traffic works again
        ticks(6);
        marker = 0; ticks(4);

        $display("wave.vcd written");
        $finish;
    end

endmodule
