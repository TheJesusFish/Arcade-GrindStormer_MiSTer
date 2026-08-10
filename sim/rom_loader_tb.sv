`timescale 1ns/1ps

module rom_loader_tb;

reg clk = 1'b0;
reg rst = 1'b1;
reg ioctl_rom = 1'b0;
reg [26:0] ioctl_addr = 27'd0;
reg [7:0] ioctl_dout = 8'd0;
reg ioctl_wr = 1'b0;
wire dwnld_busy;
wire [1:0] prog_ba;
wire [21:0] prog_addr;
wire [15:0] prog_data;
wire [1:0] prog_mask;
wire prog_rd;
wire prog_we;
reg prog_rdy = 1'b1;
reg prog_ack = 1'b0;
wire accepted;
wire range_error;
wire overflow_error;
wire [26:0] last_addr;
reg sampled_accepted = 1'b0;

always #5 clk = ~clk;
always @(posedge clk)
    sampled_accepted <= accepted;

grind_stormer_rom_loader dut (
    .clk            (clk),
    .rst            (rst),
    .ioctl_rom      (ioctl_rom),
    .ioctl_addr     (ioctl_addr),
    .ioctl_dout     (ioctl_dout),
    .ioctl_wr       (ioctl_wr),
    .dwnld_busy     (dwnld_busy),
    .prog_ba        (prog_ba),
    .prog_addr      (prog_addr),
    .prog_data      (prog_data),
    .prog_mask      (prog_mask),
    .prog_rd        (prog_rd),
    .prog_we        (prog_we),
    .prog_rdy       (prog_rdy),
    .prog_ack       (prog_ack),
    .accepted       (accepted),
    .range_error    (range_error),
    .overflow_error (overflow_error),
    .last_addr      (last_addr)
);

task automatic issue_and_check;
    input [26:0] address;
    input [7:0] byte_value;
    input [1:0] expected_bank;
    input [21:0] expected_address;
    input [1:0] expected_mask;
    begin
        @(negedge clk);
        ioctl_rom <= 1'b1;
        ioctl_wr <= 1'b1;
        ioctl_addr <= address;
        ioctl_dout <= byte_value;
        @(posedge clk);
        #1;
        if (!sampled_accepted || !prog_we)
            $fatal(1, "byte %x was not accepted", address);
        if (prog_ba != expected_bank ||
            prog_addr != expected_address ||
            prog_mask != expected_mask ||
            prog_data != {byte_value, byte_value})
            $fatal(1, "mapping mismatch at byte %x", address);

        @(negedge clk);
        ioctl_wr <= 1'b0;
        prog_ack <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        prog_ack <= 1'b0;
    end
endtask

initial begin
    repeat (3) @(posedge clk);
    rst <= 1'b0;

    issue_and_check(27'h0000000, 8'h12, 2'd0, 22'h000000, 2'b10);
    issue_and_check(27'h0000001, 8'h34, 2'd0, 22'h000000, 2'b01);
    issue_and_check(27'h007ffff, 8'h56, 2'd0, 22'h03ffff, 2'b01);
    issue_and_check(27'h0080000, 8'h78, 2'd1, 22'h000000, 2'b01);
    issue_and_check(27'h0080001, 8'h9a, 2'd1, 22'h000000, 2'b10);
    issue_and_check(27'h0080002, 8'hab, 2'd1, 22'h000002, 2'b01);
    issue_and_check(27'h017ffff, 8'hac, 2'd1, 22'h0ffffe, 2'b10);
    issue_and_check(27'h0180000, 8'had, 2'd1, 22'h000001, 2'b01);
    issue_and_check(27'h0180002, 8'hae, 2'd1, 22'h000003, 2'b01);
    issue_and_check(27'h027ffff, 8'hbc, 2'd1, 22'h0fffff, 2'b10);

    // The one-byte end marker emitted by DDR replay is not an error.
    @(negedge clk);
    ioctl_addr <= 27'h0280000;
    ioctl_dout <= 8'hee;
    ioctl_wr <= 1'b1;
    @(posedge clk);
    #1;
    if (sampled_accepted || range_error)
        $fatal(1, "terminal sentinel handling is wrong");

    @(negedge clk);
    ioctl_addr <= 27'h0280001;
    @(posedge clk);
    #1;
    if (!range_error)
        $fatal(1, "out-of-range byte was not rejected");

    // A second byte cannot overwrite an unacknowledged programming request.
    @(negedge clk);
    rst <= 1'b1;
    ioctl_wr <= 1'b0;
    ioctl_rom <= 1'b0;
    @(posedge clk);
    @(negedge clk);
    rst <= 1'b0;
    ioctl_rom <= 1'b1;
    ioctl_wr <= 1'b1;
    ioctl_addr <= 27'd0;
    ioctl_dout <= 8'h11;
    @(posedge clk);
    @(negedge clk);
    ioctl_addr <= 27'd1;
    ioctl_dout <= 8'h22;
    @(posedge clk);
    #1;
    if (!overflow_error || sampled_accepted)
        $fatal(1, "unacknowledged request was overwritten");

    @(negedge clk);
    ioctl_wr <= 1'b0;
    ioctl_rom <= 1'b0;
    prog_ack <= 1'b1;
    @(posedge clk);
    @(negedge clk);
    prog_ack <= 1'b0;
    @(posedge clk);
    #1;
    if (dwnld_busy || prog_rd)
        $fatal(1, "download did not drain cleanly");

    $display("PASS rom_loader_tb");
    $finish;
end

initial begin
    #10000;
    $fatal(1, "timeout");
end

endmodule
