// Clock-domain-crossing primitives.
//
//   cdc_sync_bit   N-flop synchroniser for a single level signal
//   cdc_reset_sync asynchronous-assert / synchronous-deassert reset bridge
//   cdc_pulse_sync single-cycle pulse across domains (toggle + edge detect)
//   cdc_handshake  multi-bit bus crossing with a 4-phase req/ack handshake
//
// All synchroniser flops carry (* ASYNC_REG = "TRUE" *) so Vivado places them
// in one slice and STA/CDC tools recognise them.

module cdc_sync_bit #(
    parameter integer STAGES = 2,
    parameter [0:0]   INIT   = 1'b0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire d,          // from another clock domain
    output wire q
);
    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) sync <= {STAGES{INIT}};
        else        sync <= {sync[STAGES-2:0], d};
    assign q = sync[STAGES-1];
endmodule

module cdc_reset_sync #(
    parameter integer STAGES = 2
) (
    input  wire clk,
    input  wire arst_n,     // asynchronous, from anywhere
    output wire rst_n       // asserts immediately, releases synchronously to clk
);
    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] sync;
    always @(posedge clk or negedge arst_n)
        if (!arst_n) sync <= {STAGES{1'b0}};
        else         sync <= {sync[STAGES-2:0], 1'b1};
    assign rst_n = sync[STAGES-1];
endmodule

// Pulses on src must be at least 2 dst cycles + 1 src cycle apart.
module cdc_pulse_sync (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_pulse,
    input  wire dst_clk,
    input  wire dst_rst_n,
    output wire dst_pulse
);
    reg tgl;
    always @(posedge src_clk or negedge src_rst_n)
        if (!src_rst_n)     tgl <= 1'b0;
        else if (src_pulse) tgl <= ~tgl;

    wire tgl_s;
    cdc_sync_bit #(.STAGES(2)) u_sync (.clk(dst_clk), .rst_n(dst_rst_n), .d(tgl), .q(tgl_s));

    reg tgl_d;
    always @(posedge dst_clk or negedge dst_rst_n)
        if (!dst_rst_n) tgl_d <= 1'b0;
        else            tgl_d <= tgl_s;
    assign dst_pulse = tgl_s ^ tgl_d;
endmodule

// The data bus is held stable from req until ack returns, so the destination
// can sample it directly once req has been synchronised (no bus synchronisers).
module cdc_handshake #(
    parameter integer W = 32
) (
    input  wire         src_clk,
    input  wire         src_rst_n,
    input  wire         src_valid,
    output wire         src_ready,
    input  wire [W-1:0] src_data,

    input  wire         dst_clk,
    input  wire         dst_rst_n,
    output reg          dst_valid,      // one-cycle pulse
    output reg  [W-1:0] dst_data
);
    reg         req;
    reg [W-1:0] hold;
    wire        ack_s, req_s;
    reg         req_d;
    reg         ack;

    // source: raise req with data held, wait for ack to rise, drop req, wait for ack to fall
    assign src_ready = !req && !ack_s;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            req <= 1'b0; hold <= {W{1'b0}};
        end else if (src_valid && src_ready) begin
            req <= 1'b1; hold <= src_data;
        end else if (req && ack_s) begin
            req <= 1'b0;
        end
    end

    cdc_sync_bit u_req (.clk(dst_clk), .rst_n(dst_rst_n), .d(req), .q(req_s));
    cdc_sync_bit u_ack (.clk(src_clk), .rst_n(src_rst_n), .d(ack), .q(ack_s));

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            req_d <= 1'b0; ack <= 1'b0; dst_valid <= 1'b0; dst_data <= {W{1'b0}};
        end else begin
            req_d     <= req_s;
            ack       <= req_s;
            dst_valid <= req_s && !req_d;
            if (req_s && !req_d) dst_data <= hold;   // stable for >= 2 dst cycles by construction
        end
    end
endmodule
