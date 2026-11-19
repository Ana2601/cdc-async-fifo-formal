// Dual-clock FIFO (Cummings style): binary pointers for addressing, Gray-coded
// pointers crossed through 2-flop synchronisers. full/empty are computed in
// their own domains and are conservative: a stale synchronised pointer can only
// make the FIFO look fuller (write side) or emptier (read side), never the
// other way, so overflow and underflow are impossible.
//
// Read data is first-word-fall-through: rdata is valid whenever !empty.
module async_fifo #(
    parameter integer W  = 16,
    parameter integer AW = 4            // depth = 2**AW
) (
    input  wire         wclk,
    input  wire         wrst_n,
    input  wire         winc,
    input  wire [W-1:0] wdata,
    output reg          wfull,
    output wire [AW:0]  wlevel,         // conservative fill level seen by the writer

    input  wire         rclk,
    input  wire         rrst_n,
    input  wire         rinc,
    output wire [W-1:0] rdata,
    output reg          rempty,
    output wire [AW:0]  rlevel          // conservative fill level seen by the reader
`ifdef FORMAL
    ,
    output wire [AW:0]  f_wbin,
    output wire [AW:0]  f_rbin,
    output wire [AW:0]  f_wgray,
    output wire [AW:0]  f_rgray,
    output wire [AW:0]  f_wq2_rgray,
    output wire [AW:0]  f_rq2_wgray,
    output wire [AW:0]  f_wq1_rgray,
    output wire [AW:0]  f_rq1_wgray,
    input  wire [AW-1:0] f_addr,
    output wire [W-1:0]  f_word
`endif
);
    reg [W-1:0] mem [0:(1<<AW)-1];

    reg [AW:0] wbin, wgray, rbin, rgray;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wq1_rgray, wq2_rgray;   // read pointer in the write domain
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rq1_wgray, rq2_wgray;   // write pointer in the read domain

    function automatic [AW:0] bin2gray(input [AW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction
    function automatic [AW:0] gray2bin(input [AW:0] g);
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    // ------------------------------------------------------------ write domain
    wire        wpush      = winc && !wfull;
    wire [AW:0] wbin_next  = wbin + {{AW{1'b0}}, wpush};
    wire [AW:0] wgray_next = bin2gray(wbin_next);
    // full: next write pointer equals the read pointer with the two MSBs inverted
    wire        wfull_next = (wgray_next == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});

    always @(posedge wclk) if (wpush) mem[wbin[AW-1:0]] <= wdata;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin <= 0; wgray <= 0; wfull <= 1'b0; wq1_rgray <= 0; wq2_rgray <= 0;
        end else begin
            wbin <= wbin_next; wgray <= wgray_next; wfull <= wfull_next;
            {wq2_rgray, wq1_rgray} <= {wq1_rgray, rgray};
        end
    end
    assign wlevel = wbin - gray2bin(wq2_rgray);

    // ------------------------------------------------------------ read domain
    wire        rpop        = rinc && !rempty;
    wire [AW:0] rbin_next   = rbin + {{AW{1'b0}}, rpop};
    wire [AW:0] rgray_next  = bin2gray(rbin_next);
    wire        rempty_next = (rgray_next == rq2_wgray);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin <= 0; rgray <= 0; rempty <= 1'b1; rq1_wgray <= 0; rq2_wgray <= 0;
        end else begin
            rbin <= rbin_next; rgray <= rgray_next; rempty <= rempty_next;
            {rq2_wgray, rq1_wgray} <= {rq1_wgray, wgray};
        end
    end
    assign rdata  = mem[rbin[AW-1:0]];
    assign rlevel = gray2bin(rq2_wgray) - rbin;

`ifdef FORMAL
    assign f_wbin = wbin;           assign f_rbin = rbin;
    assign f_wgray = wgray;         assign f_rgray = rgray;
    assign f_wq2_rgray = wq2_rgray; assign f_rq2_wgray = rq2_wgray;
    assign f_wq1_rgray = wq1_rgray; assign f_rq1_wgray = rq1_wgray;
    assign f_word = mem[f_addr];
`endif
endmodule
