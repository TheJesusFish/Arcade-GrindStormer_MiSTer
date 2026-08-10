`timescale 1ns/1ps

module m10k_latency_tb;

reg clk = 1'b0;
always #5 clk = ~clk;

reg  [15:0] data0 = 16'd0;
reg  [3:1]  addr0 = 3'd0;
reg  [1:0]  we0 = 2'b00;
wire [15:0] q0;
reg  [15:0] data1 = 16'd0;
reg  [3:1]  addr1 = 3'd0;
reg  [1:0]  we1 = 2'b00;
wire [15:0] q1;

jtframe_dual_ram16 #(.AW(3)) dut (
    .clk0  (clk),
    .data0 (data0),
    .addr0 (addr0),
    .we0   (we0),
    .q0    (q0),
    .clk1  (clk),
    .data1 (data1),
    .addr1 (addr1),
    .we1   (we1),
    .q1    (q1)
);

initial begin
    // Seed two words through port A.
    @(negedge clk);
    addr0 = 3'd1;
    data0 = 16'h1234;
    we0 = 2'b11;
    @(posedge clk);
    #1;
    @(negedge clk);
    addr0 = 3'd2;
    data0 = 16'h5678;
    we0 = 2'b11;
    @(posedge clk);
    #1;
    we0 = 2'b00;

    // Port B captures address 1 at the edge.
    @(negedge clk);
    addr1 = 3'd1;
    @(posedge clk);
    #1;
    if (q1 !== 16'h1234)
        $fatal(1, "registered read of address 1 returned %04x", q1);

    // Changing the address between edges cannot change q.
    @(negedge clk);
    addr1 = 3'd2;
    #1;
    if (q1 !== 16'h1234)
        $fatal(1, "RAM output changed before the address clock edge");
    @(posedge clk);
    #1;
    if (q1 !== 16'h5678)
        $fatal(1, "registered read of address 2 returned %04x", q1);

    // Same-edge read/write returns old data, then the byte-enabled update.
    @(negedge clk);
    addr0 = 3'd2;
    data0 = 16'h00aa;
    we0 = 2'b01;
    @(posedge clk);
    #1;
    if (q1 !== 16'h5678)
        $fatal(1, "M10K read-during-write did not return old data");
    @(negedge clk);
    we0 = 2'b00;
    @(posedge clk);
    #1;
    if (q1 !== 16'h56aa)
        $fatal(1, "low-byte write enable produced %04x", q1);

    @(negedge clk);
    data0 = 16'hbb00;
    we0 = 2'b10;
    @(posedge clk);
    #1;
    @(negedge clk);
    we0 = 2'b00;
    @(posedge clk);
    #1;
    if (q1 !== 16'hbbaa)
        $fatal(1, "high-byte write enable produced %04x", q1);

    $display("PASS m10k_latency_tb");
    $finish;
end

endmodule
