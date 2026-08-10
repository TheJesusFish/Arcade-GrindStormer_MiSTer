`timescale 1ns/1ps

module realrom_savestate_tb;

localparam integer ROM_STREAM_BYTES = 16'h2800 * 16'h100;
localparam integer MAIN_WORDS = 262144;
localparam integer GFX_WORDS = 1048576;
localparam integer DEFAULT_SAVE_FRAME = 90;
localparam integer FRAME_CYCLES = 14 * 432 * 262;
localparam integer VISIBLE_PIXELS = 320 * 240;
localparam integer YM_CAPTURE_WRITES = 16;
localparam [63:0] SS_MAGIC = 64'h4752_5353_3030_3031;
localparam [63:0] SS_VERSION = 64'h0001_0000_0000_0000;
localparam [63:0] FNV_OFFSET = 64'hcbf2_9ce4_8422_2325;
localparam [63:0] FNV_PRIME = 64'h0000_0100_0000_01b3;

reg clk = 1'b0;
always #1 clk = ~clk;

reg rst = 1'b1;
reg cold_rst = 1'b1;

reg [7:0] rom_stream [0:ROM_STREAM_BYTES-1];
reg [7:0] cross_rom_stream [0:ROM_STREAM_BYTES-1];
reg [15:0] main_rom [0:MAIN_WORDS-1];
reg [15:0] gfx_rom [0:GFX_WORDS-1];
string stream_path;
string cross_stream_path;
string main_hex_path;
string gfx_hex_path;
integer stream_fd;
integer stream_bytes_read;
integer cross_stream_fd;
integer cross_stream_bytes_read;

reg [26:0] ioctl_addr = 27'd0;
reg [7:0] ioctl_dout = 8'd0;
reg ioctl_wr = 1'b0;
reg ioctl_rom = 1'b0;
wire [7:0] ioctl_din;
wire dwnld_busy;

wire [21:0] ba0_addr;
wire [21:0] ba1_addr;
wire [21:0] ba2_addr;
wire [21:0] ba3_addr;
wire [3:0] ba_rd;
wire [3:0] ba_wr;
reg [3:0] ba_dst = 4'd0;
reg [3:0] ba_dok = 4'd0;
reg [3:0] ba_rdy = 4'd0;
reg [3:0] ba_ack = 4'd0;
wire [15:0] ba0_din;
wire [15:0] ba1_din;
wire [15:0] ba2_din;
wire [15:0] ba3_din;
wire [1:0] ba0_dsn;
wire [1:0] ba1_dsn;
wire [1:0] ba2_dsn;
wire [1:0] ba3_dsn;
reg [15:0] data_read = 16'd0;

wire [1:0] prog_ba;
wire [15:0] prog_data;
wire [21:0] prog_addr;
wire prog_rd;
wire prog_we;
wire [1:0] prog_mask;

wire pxl2_cen;
wire pxl_cen;
wire [7:0] red;
wire [7:0] green;
wire [7:0] blue;
wire lhbl;
wire lvbl;
wire hs;
wire vs;
wire dip_flip;
wire signed [15:0] snd_left;
wire signed [15:0] snd_right;
wire sample;
wire [5:0] snd_vu;
wire snd_peak;
wire [7:0] debug_bus;
wire [7:0] debug_view;

reg ss_do_save = 1'b0;
reg ss_do_restore = 1'b0;
reg [3:0] start_n = 4'hf;
reg [3:0] coin_n = 4'hf;
reg [5:0] joystick1_n = 6'h3f;
integer save_frame = DEFAULT_SAVE_FRAME;
integer post_restore_frames = 0;
integer expected_set_id = 1;
reg [63:0] expected_stream_crc64 = 64'hf00e_6758_e3d9_d52d;
reg [31:0] expected_program_crc32 = 32'h4923_f790;
reg [31:0] expected_reset_pc = 32'h0002_07f2;
integer input_phase;
reg gameplay_inputs = 1'b0;
reg invulnerable = 1'b0;
reg cross_set_test_enabled = 1'b0;
wire ss_busy;
wire ss_validation_error;
wire ss_write_start;
wire ss_read_start;
wire ss_active;
wire [3:0] ss_state;
wire ss_restore_valid;

wire stream_write_req;
wire [63:0] stream_write_data;
wire stream_read_req;
wire stream_query_req;
wire [31:0] stream_chunk_address;
wire [7:0] stream_chunk_select;
wire stream_data_ack;
wire [63:0] stream_read_data;

wire [63:0] game_ss_data_out;
wire game_ss_ack;
reg [63:0] metadata_data_out = 64'd0;
reg metadata_ack = 1'b0;
reg [63:0] restored_magic = 64'd0;
reg [63:0] restored_version = 64'd0;
wire ss_format_valid =
    (restored_magic == SS_MAGIC) &&
    (restored_version == SS_VERSION);

ddr_if state_ddr();

memory_stream #(
    .COUNT(32),
    .REQUIRED_CHUNKS(32'h0000_07ff)
) u_memory_stream (
    .clk              (clk),
    .reset            (rst),
    .ddr              (state_ddr),
    .write_req        (stream_write_req),
    .write_data       (stream_write_data),
    .data_ack         (stream_data_ack),
    .read_req         (stream_read_req),
    .read_data        (stream_read_data),
    .start_addr       (32'd0),
    .length           (32'h0040_0000),
    .read_start       (ss_read_start),
    .write_start      (ss_write_start),
    .restore_allowed  (ss_restore_valid),
    .query_req        (stream_query_req),
    .chunk_address    (stream_chunk_address),
    .chunk_select     (stream_chunk_select),
    .busy             (ss_busy),
    .validation_error (ss_validation_error)
);

assign stream_data_ack =
    (stream_chunk_select == 8'd0) ? metadata_ack : game_ss_ack;
assign stream_read_data =
    (stream_chunk_select == 8'd0) ?
        metadata_data_out : game_ss_data_out;

always @(posedge clk) begin
    metadata_ack <= 1'b0;

    if (rst || ss_read_start) begin
        restored_magic <= 64'd0;
        restored_version <= 64'd0;
    end

    if (stream_chunk_select == 8'd0) begin
        if (stream_query_req) begin
            metadata_data_out <= {8'd0, 22'd0, 2'd3, 32'd2};
            metadata_ack <= 1'b1;
        end else if (stream_read_req) begin
            metadata_data_out <=
                stream_chunk_address[0] ? SS_VERSION : SS_MAGIC;
            metadata_ack <= 1'b1;
        end else if (stream_write_req) begin
            if (stream_chunk_address[0])
                restored_version <= stream_write_data;
            else
                restored_magic <= stream_write_data;
            metadata_ack <= 1'b1;
        end
    end
end

grind_stormer_game #(
    .AW(22),
    .SS_IRQ_TIMEOUT_CYCLES(1048576)
) u_game (
    .rst                 (rst),
    .cold_rst            (cold_rst),
    .clk                 (clk),
    .clk96               (clk),
    .rst96               (rst),
    .clk48               (clk),
    .rst48               (rst),
    .clk24               (clk),
    .rst24               (rst),
    .pxl2_cen            (pxl2_cen),
    .pxl_cen             (pxl_cen),
    .red                 (red),
    .green               (green),
    .blue                (blue),
    .LHBL                (lhbl),
    .LVBL                (lvbl),
    .HS                  (hs),
    .VS                  (vs),
    .cab_1p              (start_n),
    .coin                (coin_n),
    .joystick1           (joystick1_n),
    .joystick2           (6'h3f),
    .joystick3           (6'h3f),
    .joystick4           (6'h3f),
    .joyana_l1           (16'd0),
    .joyana_l2           (16'd0),
    .joyana_l3           (16'd0),
    .joyana_l4           (16'd0),
    .joyana_r1           (16'd0),
    .joyana_r2           (16'd0),
    .joyana_r3           (16'd0),
    .joyana_r4           (16'd0),
    .dial_x              (2'd0),
    .dial_y              (2'd0),
    .ioctl_addr          (ioctl_addr),
    .ioctl_dout          (ioctl_dout),
    .ioctl_cart          (1'b0),
    .ioctl_wr            (ioctl_wr),
    .ioctl_ram           (1'b0),
    .ioctl_din           (ioctl_din),
    .ioctl_rom           (ioctl_rom),
    .dwnld_busy          (dwnld_busy),
    .data_read           (data_read),
    .ba0_addr            (ba0_addr),
    .ba1_addr            (ba1_addr),
    .ba2_addr            (ba2_addr),
    .ba3_addr            (ba3_addr),
    .ba_rd               (ba_rd),
    .ba_wr               (ba_wr),
    .ba_dst              (ba_dst),
    .ba_dok              (ba_dok),
    .ba_rdy              (ba_rdy),
    .ba_ack              (ba_ack),
    .ba0_din             (ba0_din),
    .ba0_dsn             (ba0_dsn),
    .ba1_din             (ba1_din),
    .ba1_dsn             (ba1_dsn),
    .ba2_din             (ba2_din),
    .ba2_dsn             (ba2_dsn),
    .ba3_din             (ba3_din),
    .ba3_dsn             (ba3_dsn),
    .prog_ba             (prog_ba),
    .prog_rdy            (1'b1),
    .prog_ack            (1'b1),
    .prog_dok            (1'b1),
    .prog_dst            (1'b1),
    .prog_data           (prog_data),
    .prog_addr           (prog_addr),
    .prog_rd             (prog_rd),
    .prog_we             (prog_we),
    .prog_mask           (prog_mask),
    .status              (32'd0),
    .dip_pause           (1'b1),
    .dip_flip            (dip_flip),
    .dip_test            (1'b1),
    .dip_fxlevel         (2'd0),
    .service             (1'b1),
    .tilt                (1'b1),
    .dipsw               (invulnerable ? 32'h0090_4000 :
                                           32'h0090_0000),
    .snd_left            (snd_left),
    .snd_right           (snd_right),
    .sample              (sample),
    .snd_en              (6'h01),
    .snd_vol             (8'hff),
    .snd_vu              (snd_vu),
    .snd_peak            (snd_peak),
    .gfx_en              (4'hf),
    .debug_bus           (debug_bus),
    .debug_view          (debug_view),
    .ss_do_save          (ss_do_save),
    .ss_do_restore       (ss_do_restore),
    .ss_busy             (ss_busy),
    .ss_format_valid     (ss_format_valid),
    .ss_validation_error (ss_validation_error),
    .ss_write_start      (ss_write_start),
    .ss_read_start       (ss_read_start),
    .ss_active           (ss_active),
    .ss_state_out        (ss_state),
    .ss_data             (stream_write_data),
    .ss_addr             (stream_chunk_address),
    .ss_select           (stream_chunk_select),
    .ss_write            (stream_write_req),
    .ss_read             (stream_read_req),
    .ss_query            (stream_query_req),
    .ss_data_out         (game_ss_data_out),
    .ss_ack              (game_ss_ack),
    .ss_restore_valid    (ss_restore_valid)
);

// The JTFrame ROM helpers consume a four-word SDRAM burst. dst marks the
// first word and rdy the fourth, matching jtframe_sdram64.
reg rom_burst_active = 1'b0;
reg [1:0] rom_burst_bank = 2'd0;
reg [21:0] rom_burst_addr = 22'd0;
reg [2:0] rom_burst_phase = 3'd0;
wire [21:0] rom_burst_word_addr =
    rom_burst_addr + {{19{1'b0}}, rom_burst_phase};
// The hardware loader moves logical plane-select bit 19 into physical bit 0.
// Undo that mapping when this model reads its raw, linear MAME graphics image.
wire [19:0] gfx_logical_word_addr = {
    rom_burst_word_addr[0], rom_burst_word_addr[19:1]
};

always @(posedge clk) begin
    ba_ack <= 4'd0;
    ba_dst <= 4'd0;
    ba_dok <= 4'd0;
    ba_rdy <= 4'd0;

    if (rst) begin
        rom_burst_active <= 1'b0;
        rom_burst_bank <= 2'd0;
        rom_burst_addr <= 22'd0;
        rom_burst_phase <= 3'd0;
        data_read <= 16'd0;
    end else if (rom_burst_active) begin
        if (rom_burst_bank == 2'd0) begin
            // The physical burst is four words while the 16-bit cache uses
            // only the first pair. Mirror unused tail beats at the bank edge.
            data_read <= main_rom[rom_burst_word_addr[17:0]];
        end else begin
            data_read <= gfx_rom[gfx_logical_word_addr];
        end

        ba_dok[rom_burst_bank] <= 1'b1;
        if (rom_burst_phase == 3'd0)
            ba_dst[rom_burst_bank] <= 1'b1;
        if (rom_burst_phase == 3'd3) begin
            ba_rdy[rom_burst_bank] <= 1'b1;
            rom_burst_active <= 1'b0;
            rom_burst_phase <= 3'd0;
        end else begin
            rom_burst_phase <= rom_burst_phase + 3'd1;
        end
    end else if (ba_rd[0]) begin
        ba_ack[0] <= 1'b1;
        rom_burst_active <= 1'b1;
        rom_burst_bank <= 2'd0;
        rom_burst_addr <= ba0_addr;
        rom_burst_phase <= 3'd0;
    end else if (ba_rd[1]) begin
        ba_ack[1] <= 1'b1;
        rom_burst_active <= 1'b1;
        rom_burst_bank <= 2'd1;
        rom_burst_addr <= ba1_addr;
        rom_burst_phase <= 3'd0;
    end
end

reg [63:0] state_memory [0:131071];
reg state_read_seen = 1'b0;
reg state_write_seen = 1'b0;
integer state_byte;
integer state_write_max = 0;

assign state_ddr.busy = 1'b0;

always @(posedge clk) begin
    state_ddr.rdata_ready <= 1'b0;

    if (rst) begin
        state_ddr.rdata <= 64'd0;
        state_read_seen <= 1'b0;
        state_write_seen <= 1'b0;
    end else begin
        if (!state_ddr.read)
            state_read_seen <= 1'b0;
        if (!state_ddr.write)
            state_write_seen <= 1'b0;

        if (state_ddr.read && !state_read_seen) begin
            if (state_ddr.addr[31:20] != 12'd0)
                $fatal(1, "save DDR read out of range: %08x",
                    state_ddr.addr);
            state_ddr.rdata <= state_memory[state_ddr.addr[19:3]];
            state_ddr.rdata_ready <= 1'b1;
            state_read_seen <= 1'b1;
        end

        if (state_ddr.write && !state_write_seen) begin
            if (state_ddr.addr[31:20] != 12'd0)
                $fatal(1, "save DDR write out of range: %08x",
                    state_ddr.addr);
            for (state_byte = 0; state_byte < 8;
                 state_byte = state_byte + 1)
                if (state_ddr.byteenable[state_byte])
                    state_memory[state_ddr.addr[19:3]]
                        [state_byte*8 +: 8] <=
                        state_ddr.wdata[state_byte*8 +: 8];
            if (state_ddr.addr[19:3] > state_write_max)
                state_write_max <= state_ddr.addr[19:3];
            state_write_seen <= 1'b1;
        end
    end
end

longint unsigned master_cycle = 0;
integer frame_count = 0;
reg [14:0] state_seen = 15'd0;
integer irq7_iack_count = 0;
integer ssp_hi_count = 0;
integer ssp_lo_count = 0;
integer architectural_write_count = 0;
integer validation_error_count = 0;
reg validation_error_d = 1'b0;
integer restore_commit_count = 0;
integer ym_total_writes = 0;
longint unsigned nonzero_sample_count = 0;

always @(posedge clk) begin
    master_cycle <= master_cycle + 1;
    if (rst) begin
        frame_count <= 0;
        state_seen <= 15'd0;
        validation_error_d <= 1'b0;
    end else begin
        validation_error_d <= ss_validation_error;
        if (u_game.video_line_event &&
            (u_game.vcnt == 9'd261))
            frame_count <= frame_count + 1;
        if (ss_state < 4'd15)
            state_seen[ss_state] <= 1'b1;
        if ((ss_state == 4'd2) && u_game.main_cpu_iack)
            irq7_iack_count <= irq7_iack_count + 1;
        if (u_game.main_cpu_ack && !u_game.main_cpu_rw &&
            (u_game.main_cpu_addr == 24'hff0000))
            ssp_hi_count <= ssp_hi_count + 1;
        if (u_game.main_cpu_ack && !u_game.main_cpu_rw &&
            (u_game.main_cpu_addr == 24'hff0002))
            ssp_lo_count <= ssp_lo_count + 1;
        if (stream_write_req && !stream_query_req && game_ss_ack &&
            (stream_chunk_select >= 8'd2))
            architectural_write_count <=
                architectural_write_count + 1;
        if (ss_validation_error && !validation_error_d)
            validation_error_count <= validation_error_count + 1;
        if (u_game.ss_restore_commit)
            restore_commit_count <= restore_commit_count + 1;
    end
end

always @(negedge clk) begin
    if (!rst) begin
        if (u_game.sound_debug_fault)
            $fatal(1, "V25 fault pc=%05x frame=%0d state=%0d",
                u_game.sound_debug_pc, frame_count, ss_state);
        if (u_game.sound_debug_halted)
            $fatal(1, "V25 halted pc=%05x frame=%0d state=%0d",
                u_game.sound_debug_pc, frame_count, ss_state);
        if (|u_game.video_deadline_miss)
            $fatal(1, "video deadline miss %02b frame=%0d state=%0d",
                u_game.video_deadline_miss, frame_count, ss_state);
        if (u_game.sound_debug_ym_write)
            ym_total_writes <= ym_total_writes + 1;
        if (sample && (snd_left != 16'sd0))
            nonzero_sample_count <= nonzero_sample_count + 1;
    end
end

// Match the deterministic MAME trace controls when +GAMEPLAY_INPUTS is set.
// JTFrame controls are active low.
always @(*) begin
    start_n = 4'hf;
    coin_n = 4'hf;
    joystick1_n = 6'h3f;
    input_phase = 0;

    if (gameplay_inputs) begin
        if (frame_count >= 600 && frame_count < 604)
            coin_n[0] = 1'b0;
        if (frame_count >= 660 && frame_count < 664)
            start_n[0] = 1'b0;
        if (frame_count >= 780) begin
            input_phase = ((frame_count - 780) / 120) % 8;
            if (input_phase == 0 || input_phase == 1 ||
                input_phase == 7)
                joystick1_n[3] = 1'b0;
            if (input_phase == 1 || input_phase == 2 ||
                input_phase == 3)
                joystick1_n[0] = 1'b0;
            if (input_phase == 3 || input_phase == 4 ||
                input_phase == 5)
                joystick1_n[2] = 1'b0;
            if (input_phase == 5 || input_phase == 6 ||
                input_phase == 7)
                joystick1_n[1] = 1'b0;
            if (((frame_count - 780) % 240) < 228)
                joystick1_n[4] = 1'b0;
            if ((((frame_count - 900) % 480) + 480) % 480 < 3)
                joystick1_n[5] = 1'b0;
        end
    end
end

function automatic [63:0] fnv_byte;
    input [63:0] hash;
    input [7:0] value;
    begin
        fnv_byte = (hash ^ value) * FNV_PRIME;
    end
endfunction

reg pixel_capture = 1'b0;
reg pixel_capture_done = 1'b0;
reg [63:0] pixel_capture_hash = FNV_OFFSET;
integer pixel_capture_count = 0;

always @(negedge clk) begin
    if (pixel_capture && pxl_cen && lhbl && lvbl) begin
        pixel_capture_hash =
            fnv_byte(fnv_byte(fnv_byte(pixel_capture_hash, red),
                              green), blue);
        pixel_capture_count = pixel_capture_count + 1;
        if (pixel_capture_count == VISIBLE_PIXELS) begin
            pixel_capture <= 1'b0;
            pixel_capture_done <= 1'b1;
        end
    end
end

task automatic capture_next_visible_frame;
    output reg [63:0] hash;
    integer start_frame;
    begin
        while (u_game.vcnt < 9'd240)
            @(negedge clk);
        pixel_capture_hash = FNV_OFFSET;
        pixel_capture_count = 0;
        pixel_capture_done = 1'b0;
        pixel_capture = 1'b1;
        start_frame = frame_count;
        while (!pixel_capture_done) begin
            @(negedge clk);
            if (frame_count > start_frame + 2)
                $fatal(1, "visible-frame capture timeout");
        end
        if (pixel_capture_count != VISIBLE_PIXELS)
            $fatal(1, "visible-frame pixel count %0d", pixel_capture_count);
        hash = pixel_capture_hash;
    end
endtask

reg [15:0] saved_wram [0:8191];
reg [7:0] saved_shared [0:32767];
reg [15:0] saved_palette [0:2047];
reg [15:0] saved_gp [0:8191];
reg [15:0] saved_obj0 [0:1023];
reg [15:0] saved_obj1 [0:1023];
reg [15:0] saved_gp_scroll [0:7];
reg [7:0] saved_v25_ram [0:255];
reg [63:0] saved_v25_word [0:6];
reg [12:0] saved_gp_ptr;
reg [7:0] saved_gp_select;
reg [7:0] saved_gp_flip;
reg saved_obj_valid;
reg saved_obj_active;
reg [31:0] saved_ssp;
reg saved_irq4;
reg [7:0] saved_coin_control;
integer snapshot_index;

task automatic capture_saved_architecture;
    begin
        for (snapshot_index = 0; snapshot_index < 8192;
             snapshot_index = snapshot_index + 1) begin
            saved_wram[snapshot_index] = {
                u_game.u_main.u_wram.u_hi.u_ram.mem[snapshot_index],
                u_game.u_main.u_wram.u_lo.u_ram.mem[snapshot_index]
            };
            saved_gp[snapshot_index] = {
                u_game.u_main.u_gp0.u_vram.u_hi.u_ram.mem[snapshot_index],
                u_game.u_main.u_gp0.u_vram.u_lo.u_ram.mem[snapshot_index]
            };
        end
        for (snapshot_index = 0; snapshot_index < 32768;
             snapshot_index = snapshot_index + 1)
            saved_shared[snapshot_index] =
                u_game.u_main.u_shared_ram.u_ram.mem[snapshot_index];
        for (snapshot_index = 0; snapshot_index < 2048;
             snapshot_index = snapshot_index + 1)
            saved_palette[snapshot_index] = {
                u_game.u_main.u_palette_ram.u_hi.u_ram.mem[snapshot_index],
                u_game.u_main.u_palette_ram.u_lo.u_ram.mem[snapshot_index]
            };
        for (snapshot_index = 0; snapshot_index < 1024;
             snapshot_index = snapshot_index + 1) begin
            saved_obj0[snapshot_index] = {
                u_game.u_main.u_gp0.u_obj_bank0.u_hi.u_ram.mem[snapshot_index],
                u_game.u_main.u_gp0.u_obj_bank0.u_lo.u_ram.mem[snapshot_index]
            };
            saved_obj1[snapshot_index] = {
                u_game.u_main.u_gp0.u_obj_bank1.u_hi.u_ram.mem[snapshot_index],
                u_game.u_main.u_gp0.u_obj_bank1.u_lo.u_ram.mem[snapshot_index]
            };
        end
        for (snapshot_index = 0; snapshot_index < 8;
             snapshot_index = snapshot_index + 1)
            saved_gp_scroll[snapshot_index] =
                u_game.u_main.u_gp0.scroll_reg[snapshot_index];
        for (snapshot_index = 0; snapshot_index < 256;
             snapshot_index = snapshot_index + 1)
            saved_v25_ram[snapshot_index] =
                u_game.u_sound.u_v25.internal_ram[snapshot_index];

        saved_gp_ptr = u_game.u_main.u_gp0.ptr;
        saved_gp_select = u_game.u_main.u_gp0.scroll_select;
        saved_gp_flip = u_game.u_main.u_gp0.flip_reg;
        saved_obj_valid = u_game.u_main.u_gp0.obj_snapshot_valid;
        saved_obj_active = u_game.u_main.u_gp0.obj_active_bank;
        saved_ssp = u_game.ss_saved_ssp;
        saved_irq4 = u_game.main_irq4;
        saved_coin_control = u_game.main_coin_control;

        saved_v25_word[0] = {
            u_game.u_sound.u_v25.arch_bx,
            u_game.u_sound.u_v25.arch_dx,
            u_game.u_sound.u_v25.arch_cx,
            u_game.u_sound.u_v25.arch_ax
        };
        saved_v25_word[1] = {
            u_game.u_sound.u_v25.arch_di,
            u_game.u_sound.u_v25.arch_si,
            u_game.u_sound.u_v25.arch_bp,
            u_game.u_sound.u_v25.arch_sp
        };
        saved_v25_word[2] = {
            u_game.u_sound.u_v25.arch_ss,
            u_game.u_sound.u_v25.arch_es,
            u_game.u_sound.u_v25.arch_ds,
            u_game.u_sound.u_v25.arch_cs
        };
        saved_v25_word[3] = {
            23'd0,
            u_game.u_sound.u_v25.ramen,
            1'b0,
            u_game.u_sound.u_v25.irq_entry_pending,
            u_game.u_sound.u_v25.timer2_pending,
            u_game.u_sound.u_v25.fault_latch,
            u_game.u_sound.u_v25.arch_halted,
            u_game.u_sound.u_v25.active_bank,
            u_game.u_sound.u_v25.arch_flags,
            u_game.u_sound.u_v25.arch_next_ip
        };
        saved_v25_word[4] = {
            u_game.u_sound.u_v25.pm2_reg,
            u_game.u_sound.u_v25.pm1_reg,
            u_game.u_sound.u_v25.pm0_reg,
            u_game.u_sound.u_v25.p2_latch,
            u_game.u_sound.u_v25.p1_latch,
            u_game.u_sound.u_v25.p0_latch,
            u_game.u_sound.u_v25.prc_reg,
            u_game.u_sound.u_v25.idb_reg
        };
        saved_v25_word[5] = {
            u_game.u_sound.u_v25.tmic1_reg,
            u_game.u_sound.u_v25.tmic0_reg,
            u_game.u_sound.u_v25.tmc1_reg,
            u_game.u_sound.u_v25.tmc0_reg,
            u_game.u_sound.u_v25.wtc_hi,
            u_game.u_sound.u_v25.wtc_lo,
            u_game.u_sound.u_v25.rfm_reg,
            u_game.u_sound.u_v25.pmt_reg
        };
        saved_v25_word[6] = {
            u_game.u_sound.u_v25.timer_count,
            u_game.u_sound.u_v25.md1_reg,
            u_game.u_sound.u_v25.ispr_reg,
            u_game.u_sound.u_v25.tmic2_reg
        };
    end
endtask

task automatic compare_restored_architecture;
    begin
        // Policy 3 preserves chunk 9 for stream geometry but discards the
        // late V25 image. Restore applies the ROM-boot-specific pre-YM V25
        // architecture and private-workspace baseline under IKAOPM reset.
        while (!u_game.u_sound.baseline_restore_memory_active)
            @(negedge clk);
        if (u_game.sound_debug_v25_reset_n)
            $fatal(1, "V25 escaped reset during baseline-work restore");

        for (snapshot_index = 0; snapshot_index < 8192;
             snapshot_index = snapshot_index + 1) begin
            if ({
                    u_game.u_main.u_wram.u_hi.u_ram.mem[snapshot_index],
                    u_game.u_main.u_wram.u_lo.u_ram.mem[snapshot_index]
                } !== saved_wram[snapshot_index])
                $fatal(1, "work RAM restore mismatch at %04x",
                    snapshot_index);
            if ({
                    u_game.u_main.u_gp0.u_vram.u_hi.u_ram.mem[snapshot_index],
                    u_game.u_main.u_gp0.u_vram.u_lo.u_ram.mem[snapshot_index]
                } !== saved_gp[snapshot_index])
                $fatal(1, "GP9001 VRAM restore mismatch at %04x",
                    snapshot_index);
        end
        for (snapshot_index = 0; snapshot_index < 2048;
             snapshot_index = snapshot_index + 1)
            if ({
                    u_game.u_main.u_palette_ram.u_hi.u_ram.mem[snapshot_index],
                    u_game.u_main.u_palette_ram.u_lo.u_ram.mem[snapshot_index]
                } !== saved_palette[snapshot_index])
                $fatal(1, "palette RAM restore mismatch at %04x",
                    snapshot_index);
        for (snapshot_index = 0; snapshot_index < 1024;
             snapshot_index = snapshot_index + 1) begin
            if ({
                    u_game.u_main.u_gp0.u_obj_bank0.u_hi.u_ram.mem[snapshot_index],
                    u_game.u_main.u_gp0.u_obj_bank0.u_lo.u_ram.mem[snapshot_index]
                } !== saved_obj0[snapshot_index])
                $fatal(1, "GP9001 object bank 0 mismatch at %04x",
                    snapshot_index);
            if ({
                    u_game.u_main.u_gp0.u_obj_bank1.u_hi.u_ram.mem[snapshot_index],
                    u_game.u_main.u_gp0.u_obj_bank1.u_lo.u_ram.mem[snapshot_index]
                } !== saved_obj1[snapshot_index])
                $fatal(1, "GP9001 object bank 1 mismatch at %04x",
                    snapshot_index);
        end
        for (snapshot_index = 0; snapshot_index < 8;
             snapshot_index = snapshot_index + 1)
            if (u_game.u_main.u_gp0.scroll_reg[snapshot_index] !==
                saved_gp_scroll[snapshot_index])
                $fatal(1, "GP9001 scroll restore mismatch at %0d",
                    snapshot_index);
        if (u_game.u_main.u_gp0.ptr !== saved_gp_ptr ||
            u_game.u_main.u_gp0.scroll_select !== saved_gp_select ||
            u_game.u_main.u_gp0.flip_reg !== saved_gp_flip ||
            u_game.u_main.u_gp0.obj_snapshot_valid !== saved_obj_valid ||
            u_game.u_main.u_gp0.obj_active_bank !== saved_obj_active)
            $fatal(1, "GP9001 register/ownership restore mismatch");

        while (u_game.u_sound.baseline_restore_memory_active)
            @(negedge clk);
        if (u_game.sound_debug_v25_reset_n)
            $fatal(1, "V25 released before baseline-work verification");
        for (snapshot_index = 0; snapshot_index < 2560;
             snapshot_index = snapshot_index + 1)
            if (u_game.u_main.u_shared_ram.u_ram.mem[
                    15'h7400 + snapshot_index] !==
                u_game.u_sound.v25_work_baseline[snapshot_index])
                $fatal(1, "V25 baseline-work mismatch at %04x",
                    15'h7400 + snapshot_index);
    end
endtask

task automatic compare_restored_global;
    begin
        if (u_game.main_irq4 !== saved_irq4)
            $fatal(1, "IRQ4 restore mismatch");
        if (u_game.main_coin_control !== saved_coin_control)
            $fatal(1, "coin/V25 release latch restore mismatch");
        if (u_game.ss_restore_ssp !== saved_ssp)
            $fatal(1, "saved SSP metadata restore mismatch");
    end
endtask

task automatic architecture_hash;
    output reg [63:0] hash;
    reg [15:0] word_value;
    begin
        hash = FNV_OFFSET;
        for (snapshot_index = 0; snapshot_index < 8192;
             snapshot_index = snapshot_index + 1) begin
            word_value = {
                u_game.u_main.u_wram.u_hi.u_ram.mem[snapshot_index],
                u_game.u_main.u_wram.u_lo.u_ram.mem[snapshot_index]
            };
            hash = fnv_byte(fnv_byte(hash, word_value[7:0]),
                            word_value[15:8]);
            word_value = {
                u_game.u_main.u_gp0.u_vram.u_hi.u_ram.mem[snapshot_index],
                u_game.u_main.u_gp0.u_vram.u_lo.u_ram.mem[snapshot_index]
            };
            hash = fnv_byte(fnv_byte(hash, word_value[7:0]),
                            word_value[15:8]);
        end
        for (snapshot_index = 0; snapshot_index < 32768;
             snapshot_index = snapshot_index + 1)
            hash = fnv_byte(hash,
                u_game.u_main.u_shared_ram.u_ram.mem[snapshot_index]);
        for (snapshot_index = 0; snapshot_index < 2048;
             snapshot_index = snapshot_index + 1) begin
            word_value = {
                u_game.u_main.u_palette_ram.u_hi.u_ram.mem[snapshot_index],
                u_game.u_main.u_palette_ram.u_lo.u_ram.mem[snapshot_index]
            };
            hash = fnv_byte(fnv_byte(hash, word_value[7:0]),
                            word_value[15:8]);
        end
        hash = fnv_byte(hash, u_game.u_main.u_gp0.ptr[7:0]);
        hash = fnv_byte(hash, {3'd0, u_game.u_main.u_gp0.ptr[12:8]});
        hash = fnv_byte(hash, u_game.u_main.u_gp0.scroll_select);
        hash = fnv_byte(hash, u_game.u_main.u_gp0.flip_reg);
        hash = fnv_byte(hash, {6'd0,
            u_game.u_main.u_gp0.obj_snapshot_valid,
            u_game.u_main.u_gp0.obj_active_bank});
    end
endtask

reg [8:0] ym_sequence_1 [0:YM_CAPTURE_WRITES-1];
reg [8:0] ym_sequence_2 [0:YM_CAPTURE_WRITES-1];
reg [63:0] ym_delta_1 [0:YM_CAPTURE_WRITES-1];
reg [63:0] ym_delta_2 [0:YM_CAPTURE_WRITES-1];
integer ym_capture_mode = 0;
integer ym_capture_count = 0;
integer ym_capture_start_cycle = 0;

always @(negedge clk) begin
    if (!rst && u_game.sound_debug_ym_write &&
        (ym_capture_mode != 0) &&
        (ym_capture_count < YM_CAPTURE_WRITES)) begin
        if (ym_capture_mode == 1) begin
            ym_sequence_1[ym_capture_count] = {
                u_game.sound_debug_ym_a0,
                u_game.sound_debug_ym_data
            };
            ym_delta_1[ym_capture_count] =
                master_cycle - ym_capture_start_cycle;
        end else begin
            ym_sequence_2[ym_capture_count] = {
                u_game.sound_debug_ym_a0,
                u_game.sound_debug_ym_data
            };
            ym_delta_2[ym_capture_count] =
                master_cycle - ym_capture_start_cycle;
        end
        ym_capture_count = ym_capture_count + 1;
    end
end

task automatic start_ym_capture;
    input integer mode;
    begin
        ym_capture_mode = mode;
        ym_capture_count = 0;
        ym_capture_start_cycle = master_cycle;
    end
endtask

task automatic wait_for_ym_capture;
    integer start_frame;
    begin
        start_frame = frame_count;
        while (ym_capture_count < YM_CAPTURE_WRITES) begin
            @(negedge clk);
            if (frame_count > start_frame + 120)
                $fatal(1,
                    "post-restore YM recovery timeout: %0d/%0d writes",
                    ym_capture_count, YM_CAPTURE_WRITES);
        end
        ym_capture_mode = 0;
    end
endtask

task automatic compare_ym_captures;
    integer ym_index;
    begin
        for (ym_index = 0; ym_index < YM_CAPTURE_WRITES;
             ym_index = ym_index + 1) begin
            if (ym_sequence_2[ym_index] !== ym_sequence_1[ym_index])
                $fatal(1,
                    "deterministic YM restart data mismatch %0d: %03x/%03x",
                    ym_index, ym_sequence_1[ym_index],
                    ym_sequence_2[ym_index]);
        end
        $display(
            "LANDMARK deterministic_ym_restart writes=%0d first_latency=%0d/%0d",
            YM_CAPTURE_WRITES, ym_delta_1[0], ym_delta_2[0]);
    end
endtask

task automatic pulse_save;
    begin
        @(negedge clk);
        ss_do_save = 1'b1;
        @(negedge clk);
        ss_do_save = 1'b0;
    end
endtask

task automatic pulse_restore;
    begin
        @(negedge clk);
        ss_do_restore = 1'b1;
        @(negedge clk);
        ss_do_restore = 1'b0;
    end
endtask

task automatic wait_state_idle;
    integer wait_cycles;
    begin
        wait_cycles = 0;
        while (ss_active) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
            if (wait_cycles > (FRAME_CYCLES * 160))
                $fatal(1, "save-state FSM timeout in state %0d", ss_state);
        end
    end
endtask

task automatic wait_frames;
    input integer count;
    integer target_frame;
    begin
        target_frame = frame_count + count;
        while (frame_count < target_frame)
            @(negedge clk);
    end
endtask

task automatic download_stream;
    input use_cross_stream;
    integer rom_index;
    begin
        @(negedge clk);
        ioctl_rom = 1'b1;
        ioctl_wr = 1'b1;
        for (rom_index = 0; rom_index < ROM_STREAM_BYTES;
            rom_index = rom_index + 1) begin
            ioctl_addr = rom_index[26:0];
            ioctl_dout = use_cross_stream ?
                cross_rom_stream[rom_index] : rom_stream[rom_index];
            @(negedge clk);
        end
        ioctl_wr = 1'b0;
        ioctl_rom = 1'b0;
        ioctl_addr = 27'd0;
        ioctl_dout = 8'd0;
        while (dwnld_busy)
            @(negedge clk);
        repeat (4) @(negedge clk);
        if (!u_game.rom_identity_valid)
            $fatal(1,
                "ROM identity invalid crc64=%016x crc32=%08x len=%08x",
                u_game.rom_stream_crc64,
                u_game.rom_program_crc32,
                u_game.rom_stream_length);
        if (use_cross_stream) begin
            if (u_game.rom_stream_length !== 32'h0028_0000 ||
                u_game.rom_set_id == 2'd0 ||
                u_game.rom_set_id == expected_set_id[1:0])
                $fatal(1,
                    "cross-set ROM identity tuple mismatch active=%0d saved=%0d",
                    u_game.rom_set_id, expected_set_id);
        end else if (
            u_game.rom_stream_crc64 !== expected_stream_crc64 ||
            u_game.rom_program_crc32 !== expected_program_crc32 ||
            u_game.rom_stream_length !== 32'h0028_0000 ||
            u_game.rom_set_id !== expected_set_id[1:0])
            $fatal(1,
                "ROM identity tuple mismatch set=%0d crc64=%016x crc32=%08x",
                u_game.rom_set_id, u_game.rom_stream_crc64,
                u_game.rom_program_crc32);
    end
endtask

task automatic dump_sound_restore_fixture;
    integer output_fd;
    integer fixture_index;
    integer v25_descriptor;
    integer policy_descriptor;
    begin
        if (sound_shared_path.len() == 0 ||
            sound_v25_path.len() == 0 ||
            sound_policy_path.len() == 0)
            disable dump_sound_restore_fixture;

        output_fd = $fopen(sound_shared_path, "w");
        if (output_fd == 0)
            $fatal(1, "could not create sound shared fixture");
        for (fixture_index = 0; fixture_index < 32768;
             fixture_index = fixture_index + 1)
            $fdisplay(output_fd, "%02x", saved_shared[fixture_index]);
        $fclose(output_fd);

        v25_descriptor = -1;
        policy_descriptor = -1;
        for (fixture_index = 1; fixture_index <= state_write_max;
             fixture_index = fixture_index + 1) begin
            if (state_memory[fixture_index][63:61] == 3'd0 &&
                state_memory[fixture_index][55:34] == 22'd0 &&
                state_memory[fixture_index][33:32] == 2'd3 &&
                state_memory[fixture_index][60:56] == 5'd9 &&
                state_memory[fixture_index][31:0] == 32'd39)
                v25_descriptor = fixture_index;
            if (state_memory[fixture_index][63:61] == 3'd0 &&
                state_memory[fixture_index][55:34] == 22'd0 &&
                state_memory[fixture_index][33:32] == 2'd3 &&
                state_memory[fixture_index][60:56] == 5'd10 &&
                state_memory[fixture_index][31:0] == 32'd1)
                policy_descriptor = fixture_index;
        end
        if (v25_descriptor < 0 || policy_descriptor < 0)
            $fatal(1,
                "sound fixture descriptor missing v25=%0d policy=%0d",
                v25_descriptor, policy_descriptor);

        output_fd = $fopen(sound_v25_path, "w");
        if (output_fd == 0)
            $fatal(1, "could not create V25 state fixture");
        for (fixture_index = 0; fixture_index < 39;
             fixture_index = fixture_index + 1)
            $fdisplay(output_fd, "%016x",
                state_memory[v25_descriptor + 1 + fixture_index]);
        $fclose(output_fd);

        output_fd = $fopen(sound_policy_path, "w");
        if (output_fd == 0)
            $fatal(1, "could not create sound policy fixture");
        $fdisplay(output_fd, "%016x",
            state_memory[policy_descriptor + 1]);
        $fclose(output_fd);

        $display(
            "LANDMARK sound_fixture shared=%s v25=%s policy=%s",
            sound_shared_path, sound_v25_path, sound_policy_path);
    end
endtask

reg [63:0] golden_video_hash;
reg [63:0] restore_video_hash;
reg [63:0] repeat_video_hash;
reg [63:0] reload_video_hash;
reg [63:0] invalid_before_hash;
reg [63:0] invalid_after_hash;
reg [63:0] corrupted_word;
integer writes_before_invalid;
longint unsigned nonzero_before_window;
integer commit_before_invalid;
integer commits_before_restore;
string sound_shared_path;
string sound_v25_path;
string sound_policy_path;

initial begin
    if (!$value$plusargs("STREAM_BIN=%s", stream_path))
        $fatal(1, "missing +STREAM_BIN");
    if (!$value$plusargs("MAIN_HEX=%s", main_hex_path))
        $fatal(1, "missing +MAIN_HEX");
    if (!$value$plusargs("GFX_HEX=%s", gfx_hex_path))
        $fatal(1, "missing +GFX_HEX");
    void'($value$plusargs("SAVE_FRAME=%d", save_frame));
    void'($value$plusargs(
        "POST_RESTORE_FRAMES=%d", post_restore_frames));
    void'($value$plusargs("EXPECTED_SET_ID=%d", expected_set_id));
    void'($value$plusargs(
        "EXPECTED_STREAM_CRC64=%h", expected_stream_crc64));
    void'($value$plusargs(
        "EXPECTED_PROGRAM_CRC32=%h", expected_program_crc32));
    void'($value$plusargs(
        "EXPECTED_RESET_PC=%h", expected_reset_pc));
    cross_set_test_enabled = $value$plusargs(
        "CROSS_STREAM_BIN=%s", cross_stream_path);
    gameplay_inputs = $test$plusargs("GAMEPLAY_INPUTS");
    invulnerable = $test$plusargs("INVULNERABLE");
    void'($value$plusargs(
        "DUMP_SOUND_SHARED=%s", sound_shared_path));
    void'($value$plusargs("DUMP_SOUND_V25=%s", sound_v25_path));
    void'($value$plusargs(
        "DUMP_SOUND_POLICY=%s", sound_policy_path));
    if (save_frame < 90)
        $fatal(1, "SAVE_FRAME must be at least 90");
    if (post_restore_frames < 0)
        $fatal(1, "POST_RESTORE_FRAMES cannot be negative");

    stream_fd = $fopen(stream_path, "rb");
    if (stream_fd == 0)
        $fatal(1, "could not open normalized ROM stream");
    stream_bytes_read = $fread(rom_stream, stream_fd);
    $fclose(stream_fd);
    if (stream_bytes_read != ROM_STREAM_BYTES)
        $fatal(1, "ROM stream read %0d bytes, expected %0d",
            stream_bytes_read, ROM_STREAM_BYTES);
    if (cross_set_test_enabled) begin
        cross_stream_fd = $fopen(cross_stream_path, "rb");
        if (cross_stream_fd == 0)
            $fatal(1, "could not open cross-set normalized ROM stream");
        cross_stream_bytes_read =
            $fread(cross_rom_stream, cross_stream_fd);
        $fclose(cross_stream_fd);
        if (cross_stream_bytes_read != ROM_STREAM_BYTES)
            $fatal(1,
                "cross-set ROM stream read %0d bytes, expected %0d",
                cross_stream_bytes_read, ROM_STREAM_BYTES);
    end
    $readmemh(main_hex_path, main_rom);
    $readmemh(gfx_hex_path, gfx_rom);
    if ({main_rom[0], main_rom[1]} !== 32'h0010_4000 ||
        {main_rom[2], main_rom[3]} !== expected_reset_pc)
        $fatal(1, "unexpected official-set reset vectors");

    repeat (16) @(negedge clk);
    cold_rst = 1'b0;
    download_stream(1'b0);
    rst = 1'b0;

    while (frame_count < save_frame)
        @(negedge clk);
    if (gameplay_inputs) begin
        gameplay_inputs = 1'b0;
        wait_frames(1);
        $display(
            "LANDMARK gameplay_inputs_complete frame=%0d gp=%0d palette=%0d ym=%0d",
            frame_count, u_game.main_gp_access_count,
            u_game.main_palette_write_count, ym_total_writes);
    end
    if (u_game.main_shared_write_count < 32'd512 ||
        !u_game.main_v25_reset_n ||
        ym_total_writes == 0)
        $fatal(1,
            "real-ROM save point lacks sustained boot/audio evidence");

    pulse_save();
    while (!ss_write_start)
        @(negedge clk);
    capture_saved_architecture();
    wait_state_idle();

    if (!state_seen[2] || !state_seen[3] || !state_seen[4] ||
        !state_seen[5] || !state_seen[10] || !state_seen[13])
        $fatal(1, "save FSM did not visit every required state: %04x",
            state_seen);
    if (irq7_iack_count != 1 ||
        ssp_hi_count != 1 || ssp_lo_count != 1)
        $fatal(1,
            "private IRQ7 capture mismatch iack=%0d ssp_hi=%0d ssp_lo=%0d",
            irq7_iack_count, ssp_hi_count, ssp_lo_count);
    if (saved_ssp < 32'h0010_0000 || saved_ssp > 32'h0010_4000)
        $fatal(1, "saved SSP outside work RAM: %08x", saved_ssp);
    if (state_write_max < 100)
        $fatal(1, "save stream unexpectedly short: last word %0d",
            state_write_max);
    dump_sound_restore_fixture();

    capture_next_visible_frame(golden_video_hash);
    $display(
        "LANDMARK save_complete frame=%0d ssp=%08x words=%0d video=%016x ym=%0d",
        frame_count, saved_ssp, state_write_max + 1,
        golden_video_hash, ym_total_writes);

    wait_frames(3);

    // Corrupt a CRC-covered payload word. Preflight may stage chunks 0/1,
    // but it must reject before any architectural client write.
    corrupted_word = state_memory[64];
    state_memory[64] = corrupted_word ^ 64'h0000_0000_0000_0001;
    writes_before_invalid = architectural_write_count;
    commit_before_invalid = restore_commit_count;
    pulse_restore();
    while (!(ss_state == 4'd7 && ss_busy))
        @(negedge clk);
    architecture_hash(invalid_before_hash);
    while (ss_busy)
        @(negedge clk);
    architecture_hash(invalid_after_hash);
    if (invalid_after_hash !== invalid_before_hash)
        $fatal(1,
            "corrupt restore mutated architecture %016x/%016x",
            invalid_before_hash, invalid_after_hash);
    if (architectural_write_count != writes_before_invalid)
        $fatal(1, "corrupt preflight issued architectural writes");
    if (!ss_validation_error)
        $fatal(1, "corrupt stream did not raise validation_error");
    if (restore_commit_count != commit_before_invalid)
        $fatal(1, "corrupt stream reached restore commit");
    wait_state_idle();
    state_memory[64] = corrupted_word;

    // First valid restore proves every live owner plus the policy-3
    // post-bootstrap sound baseline used in place of the saved V25 image.
    commits_before_restore = restore_commit_count;
    pulse_restore();
    while (!u_game.ss_restore_commit)
        @(negedge clk);
    start_ym_capture(1);
    compare_restored_architecture();
    @(negedge clk);
    compare_restored_global();
    wait_state_idle();
    if (restore_commit_count != commits_before_restore + 1)
        $fatal(1, "valid restore commit count mismatch");
    capture_next_visible_frame(restore_video_hash);
    if (restore_video_hash !== golden_video_hash)
        $fatal(1,
            "first reconstructed frame mismatch golden=%016x restore=%016x",
            golden_video_hash, restore_video_hash);
    wait_for_ym_capture();
    if (post_restore_frames > 0) begin
        writes_before_invalid = ym_total_writes;
        nonzero_before_window = nonzero_sample_count;
        wait_frames(post_restore_frames);
        if (ym_total_writes <= writes_before_invalid)
            $fatal(1, "first post-restore longevity window has no YM writes");
        if (nonzero_sample_count <= nonzero_before_window)
            $fatal(1,
                "first post-restore longevity window has no nonzero audio");
        $display(
            "LANDMARK first_post_restore frames=%0d ym_delta=%0d nonzero_delta=%0d",
            post_restore_frames, ym_total_writes - writes_before_invalid,
            nonzero_sample_count - nonzero_before_window);
    end

    wait_frames(3);
    commits_before_restore = restore_commit_count;
    pulse_restore();
    while (!u_game.ss_restore_commit)
        @(negedge clk);
    start_ym_capture(2);
    compare_restored_architecture();
    @(negedge clk);
    compare_restored_global();
    wait_state_idle();
    if (restore_commit_count != commits_before_restore + 1)
        $fatal(1, "repeat restore commit count mismatch");
    capture_next_visible_frame(repeat_video_hash);
    if (repeat_video_hash !== restore_video_hash)
        $fatal(1,
            "repeated restore frame mismatch first=%016x repeat=%016x",
            restore_video_hash, repeat_video_hash);
    wait_for_ym_capture();
    compare_ym_captures();
    if (post_restore_frames > 0) begin
        writes_before_invalid = ym_total_writes;
        nonzero_before_window = nonzero_sample_count;
        wait_frames(post_restore_frames);
        if (ym_total_writes <= writes_before_invalid)
            $fatal(1,
                "repeated post-restore longevity window has no YM writes");
        if (nonzero_sample_count <= nonzero_before_window)
            $fatal(1,
                "repeated post-restore longevity window has no nonzero audio");
        $display(
            "LANDMARK repeat_post_restore frames=%0d ym_delta=%0d nonzero_delta=%0d",
            post_restore_frames, ym_total_writes - writes_before_invalid,
            nonzero_sample_count - nonzero_before_window);
    end

    // A valid save from one official set must be rejected without mutation
    // after a different official stream becomes the active ROM identity.
    if (cross_set_test_enabled) begin
        @(negedge clk);
        rst = 1'b1;
        cold_rst = 1'b1;
        repeat (16) @(negedge clk);
        cold_rst = 1'b0;
        download_stream(1'b1);
        rst = 1'b0;
        wait_frames(2);

        writes_before_invalid = architectural_write_count;
        commit_before_invalid = restore_commit_count;
        pulse_restore();
        while (!(ss_state == 4'd7 && ss_busy))
            @(negedge clk);
        architecture_hash(invalid_before_hash);
        wait_state_idle();
        architecture_hash(invalid_after_hash);
        if (invalid_after_hash !== invalid_before_hash)
            $fatal(1,
                "cross-set restore mutated architecture %016x/%016x",
                invalid_before_hash, invalid_after_hash);
        if (architectural_write_count != writes_before_invalid)
            $fatal(1, "cross-set preflight issued architectural writes");
        if (!ss_validation_error)
            $fatal(1, "cross-set stream did not raise validation_error");
        if (restore_commit_count != commit_before_invalid)
            $fatal(1, "cross-set stream reached restore commit");
        $display(
            "LANDMARK cross_set_rejected saved_set=%0d active_set=%0d",
            expected_set_id, u_game.rom_set_id);
    end

    // Preserve the save DDR image while simulating a complete core reload,
    // then redownload the same official stream and restore immediately.
    @(negedge clk);
    rst = 1'b1;
    cold_rst = 1'b1;
    repeat (16) @(negedge clk);
    cold_rst = 1'b0;
    download_stream(1'b0);
    rst = 1'b0;
    wait_frames(2);

    commits_before_restore = restore_commit_count;
    pulse_restore();
    while (!u_game.ss_restore_commit)
        @(negedge clk);
    compare_restored_architecture();
    @(negedge clk);
    compare_restored_global();
    wait_state_idle();
    if (restore_commit_count != commits_before_restore + 1)
        $fatal(1, "post-reload restore commit count mismatch");
    capture_next_visible_frame(reload_video_hash);
    if (reload_video_hash !== restore_video_hash)
        $fatal(1,
            "post-reload frame mismatch first=%016x reload=%016x",
            restore_video_hash, reload_video_hash);

    $display(
        "PASS realrom_savestate_tb frames=%0d save_words=%0d arch_writes=%0d validations=%0d commits=%0d video=%016x ym_restart_writes=%0d",
        frame_count, state_write_max + 1,
        architectural_write_count, validation_error_count,
        restore_commit_count, restore_video_hash,
        YM_CAPTURE_WRITES);
    $finish;
end

initial begin
    #100000000000;
    $fatal(1, "real-ROM save-state simulation timeout");
end

endmodule
