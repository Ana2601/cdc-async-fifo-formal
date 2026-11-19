// Multi-clock formal harness for async_fifo.
//
// wclk and rclk are free inputs: the solver chooses their edges, so every
// phase relationship is covered, with frequency ratios up to 3:1 either way
// (fairness assumption below). Simulation covers more extreme ratios.
// Proved properties (k-induction):
//   * no overflow / underflow: the true occupancy is always 0..DEPTH
//   * full and empty are never optimistic
//   * Gray pointers change by exactly one bit per update (safe to synchronise)
//   * data integrity: an arbitrarily chosen write is read back intact and in order
module async_fifo_formal #(parameter integer W = 4, AW = 2) (
    input wire         wclk,
    input wire         rclk,
    input wire         winc,
    input wire [W-1:0] wdata,
    input wire         rinc
);
    localparam integer D = 1 << AW;

    reg f_init = 1'b1;
    (* gclk *) wire gclk;
    always @(posedge gclk) f_init <= 1'b0;

    // hold both domains in reset for the first global step only
    wire rst_n = !f_init;

    // fairness: each clock toggles at least once every 3 solver steps.
    // Phase and ratio are otherwise unconstrained (covers ratios up to 3:1).
    reg wclk_q, rclk_q;
    reg [1:0] whold = 0, rhold = 0;
    always @(posedge gclk) begin
        wclk_q <= wclk; rclk_q <= rclk;
        whold  <= (wclk == wclk_q) ? whold + 1'b1 : 2'd0;
        rhold  <= (rclk == rclk_q) ? rhold + 1'b1 : 2'd0;
    end
    always @(*) begin
        assume (whold < 2'd3);
        assume (rhold < 2'd3);
    end

    wire         wfull, rempty;
    wire [W-1:0] rdata;
    wire [AW:0]  wbin, rbin, wgray, rgray, wq2, rq2, wq1, rq1;
    wire [W-1:0] f_word;
    (* anyconst *) wire [AW:0] f_ptr;

    async_fifo #(.W(W), .AW(AW)) dut (
        .wclk(wclk), .wrst_n(rst_n), .winc(winc), .wdata(wdata), .wfull(wfull), .wlevel(),
        .rclk(rclk), .rrst_n(rst_n), .rinc(rinc), .rdata(rdata), .rempty(rempty), .rlevel(),
        .f_wbin(wbin), .f_rbin(rbin), .f_wgray(wgray), .f_rgray(rgray),
        .f_wq2_rgray(wq2), .f_rq2_wgray(rq2), .f_wq1_rgray(wq1), .f_rq1_wgray(rq1),
        .f_addr(f_ptr[AW-1:0]), .f_word(f_word)
    );

    function automatic [AW:0] g2b(input [AW:0] g);
        integer i;
        begin
            g2b[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1) g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction
    function automatic onehot0(input [AW:0] x);   // zero or one bit set
        onehot0 = ((x & (x - 1'b1)) == 0);
    endfunction

    // pointer distance, modulo 2^(AW+1). Must stay AW+1 bits wide: in a 32-bit
    // context a wrapped difference such as 0 - 4 would become a huge number.
    function automatic [AW:0] dist(input [AW:0] to, input [AW:0] from);
        dist = to - from;
    endfunction

    wire [AW:0] occ = wbin - rbin;

    // ---- data integrity: watch the write that lands at pointer value f_ptr
    reg [W-1:0] f_val;
    reg         f_wtog = 1'b0, f_rtog = 1'b0;   // one toggle per domain: no multi-driven state
    wire        f_armed = f_wtog ^ f_rtog;
    wire wpush = winc && !wfull;
    wire rpop  = rinc && !rempty;
    wire [AW:0] f_off = f_ptr - rbin;            // distance of the watched slot from the read pointer

    always @(posedge wclk) if (rst_n && wpush && wbin == f_ptr) begin
        f_val <= wdata; f_wtog <= ~f_wtog;
    end
    always @(posedge rclk) if (rst_n && rpop && rbin == f_ptr) f_rtog <= ~f_rtog;

    always @(*) if (rst_n) begin
        // structural invariants (also what makes the proof inductive)
        assert (occ <= D);
        assert (wgray == (wbin ^ (wbin >> 1)));
        assert (rgray == (rbin ^ (rbin >> 1)));
        // synchronised copies are OLDER values of the real pointer, in order:
        //   writer's view of the read pointer:  wq2 <= wq1 <= rbin <= wbin
        //   reader's view of the write pointer: rbin <= rq2 <= rq1 <= wbin
        assert (dist(rbin, g2b(wq1)) <= dist(rbin, g2b(wq2)));
        assert (dist(wbin, g2b(wq2)) <= D);
        assert (dist(wbin, g2b(wq1)) <= dist(wbin, g2b(wq2)));
        assert (dist(g2b(wq1), g2b(wq2)) <= dist(rbin, g2b(wq2)));
        assert (dist(g2b(rq1), g2b(rq2)) <= dist(wbin, g2b(rq2)));
        assert (dist(rbin, g2b(wq2)) <= dist(wbin, g2b(wq2)));
        assert (dist(wbin, g2b(rq1)) <= dist(wbin, g2b(rq2)));
        assert (dist(g2b(rq2), rbin) <= occ);
        assert (dist(g2b(rq1), rbin) <= occ);
        // the registered flags are never optimistic w.r.t. the synchronised pointers
        if (dist(wbin, g2b(wq2)) == D) assert (wfull);
        if (g2b(rq2) == rbin)       assert (rempty);
        // conservative flags
        if (occ == D) assert (wfull);
        if (occ == 0) assert (rempty);
        // the watched entry
        if (f_armed) begin
            assert (f_off < occ);
            assert (f_word == f_val);
        end else begin
            assert (!(f_off < occ));
        end
        if (f_armed && rbin == f_ptr && !rempty) assert (rdata == f_val);
    end

    // Gray pointers move by one bit per clock edge
    reg [AW:0] wgray_q, rgray_q;
    always @(posedge gclk) begin wgray_q <= wgray; rgray_q <= rgray; end
    always @(*) if (rst_n && !f_init) assert (onehot0(wgray ^ wgray_q) && onehot0(rgray ^ rgray_q));

    // reachability
    always @(*) if (rst_n) begin
        cover (wfull);
        cover (f_armed && rbin == f_ptr && !rempty && occ == D);
    end
endmodule
