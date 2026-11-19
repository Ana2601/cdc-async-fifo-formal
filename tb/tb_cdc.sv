`timescale 1ps/1ps
// Simulation of the async FIFO and the CDC primitives across many clock ratios.
// Clock periods are passed as plusargs; the Makefile sweeps slow->fast and
// fast->slow ratios with non-integer relationships and random start phases.
module tb_cdc;
    integer WPER = 10000, RPER = 13000, N = 20000;
    reg wclk = 0, rclk = 0, arst_n = 0;

    initial begin
        void'($value$plusargs("wper=%d", WPER));
        void'($value$plusargs("rper=%d", RPER));
        void'($value$plusargs("n=%d", N));
        #($urandom_range(0, WPER));
        forever #(WPER / 2) wclk = ~wclk;
    end
    initial begin
        #($urandom_range(0, RPER));
        forever #(RPER / 2) rclk = ~rclk;
    end

    // reset bridges: asynchronous assert, synchronous release per domain
    wire wrst_n, rrst_n;
    cdc_reset_sync u_wrst (.clk(wclk), .arst_n(arst_n), .rst_n(wrst_n));
    cdc_reset_sync u_rrst (.clk(rclk), .arst_n(arst_n), .rst_n(rrst_n));

    // ------------------------------------------------------------ async FIFO
    reg         winc = 0, rinc = 0;
    reg  [15:0] wdata = 0;
    wire        wfull, rempty;
    wire [15:0] rdata;
    wire [4:0]  wlevel, rlevel;

    async_fifo #(.W(16), .AW(4)) u_fifo (
        .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(wfull), .wlevel(wlevel),
        .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(rdata), .rempty(rempty), .rlevel(rlevel)
    );

    integer wr_cnt = 0, rd_cnt = 0, errors = 0, full_cycles = 0, empty_cycles = 0;
    integer w_burst = 0, r_burst = 0;

    // writer: bursty traffic so the FIFO swings between full and empty.
    // Word number k carries the value k * 40503 (mod 2^16).
    always @(posedge wclk) if (wrst_n) begin
        if (winc && !wfull) wr_cnt = wr_cnt + 1;
        full_cycles = full_cycles + wfull;
        if (wlevel > 16) begin errors = errors + 1; $display("ERROR wlevel %0d", wlevel); end
        if (w_burst == 0) w_burst = $urandom_range(1, 40) * (($urandom_range(0, 1)) ? 1 : -1);
        winc  <= (wr_cnt < N) && (w_burst > 0);
        wdata <= 16'(wr_cnt * 40503);
        w_burst = (w_burst > 0) ? w_burst - 1 : w_burst + 1;
    end

    always @(posedge rclk) if (rrst_n) begin
        if (rinc && !rempty) begin
            if (rdata !== 16'(rd_cnt * 40503)) begin
                errors = errors + 1;
                if (errors < 10) $display("ERROR read #%0d got %h expected %h", rd_cnt, rdata, 16'(rd_cnt * 40503));
            end
            rd_cnt = rd_cnt + 1;
        end
        empty_cycles = empty_cycles + rempty;
        if (rlevel > 16) begin errors = errors + 1; $display("ERROR rlevel %0d", rlevel); end
        if (r_burst == 0) r_burst = $urandom_range(1, 40) * (($urandom_range(0, 1)) ? 1 : -1);
        rinc <= (r_burst > 0);
        r_burst = (r_burst > 0) ? r_burst - 1 : r_burst + 1;
    end

    // ------------------------------------------------------------ pulse synchroniser
    reg  p_src = 0;
    wire p_dst;
    integer p_sent = 0, p_recv = 0, p_gap = 0;
    cdc_pulse_sync u_pulse (.src_clk(wclk), .src_rst_n(wrst_n), .src_pulse(p_src),
                            .dst_clk(rclk), .dst_rst_n(rrst_n), .dst_pulse(p_dst));
    // pulses kept apart by the documented minimum (2 dst cycles + 1 src cycle, plus margin)
    always @(posedge wclk) if (wrst_n) begin
        p_src <= 0;
        p_gap = p_gap + 1;
        if (p_gap * WPER > 3 * RPER + 2 * WPER && $urandom_range(0, 3) == 0 && p_sent < 500) begin
            p_src <= 1; p_sent = p_sent + 1; p_gap = 0;
        end
    end
    always @(posedge rclk) if (rrst_n && p_dst) p_recv = p_recv + 1;

    // ------------------------------------------------------------ handshake bus synchroniser
    reg         h_valid = 0;
    reg  [31:0] h_data = 0;
    wire        h_ready, h_dvalid;
    wire [31:0] h_ddata;
    integer h_sent = 0, h_recv = 0;
    cdc_handshake #(.W(32)) u_hs (.src_clk(wclk), .src_rst_n(wrst_n), .src_valid(h_valid), .src_ready(h_ready),
                                 .src_data(h_data), .dst_clk(rclk), .dst_rst_n(rrst_n),
                                 .dst_valid(h_dvalid), .dst_data(h_ddata));
    always @(posedge wclk) if (wrst_n) begin
        if (h_valid && h_ready) begin h_sent = h_sent + 1; h_valid <= 0; end
        else if (!h_valid && h_sent < 300) begin h_valid <= 1; h_data <= h_sent * 32'h9E3779B9; end
    end
    always @(posedge rclk) if (rrst_n && h_dvalid) begin
        if (h_ddata !== h_recv * 32'h9E3779B9) begin
            errors = errors + 1; $display("ERROR handshake word %0d got %h", h_recv, h_ddata);
        end
        h_recv = h_recv + 1;
    end

    // ------------------------------------------------------------ end of test
    initial begin
        #(3 * (WPER + RPER)) arst_n = 1;
        wait (rd_cnt == N && h_recv == 300 && p_sent == 500);
        #(10 * (WPER + RPER));
        $display("wclk %0d ps / rclk %0d ps (ratio %.2f): FIFO %0d words, full %0d wclk cycles, empty %0d rclk cycles; pulses %0d/%0d; handshake %0d/%0d; errors %0d",
                 WPER, RPER, 1.0 * RPER / WPER, rd_cnt, full_cycles, empty_cycles, p_recv, p_sent, h_recv, h_sent, errors);
        if (errors != 0 || p_recv != p_sent || wr_cnt != N) $fatal(1, "TEST FAILED");
        $display("TEST PASSED");
        $finish;
    end
    initial begin #(64'd400 * N * (WPER + RPER)); $fatal(1, "timeout (deadlock?)"); end
endmodule
