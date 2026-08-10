`timescale 1ns/1ps

module rom_identity_tb;

reg clk = 1'b0;
reg rst = 1'b1;
reg download = 1'b0;
reg accepted = 1'b0;
reg [26:0] addr = 27'd0;
reg [7:0] data = 8'd0;
wire [63:0] stream_crc64;
wire [31:0] program_crc32;
wire [31:0] stream_length;
wire [1:0] set_id;
wire valid;
wire sequence_error;
wire [1:0] old_set_id;
wire old_valid;
wire old_sequence_error;
wire [1:0] vfive_set_id;
wire vfive_valid;
wire vfive_sequence_error;
integer i;

always #5 clk = ~clk;

grind_stormer_rom_identity #(
    .EXPECTED_LENGTH(32'd16),
    .CRC_GRINDSTM    (32'hcece_e288),
    .CRC_GRINDSTMA   (32'h1111_1111),
    .CRC_VFIVE       (32'h2222_2222)
) dut (
    .clk            (clk),
    .rst            (rst),
    .download       (download),
    .accepted       (accepted),
    .addr           (addr),
    .data           (data),
    .stream_crc64   (stream_crc64),
    .program_crc32  (program_crc32),
    .stream_length  (stream_length),
    .set_id         (set_id),
    .valid          (valid),
    .sequence_error (sequence_error)
);

grind_stormer_rom_identity #(
    .EXPECTED_LENGTH(32'd16),
    .CRC_GRINDSTM    (32'h1111_1111),
    .CRC_GRINDSTMA   (32'hcece_e288),
    .CRC_VFIVE       (32'h2222_2222)
) dut_old (
    .clk            (clk),
    .rst            (rst),
    .download       (download),
    .accepted       (accepted),
    .addr           (addr),
    .data           (data),
    .stream_crc64   (),
    .program_crc32  (),
    .stream_length  (),
    .set_id         (old_set_id),
    .valid          (old_valid),
    .sequence_error (old_sequence_error)
);

grind_stormer_rom_identity #(
    .EXPECTED_LENGTH(32'd16),
    .CRC_GRINDSTM    (32'h1111_1111),
    .CRC_GRINDSTMA   (32'h2222_2222),
    .CRC_VFIVE       (32'hcece_e288)
) dut_vfive (
    .clk            (clk),
    .rst            (rst),
    .download       (download),
    .accepted       (accepted),
    .addr           (addr),
    .data           (data),
    .stream_crc64   (),
    .program_crc32  (),
    .stream_length  (),
    .set_id         (vfive_set_id),
    .valid          (vfive_valid),
    .sequence_error (vfive_sequence_error)
);

initial begin
    repeat (3) @(posedge clk);
    rst <= 1'b0;

    // Exercise the boundary case where byte zero is accepted on the same
    // clock that starts a new download.
    @(negedge clk);
    download <= 1'b1;
    accepted <= 1'b1;
    addr <= 27'd0;
    data <= 8'd0;
    for (i = 1; i < 16; i = i + 1) begin
        @(negedge clk);
        addr <= i;
        data <= i;
    end
    @(negedge clk);
    accepted <= 1'b0;
    download <= 1'b0;
    repeat (2) @(posedge clk);

    if (!valid || sequence_error)
        $fatal(1, "valid synthetic stream was rejected");
    if (stream_length != 32'd16)
        $fatal(1, "length mismatch");
    if (program_crc32 != 32'hcece_e288)
        $fatal(1, "program CRC32 mismatch: %08x", program_crc32);
    if (stream_crc64 != 64'hf9c4_2d91_abaf_3b55)
        $fatal(1, "stream CRC64 mismatch: %016x", stream_crc64);
    if (set_id != 2'd1)
        $fatal(1, "parent set mapping mismatch");
    if (!old_valid || old_sequence_error || old_set_id != 2'd2)
        $fatal(1, "older set mapping mismatch");
    if (!vfive_valid || vfive_sequence_error || vfive_set_id != 2'd3)
        $fatal(1, "V-Five set mapping mismatch");

    @(negedge clk);
    download <= 1'b1;
    accepted <= 1'b1;
    addr <= 27'd1;
    data <= 8'haa;
    @(negedge clk);
    accepted <= 1'b0;
    download <= 1'b0;
    repeat (2) @(posedge clk);

    if (valid || !sequence_error ||
        old_valid || !old_sequence_error ||
        vfive_valid || !vfive_sequence_error)
        $fatal(1, "out-of-order stream was not rejected");

    $display("PASS rom_identity_tb");
    $finish;
end

initial begin
    #10000;
    $fatal(1, "timeout");
end

endmodule
