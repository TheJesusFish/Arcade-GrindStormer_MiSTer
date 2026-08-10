`timescale 1ns/1ps

module video_mixer_tb;

reg [8:0] display_y = 9'd10;
reg display_epoch = 1'b0;
reg [14:0] tile_pixel = 15'd0;
reg [8:0] tile_y = 9'd10;
reg tile_epoch = 1'b0;
reg tile_valid = 1'b0;
reg [14:0] object_pixel = 15'd0;
reg [8:0] object_y = 9'd10;
reg object_epoch = 1'b0;
reg object_valid = 1'b0;
wire line_ready;
wire [10:0] final_color;

grind_stormer_gp9001_line_mixer dut (
    .display_y     (display_y),
    .display_epoch (display_epoch),
    .tile_pixel    (tile_pixel),
    .tile_y        (tile_y),
    .tile_epoch    (tile_epoch),
    .tile_valid    (tile_valid),
    .object_pixel  (object_pixel),
    .object_y      (object_y),
    .object_epoch  (object_epoch),
    .object_valid  (object_valid),
    .line_ready    (line_ready),
    .final_color   (final_color)
);

initial begin
    tile_pixel = {4'd5, 7'h12, 4'h7};
    object_pixel = {4'd5, 7'h34, 4'h0};
    tile_valid = 1'b1;
    object_valid = 1'b1;
    #1;
    if (!line_ready || final_color != tile_pixel[10:0])
        $fatal(1, "transparent object did not expose tile");

    object_pixel = {4'd5, 7'h34, 4'h8};
    #1;
    if (final_color != object_pixel[10:0])
        $fatal(1, "equal-priority object did not win");

    object_pixel = {4'd4, 7'h34, 4'h8};
    #1;
    if (final_color != tile_pixel[10:0])
        $fatal(1, "lower-priority object covered tile");

    object_pixel = {4'd6, 7'h34, 4'h8};
    #1;
    if (final_color != object_pixel[10:0])
        $fatal(1, "higher-priority object did not win");

    object_epoch = 1'b1;
    #1;
    if (line_ready || final_color != 11'd0)
        $fatal(1, "stale line tag was published");

    $display("PASS video_mixer_tb");
    $finish;
end

endmodule
