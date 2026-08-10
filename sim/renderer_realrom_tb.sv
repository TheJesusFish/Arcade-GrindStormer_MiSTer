`timescale 1ns/1ps

module renderer_realrom_tb;

localparam integer WIDTH = 320;
localparam integer HEIGHT = 240;
localparam integer LINE_CLOCKS = 14 * 432;

reg clk = 1'b0;
always #1 clk = ~clk;

reg rst = 1'b1;
reg line_start = 1'b0;
reg line_commit = 1'b0;
reg [8:0] target_y = 9'd0;
reg target_epoch = 1'b0;
reg [8:0] display_x = 9'd0;
reg [8:0] display_y = 9'd0;
reg display_epoch = 1'b0;

reg [15:0] gp_mem [0:8191];
reg [15:0] object_gp_mem [0:8191];
reg [15:0] palette_mem [0:2047];
reg [15:0] scroll_mem [0:8];
reg [15:0] gfx_mem [0:1048575];

string gp_hex_path;
string object_gp_hex_path;
string palette_hex_path;
string scroll_hex_path;
string gfx_hex_path;
string rgb_hex_path;
string index_hex_path;

wire [127:0] scrolls = {
    scroll_mem[7], scroll_mem[6], scroll_mem[5], scroll_mem[4],
    scroll_mem[3], scroll_mem[2], scroll_mem[1], scroll_mem[0]
};
wire [7:0] scroll_flip = scroll_mem[8][7:0];

wire [12:0] vram_addr;
reg [15:0] vram_data = 16'd0;
wire [9:0] object_addr;
reg [15:0] object_data = 16'd0;
wire tile_gfx_req;
wire [21:0] tile_gfx_addr;
reg [15:0] tile_gfx_data = 16'd0;
reg tile_gfx_ok = 1'b0;
wire object_gfx_req;
wire [21:0] object_gfx_addr;
reg [15:0] object_gfx_data = 16'd0;
reg object_gfx_ok = 1'b0;
wire line_ready;
wire [10:0] final_color;
wire [1:0] engine_busy;
wire [1:0] deadline_miss;
wire [15:0] tile_cycles;
wire [15:0] object_cycles;

grind_stormer_gp9001_video dut (
    .clk             (clk),
    .rst             (rst),
    .line_start      (line_start),
    .line_commit     (line_commit),
    .target_y        (target_y),
    .target_epoch    (target_epoch),
    .display_x       (display_x),
    .display_y       (display_y),
    .display_epoch   (display_epoch),
    .scrolls         (scrolls),
    .scroll_flip     (scroll_flip),
    .vram_addr       (vram_addr),
    .vram_data       (vram_data),
    .object_addr     (object_addr),
    .object_data     (object_data),
    .tile_gfx_req    (tile_gfx_req),
    .tile_gfx_addr   (tile_gfx_addr),
    .tile_gfx_data   (tile_gfx_data),
    .tile_gfx_ok     (tile_gfx_ok),
    .object_gfx_req  (object_gfx_req),
    .object_gfx_addr (object_gfx_addr),
    .object_gfx_data (object_gfx_data),
    .object_gfx_ok   (object_gfx_ok),
    .line_ready      (line_ready),
    .final_color     (final_color),
    .engine_busy     (engine_busy),
    .deadline_miss   (deadline_miss),
    .tile_cycles     (tile_cycles),
    .object_cycles   (object_cycles),
    .debug_tile_y    (),
    .debug_object_y  (),
    .debug_line_epoch(),
    .debug_line_valid()
);

always @(posedge clk) begin
    vram_data <= gp_mem[vram_addr];
    object_data <= object_gp_mem[13'h1800 + object_addr];

    tile_gfx_ok <= tile_gfx_req;
    if (tile_gfx_req) begin
        if (tile_gfx_addr >= 22'h100000)
            $fatal(1, "tile graphics address out of range: %06x",
                tile_gfx_addr);
        tile_gfx_data <= gfx_mem[tile_gfx_addr[19:0]];
    end

    object_gfx_ok <= object_gfx_req;
    if (object_gfx_req) begin
        if (object_gfx_addr >= 22'h100000)
            $fatal(1, "object graphics address out of range: %06x",
                object_gfx_addr);
        object_gfx_data <= gfx_mem[object_gfx_addr[19:0]];
    end
end

task automatic pulse_line_start;
    begin
        @(negedge clk);
        line_start = 1'b1;
        @(negedge clk);
        line_start = 1'b0;
    end
endtask

task automatic pulse_line_commit;
    begin
        @(negedge clk);
        line_commit = 1'b1;
        @(negedge clk);
        line_commit = 1'b0;
    end
endtask

integer rgb_fd;
integer index_fd;
integer x;
integer y;
integer wait_cycles;
integer max_tile_cycles = 0;
integer max_object_cycles = 0;
reg [15:0] palette_word;
reg [23:0] rgb_word;

initial begin
    if (!$value$plusargs("GP_HEX=%s", gp_hex_path))
        $fatal(1, "missing +GP_HEX");
    if (!$value$plusargs("OBJECT_GP_HEX=%s", object_gp_hex_path))
        $fatal(1, "missing +OBJECT_GP_HEX");
    if (!$value$plusargs("PALETTE_HEX=%s", palette_hex_path))
        $fatal(1, "missing +PALETTE_HEX");
    if (!$value$plusargs("SCROLL_HEX=%s", scroll_hex_path))
        $fatal(1, "missing +SCROLL_HEX");
    if (!$value$plusargs("GFX_HEX=%s", gfx_hex_path))
        $fatal(1, "missing +GFX_HEX");
    if (!$value$plusargs("RGB_HEX=%s", rgb_hex_path))
        $fatal(1, "missing +RGB_HEX");
    if (!$value$plusargs("INDEX_HEX=%s", index_hex_path))
        $fatal(1, "missing +INDEX_HEX");

    $readmemh(gp_hex_path, gp_mem);
    $readmemh(object_gp_hex_path, object_gp_mem);
    $readmemh(palette_hex_path, palette_mem);
    $readmemh(scroll_hex_path, scroll_mem);
    $readmemh(gfx_hex_path, gfx_mem);

    rgb_fd = $fopen(rgb_hex_path, "w");
    if (rgb_fd == 0)
        $fatal(1, "could not open RGB output");
    index_fd = $fopen(index_hex_path, "w");
    if (index_fd == 0)
        $fatal(1, "could not open palette-index output");

    repeat (16) @(posedge clk);
    rst = 1'b0;
    repeat (4) @(posedge clk);

    for (y = 0; y < HEIGHT; y = y + 1) begin
        target_y = y[8:0];
        display_y = y[8:0];
        pulse_line_start();

        wait_cycles = 0;
        while (engine_busy != 2'b00) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
            if (wait_cycles > LINE_CLOCKS)
                $fatal(1, "renderer line %0d exceeded deadline", y);
        end
        if (deadline_miss != 2'b00)
            $fatal(1, "renderer line %0d reported deadline miss %02b",
                y, deadline_miss);
        if (tile_cycles > max_tile_cycles)
            max_tile_cycles = tile_cycles;
        if (object_cycles > max_object_cycles)
            max_object_cycles = object_cycles;

        pulse_line_commit();
        for (x = 0; x < WIDTH; x = x + 1) begin
            @(negedge clk);
            display_x = x[8:0];
            @(posedge clk);
            #1;
            if (!line_ready)
                $fatal(1, "renderer line %0d pixel %0d is not ready",
                    y, x);
            palette_word = palette_mem[final_color];
            rgb_word = {
                palette_word[4:0], palette_word[4:2],
                palette_word[9:5], palette_word[9:7],
                palette_word[14:10], palette_word[14:12]
            };
            $fdisplay(index_fd, "%03x", final_color);
            $fdisplay(rgb_fd, "%06x", rgb_word);
        end
    end

    $fclose(index_fd);
    $fclose(rgb_fd);
    $display(
        "PASS renderer_realrom_tb pixels=%0d max_tile_cycles=%0d max_object_cycles=%0d",
        WIDTH * HEIGHT, max_tile_cycles, max_object_cycles);
    $finish;
end

initial begin
    #100000000;
    $fatal(1, "renderer simulation timeout");
end

endmodule
