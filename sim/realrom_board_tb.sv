`timescale 1ns/1ps

module realrom_board_tb;

localparam integer YM_GOLDEN_WRITES = 256;
localparam integer MAX_FRAMES = 110;
localparam integer POST_BOOT_FRAME = 180;
localparam integer RAW_FRAME_CYCLES = 14 * 432 * 262;
localparam integer MAME_FIRST_YM_CYCLE = 140752893;
localparam [15:0] IDLE_INPUT_WORD = 16'h0000;

reg clk = 1'b0;
always #1 clk = ~clk;

reg rst = 1'b1;
reg [3:0] pixel_div = 4'd0;
reg [9:0] hcnt = 10'd0;
reg [8:0] vcnt = 9'd0;
integer frame_count = 0;
integer master_cycle = 0;

wire irq4_start = (pixel_div == 4'd13) &&
                  (hcnt == 10'd0) && (vcnt == 9'd230);
wire obj_buf_start = (pixel_div == 4'd13) &&
                     (hcnt == 10'd431) && (vcnt == 9'd239);

always @(posedge clk) begin
    if (rst) begin
        pixel_div <= 4'd0;
        hcnt <= 10'd0;
        vcnt <= 9'd0;
        frame_count <= 0;
        master_cycle <= 0;
    end else begin
        master_cycle <= master_cycle + 1;
        if (pixel_div == 4'd13) begin
            pixel_div <= 4'd0;
            if (hcnt == 10'd431) begin
                hcnt <= 10'd0;
                if (vcnt == 9'd261) begin
                    vcnt <= 9'd0;
                    frame_count <= frame_count + 1;
                end else begin
                    vcnt <= vcnt + 9'd1;
                end
            end else begin
                hcnt <= hcnt + 10'd1;
            end
        end else begin
            pixel_div <= pixel_div + 4'd1;
        end
    end
end

reg [15:0] main_rom [0:262143];
reg [7:0] upload_golden [0:511];
reg [8:0] ym_golden [0:YM_GOLDEN_WRITES-1];
reg [15:0] mame_gp_prev [0:8191];
reg [15:0] mame_gp_same [0:8191];
reg [15:0] mame_gp_next [0:8191];
reg [15:0] mame_palette_prev [0:2047];
reg [15:0] mame_palette_same [0:2047];
reg [15:0] mame_palette_next [0:2047];
reg [15:0] mame_work_prev [0:8191];
reg [15:0] mame_work_same [0:8191];
reg [15:0] mame_work_next [0:8191];
reg [7:0] mame_shared_prev [0:32767];
reg [7:0] mame_shared_same [0:32767];
reg [7:0] mame_shared_next [0:32767];
reg [15:0] mame_scroll_prev [0:8];
reg [15:0] mame_scroll_same [0:8];
reg [15:0] mame_scroll_next [0:8];
string main_hex_path;
string upload_hex_path;
string ym_hex_path;
string rtl_instruction_trace_path;
string mame_reference_directory;
string mame_reference_path;
string rtl_state_directory;
string rtl_state_path;
string sound_fixture_shared_path;
string sound_fixture_v25_path;
string sound_fixture_policy_path;
string sound_baseline_v25_path;
string sound_baseline_work_path;
integer mame_reference_frame = 0;
reg [31:0] expected_reset_pc = 32'h0002_07f2;
reg mame_compare_enabled = 1'b0;
reg rtl_state_dump_enabled = 1'b0;
integer rtl_instruction_trace_fd = 0;
reg rtl_instruction_trace_closed = 1'b0;

initial begin
    if (!$value$plusargs("MAIN_HEX=%s", main_hex_path))
        $fatal(1, "missing +MAIN_HEX");
    if (!$value$plusargs("UPLOAD_HEX=%s", upload_hex_path))
        $fatal(1, "missing +UPLOAD_HEX");
    if (!$value$plusargs("YM_HEX=%s", ym_hex_path))
        $fatal(1, "missing +YM_HEX");
    void'($value$plusargs(
        "EXPECTED_RESET_PC=%h", expected_reset_pc));
    $readmemh(main_hex_path, main_rom);
    $readmemh(upload_hex_path, upload_golden);
    $readmemh(ym_hex_path, ym_golden);
    if ($value$plusargs(
            "MAME_REFERENCE_DIR=%s", mame_reference_directory) &&
        $value$plusargs(
            "MAME_REFERENCE_FRAME=%d", mame_reference_frame)) begin
        mame_reference_path = $sformatf(
            "%s/gp9001-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame - 1);
        $readmemh(mame_reference_path, mame_gp_prev);
        mame_reference_path = $sformatf(
            "%s/gp9001-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame);
        $readmemh(mame_reference_path, mame_gp_same);
        mame_reference_path = $sformatf(
            "%s/gp9001-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame + 1);
        $readmemh(mame_reference_path, mame_gp_next);

        mame_reference_path = $sformatf(
            "%s/palette-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame - 1);
        $readmemh(mame_reference_path, mame_palette_prev);
        mame_reference_path = $sformatf(
            "%s/palette-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame);
        $readmemh(mame_reference_path, mame_palette_same);
        mame_reference_path = $sformatf(
            "%s/palette-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame + 1);
        $readmemh(mame_reference_path, mame_palette_next);

        mame_reference_path = $sformatf(
            "%s/work-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame - 1);
        $readmemh(mame_reference_path, mame_work_prev);
        mame_reference_path = $sformatf(
            "%s/work-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame);
        $readmemh(mame_reference_path, mame_work_same);
        mame_reference_path = $sformatf(
            "%s/work-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame + 1);
        $readmemh(mame_reference_path, mame_work_next);

        mame_reference_path = $sformatf(
            "%s/shared-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame - 1);
        $readmemh(mame_reference_path, mame_shared_prev);
        mame_reference_path = $sformatf(
            "%s/shared-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame);
        $readmemh(mame_reference_path, mame_shared_same);
        mame_reference_path = $sformatf(
            "%s/shared-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame + 1);
        $readmemh(mame_reference_path, mame_shared_next);

        mame_reference_path = $sformatf(
            "%s/scroll-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame - 1);
        $readmemh(mame_reference_path, mame_scroll_prev);
        mame_reference_path = $sformatf(
            "%s/scroll-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame);
        $readmemh(mame_reference_path, mame_scroll_same);
        mame_reference_path = $sformatf(
            "%s/scroll-frame-%06d.hex",
            mame_reference_directory, mame_reference_frame + 1);
        $readmemh(mame_reference_path, mame_scroll_next);
        mame_compare_enabled = 1'b1;
    end
    if ($value$plusargs("RTL_STATE_DIR=%s", rtl_state_directory))
        rtl_state_dump_enabled = 1'b1;
    if ($test$plusargs("SOUND_RESTORE_TEST"))
        sound_restore_test_enabled = 1'b1;
    void'($value$plusargs(
        "DUMP_SOUND_SHARED=%s", sound_fixture_shared_path));
    void'($value$plusargs(
        "DUMP_SOUND_V25=%s", sound_fixture_v25_path));
    void'($value$plusargs(
        "DUMP_SOUND_POLICY=%s", sound_fixture_policy_path));
    void'($value$plusargs(
        "DUMP_SOUND_BASELINE_V25=%s", sound_baseline_v25_path));
    void'($value$plusargs(
        "DUMP_SOUND_BASELINE_WORK=%s", sound_baseline_work_path));
    if ($value$plusargs(
            "RTL_INSTRUCTION_TRACE=%s", rtl_instruction_trace_path)) begin
        rtl_instruction_trace_fd =
            $fopen(rtl_instruction_trace_path, "w");
        if (rtl_instruction_trace_fd == 0)
            $fatal(1, "could not open RTL instruction trace");
        $fwrite(rtl_instruction_trace_fd,
            "instruction,total_v25_cycles,delta_v25_cycles,next_pc,opcode,master_cycle,frame\n");
    end
    if ({main_rom[0], main_rom[1]} !== 32'h0010_4000)
        $fatal(1, "unexpected real-ROM reset SSP");
    if ({main_rom[2], main_rom[3]} !== expected_reset_pc)
        $fatal(1,
            "unexpected real-ROM reset PC actual=%08x expected=%08x",
            {main_rom[2], main_rom[3]}, expected_reset_pc);
end

wire        rom_cs;
wire [17:0] rom_addr;
wire [15:0] rom_data = main_rom[rom_addr];
wire        rom_ok = rom_cs;

wire [14:0] sound_shared_addr;
wire [7:0]  sound_shared_dout;
wire        sound_shared_we;
wire [7:0]  sound_shared_din;
wire [14:0] sound_core_shared_addr;
wire [7:0]  sound_core_shared_dout;
wire        sound_core_shared_we;
reg         test_shared_override = 1'b0;
reg [14:0]  test_shared_addr = 15'd0;
reg [7:0]   test_shared_data = 8'd0;
reg         sound_state_hold = 1'b0;
reg         main_cpu_run = 1'b1;
reg         sound_restore_enable = 1'b0;
reg         sound_restore_commit = 1'b0;
reg [63:0]  sound_ss_data = 64'd0;
reg [31:0]  sound_ss_addr = 32'd0;
reg [7:0]   sound_ss_select = 8'd0;
reg         sound_ss_write = 1'b0;
reg         sound_ss_read = 1'b0;
wire [63:0] sound_ss_data_out;
wire        sound_ss_ack;
wire        sound_state_held;
reg         sound_restore_test_enabled = 1'b0;

assign sound_shared_addr =
    test_shared_override ? test_shared_addr : sound_core_shared_addr;
assign sound_shared_dout =
    test_shared_override ? test_shared_data : sound_core_shared_dout;
assign sound_shared_we =
    test_shared_override || sound_core_shared_we;
wire [7:0]  coin_control;
wire        v25_reset_n;
wire        irq4;
wire [23:0] last_program_fetch;
wire [31:0] bus_count;
wire [31:0] rom_read_count;
wire [31:0] wram_write_count;
wire [31:0] shared_write_count;
wire [31:0] gp_access_count;
wire [31:0] palette_write_count;
wire [31:0] io_access_count;
wire [31:0] unmapped_count;
wire [31:0] irq_count;
wire [31:0] iack_count;
wire [23:0] cpu_addr_debug;
wire [15:0] cpu_dout_debug;
wire [15:0] cpu_din_debug;
wire        main_cpu_rw;
wire        main_cpu_bus_active;
wire        cpu_ack_debug;
wire        cpu_iack_debug;
wire [15:0] main_debug_events;
wire        main_gp_idle;

grind_stormer_main u_main (
    .clk                     (clk),
    .rst                     (rst),
    .halt_n                  (1'b1),
    .hs_reset                (rst),
    .hs_rom_set_id           (2'd0),
    .hs_rom_identity_valid   (1'b0),
    .hs_config_download      (1'b0),
    .hs_config_wr            (1'b0),
    .hs_nvram_download       (1'b0),
    .hs_nvram_upload         (1'b0),
    .hs_nvram_wr             (1'b0),
    .hs_nvram_rd             (1'b0),
    .hs_addr                 (27'd0),
    .hs_dout                 (8'd0),
    .hs_ss_active            (1'b0),
    .hs_din                  (),
    .hs_wait                 (),
    .hs_dirty                (),
    .hs_active               (),
    .rom_cs                  (rom_cs),
    .rom_addr                (rom_addr),
    .rom_data                (rom_data),
    .rom_ok                  (rom_ok),
    .in1_data                (IDLE_INPUT_WORD),
    .in2_data                (IDLE_INPUT_WORD),
    .sys_data                (IDLE_INPUT_WORD),
    .hcnt                    (hcnt),
    .vcnt                    (vcnt),
    .irq4_start              (irq4_start),
    .sound_clk               (clk),
    .sound_shared_addr       (sound_shared_addr),
    .sound_shared_din        (sound_shared_dout),
    .sound_shared_we         (sound_shared_we),
    .sound_shared_dout       (sound_shared_din),
    .coin_control            (coin_control),
    .v25_reset_n             (v25_reset_n),
    .wram_scan_addr          (13'd0),
    .wram_scan_dout          (),
    .palette_scan_addr       (11'd0),
    .palette_scan_dout       (),
    .gp0_scan_addr           (13'd0),
    .gp0_scan_dout           (),
    .gp_obj_buf_start        (obj_buf_start),
    .gp0_obj_scan_addr       (10'd0),
    .gp0_obj_scan_dout       (),
    .gp0_obj_buf_busy        (),
    .gp0_obj_buf_miss        (),
    .gp0_scrolls             (),
    .gp0_scroll_flip         (),
    .cpu_cen                 (),
    .cpu_cenb                (),
    .cpu_bus_active          (main_cpu_bus_active),
    .cpu_rw                  (main_cpu_rw),
    .irq4                    (irq4),
    .last_program_fetch      (last_program_fetch),
    .bus_count               (bus_count),
    .rom_read_count          (rom_read_count),
    .wram_write_count        (wram_write_count),
    .shared_write_count      (shared_write_count),
    .gp_access_count         (gp_access_count),
    .palette_write_count     (palette_write_count),
    .io_access_count         (io_access_count),
    .unmapped_count          (unmapped_count),
    .irq_count               (irq_count),
    .iack_count              (iack_count),
    .cpu_addr_debug          (cpu_addr_debug),
    .cpu_dout_debug          (cpu_dout_debug),
    .cpu_din_debug           (cpu_din_debug),
    .gp0_ptr                 (),
    .debug_events            (main_debug_events),
    .ss_irq                  (1'b0),
    .ss_override             (1'b0),
    .ss_reset                (1'b0),
    .ss_cpu_run              (main_cpu_run),
    .ss_hold                 (sound_state_hold),
    .ss_restore_enable       (1'b0),
    .ss_restore_commit       (1'b0),
    .ss_restore_irq4         (1'b0),
    .ss_restore_coin_control (8'd0),
    .ss_reset_vector         (64'd0),
    .cpu_ack_debug           (cpu_ack_debug),
    .cpu_iack_debug          (cpu_iack_debug),
    .cpu_lds_n_debug         (),
    .cpu_fc_debug            (),
    .gp_idle                 (main_gp_idle),
    .ss_data                 (64'd0),
    .ss_addr                 (32'd0),
    .ss_select               (8'd0),
    .ss_write                (1'b0),
    .ss_read                 (1'b0),
    .ss_query                (1'b0),
    .ss_data_out             (),
    .ss_ack                  ()
);

wire signed [15:0] snd_mono;
wire sample;
wire sound_fault;
wire sound_halted;
wire [19:0] sound_pc;
wire sound_state_idle;
wire sound_v25_reset_n;
wire sound_ym_write;
wire sound_ym_a0;
wire [7:0] sound_ym_data;
wire sound_v25_cen;

grind_stormer_sound u_sound (
    .reset               (rst),
    .clk                 (clk),
    .v25_enable          (v25_reset_n),
    .dip_a               (8'h00),
    .dip_b               (8'h00),
    .jmpr                (8'h90),
    .ym_enable           (1'b1),
    .state_hold          (sound_state_hold),
    .pause               (1'b0),
    .main_shared_write   (test_shared_override ?
                          1'b1 : main_debug_events[3]),
    .main_shared_addr    (test_shared_override ?
                          test_shared_addr : cpu_addr_debug[15:1]),
    .main_shared_data    (test_shared_override ?
                          test_shared_data : cpu_dout_debug[7:0]),
    .ss_restore_enable   (sound_restore_enable),
    .ss_restore_commit   (sound_restore_commit),
    .ss_data             (sound_ss_data),
    .ss_addr             (sound_ss_addr),
    .ss_select           (sound_ss_select),
    .ss_write            (sound_ss_write),
    .ss_read             (sound_ss_read),
    .ss_query            (1'b0),
    .ss_data_out         (sound_ss_data_out),
    .ss_ack              (sound_ss_ack),
    .shared_addr         (sound_core_shared_addr),
    .shared_dout         (sound_core_shared_dout),
    .shared_we           (sound_core_shared_we),
    .shared_din          (sound_shared_din),
    .snd_mono            (snd_mono),
    .sample              (sample),
    .debug_fault         (sound_fault),
    .debug_halted        (sound_halted),
    .debug_pc            (sound_pc),
    .debug_state_idle    (),
    .state_idle          (sound_state_idle),
    .state_held          (sound_state_held),
    .debug_v25_reset_n   (sound_v25_reset_n),
    .debug_ym_write      (sound_ym_write),
    .debug_ym_a0         (sound_ym_a0),
    .debug_ym_data       (sound_ym_data),
    .debug_v25_cen       (sound_v25_cen),
    .debug_ym_cen        (),
    .debug_ym_cen_p1     (),
    .debug_ym_status     ()
);

integer ym_write_count = 0;
integer first_ym_frame = -1;
integer first_ym_cycle = -1;
integer rtl_instruction_count = 0;
integer v25_clock_count = 0;
integer previous_instruction_clock = 0;
integer first_gp_cycle = -1;
integer first_palette_cycle = -1;
integer first_irq_cycle = -1;
integer first_iack_cycle = -1;
integer first_polled_handler_cycle = -1;
integer polled_handler_count = 0;
integer first_post_upload_shared_cycle = -1;
integer last_main_shared_cycle = -1;
integer last_sound_shared_cycle = -1;
integer gp_irq_clear_count = 0;
reg [23:0] last_main_shared_addr = 24'd0;
reg [7:0] last_main_shared_data = 8'd0;
reg [14:0] last_sound_shared_addr = 15'd0;
reg [7:0] last_sound_shared_data = 8'd0;
reg [7:0] previous_coin_control = 8'h00;
reg idle_sys_read_seen = 1'b0;

always @(posedge clk) begin
    if (rst) begin
        idle_sys_read_seen <= 1'b0;
    end else if (cpu_ack_debug && main_cpu_rw &&
                 ((cpu_addr_debug & 24'hfffffe) == 24'h200018)) begin
        idle_sys_read_seen <= 1'b1;
        if (cpu_din_debug !== IDLE_INPUT_WORD)
            $fatal(1, "idle SYS read returned %04x", cpu_din_debug);
    end
end

always @(posedge clk) begin
    if (!sound_v25_reset_n) begin
        rtl_instruction_count = 0;
        v25_clock_count = 0;
        previous_instruction_clock = 0;
    end else if (sound_v25_cen) begin
        v25_clock_count = v25_clock_count + 1;
        if (u_sound.u_v25.instruction_done) begin
            if (rtl_instruction_trace_fd != 0)
                $fwrite(rtl_instruction_trace_fd,
                    "%0d,%0d,%0d,%05x,%02x,%0d,%0d\n",
                    rtl_instruction_count, v25_clock_count,
                    v25_clock_count - previous_instruction_clock,
                    u_sound.u_v25.instruction_next_pc,
                    u_sound.u_v25.instruction_opcode,
                    master_cycle, frame_count);
            rtl_instruction_count = rtl_instruction_count + 1;
            previous_instruction_clock = v25_clock_count;
        end
    end
end

always @(posedge clk) begin
    if (!rst) begin
        if (coin_control != previous_coin_control) begin
            $display(
                "LANDMARK coin_control cycle=%0d frame=%0d data=%02x pc=%06x fetch=%06x",
                master_cycle, frame_count, coin_control,
                u_main.u_main68k.PC[23:0], last_program_fetch);
            previous_coin_control = coin_control;
        end
        if (u_main.gp0_irq_clear) begin
            gp_irq_clear_count = gp_irq_clear_count + 1;
        end
        if (u_main.ack_now && u_main.normal_rom_read_cs &&
            u_main.cpu_program_space &&
            (cpu_addr_debug == 24'h0002ce)) begin
            polled_handler_count = polled_handler_count + 1;
            if (first_polled_handler_cycle < 0) begin
                first_polled_handler_cycle = master_cycle;
                $display(
                    "LANDMARK first_polled_handler cycle=%0d frame=%0d sr_i=%0d irq=%0b",
                    master_cycle, frame_count, u_main.u_main68k.pswI,
                    irq4);
            end
        end
        if ((first_gp_cycle < 0) &&
            u_main.ack_now && u_main.gp_cs && u_main.cpu_write) begin
            first_gp_cycle = master_cycle;
            $display(
                "LANDMARK first_gp cycle=%0d frame=%0d addr=%06x data=%04x fetch=%06x",
                master_cycle, frame_count, cpu_addr_debug,
                cpu_dout_debug, last_program_fetch);
        end
        if ((first_palette_cycle < 0) && main_debug_events[6]) begin
            first_palette_cycle = master_cycle;
            $display(
                "LANDMARK first_palette cycle=%0d frame=%0d addr=%06x data=%04x fetch=%06x",
                master_cycle, frame_count, cpu_addr_debug,
                cpu_dout_debug, last_program_fetch);
        end
        if ((first_irq_cycle < 0) && main_debug_events[10]) begin
            first_irq_cycle = master_cycle;
            $display("LANDMARK first_irq cycle=%0d frame=%0d",
                master_cycle, frame_count);
        end
        if ((first_iack_cycle < 0) && cpu_iack_debug) begin
            first_iack_cycle = master_cycle;
            $display(
                "LANDMARK first_iack cycle=%0d frame=%0d fetch=%06x",
                master_cycle, frame_count, last_program_fetch);
        end
        if (main_debug_events[3]) begin
            last_main_shared_cycle = master_cycle;
            last_main_shared_addr = cpu_addr_debug;
            last_main_shared_data = cpu_dout_debug[7:0];
            if ((first_post_upload_shared_cycle < 0) &&
                (shared_write_count >= 32'd512)) begin
                first_post_upload_shared_cycle = master_cycle;
                $display(
                    "LANDMARK first_post_upload_shared cycle=%0d frame=%0d addr=%06x data=%02x fetch=%06x",
                    master_cycle, frame_count, cpu_addr_debug,
                    cpu_dout_debug[7:0], last_program_fetch);
            end
        end
        if (sound_shared_we) begin
            last_sound_shared_cycle = master_cycle;
            last_sound_shared_addr = sound_shared_addr;
            last_sound_shared_data = sound_shared_dout;
        end
    end
end

always @(negedge clk) begin
    if (!rst) begin
        if (sound_fault)
            $fatal(1, "V25 fault at pc=%05x frame=%0d", sound_pc, frame_count);
        if (sound_halted)
            $fatal(1, "V25 halted at pc=%05x frame=%0d", sound_pc, frame_count);
        if (sound_ym_write) begin
            if (ym_write_count < YM_GOLDEN_WRITES) begin
                if ({sound_ym_a0, sound_ym_data} !==
                    ym_golden[ym_write_count])
                    $fatal(1,
                        "YM write %0d mismatch frame=%0d pc=%05x got=%03x expected=%03x",
                        ym_write_count, frame_count, sound_pc,
                        {sound_ym_a0, sound_ym_data},
                        ym_golden[ym_write_count]);
            end
            if (ym_write_count == 0) begin
                first_ym_frame = frame_count;
                first_ym_cycle = master_cycle;
                $display(
                    "LANDMARK first_ym cycle=%0d frame=%0d sound_pc=%05x main_fetch=%06x instructions=%0d v25_clocks=%0d main_shared_count=%0d last_main_shared=%0d/%06x/%02x last_sound_shared=%0d/%04x/%02x",
                    master_cycle, frame_count, sound_pc,
                    last_program_fetch, rtl_instruction_count,
                    v25_clock_count, shared_write_count,
                    last_main_shared_cycle,
                    last_main_shared_addr, last_main_shared_data,
                    last_sound_shared_cycle, last_sound_shared_addr,
                    last_sound_shared_data);
            end
            ym_write_count = ym_write_count + 1;
            if ((ym_write_count == YM_GOLDEN_WRITES) &&
                (rtl_instruction_trace_fd != 0)) begin
                $fflush(rtl_instruction_trace_fd);
                $fclose(rtl_instruction_trace_fd);
                rtl_instruction_trace_fd = 0;
                rtl_instruction_trace_closed = 1'b1;
            end
        end
    end
end

integer release_cycle;
integer upload_index;
integer timeout_cycles;
integer compare_candidate;
integer compare_index;
integer gp_mismatches [0:2];
integer object_mismatches [0:2];
integer palette_mismatches [0:2];
integer work_mismatches [0:2];
integer shared_mismatches [0:2];
integer scroll_mismatches [0:2];
integer compare_gp_index;
reg [15:0] compare_rtl_word;
reg [15:0] compare_expected_word;
reg [7:0] compare_expected_byte;
integer rtl_state_fd;
reg mame_visual_state_match = 1'b0;

task automatic dump_rtl_state;
    begin
        rtl_state_path = $sformatf(
            "%s/gp9001-frame-%06d.hex",
            rtl_state_directory, frame_count);
        rtl_state_fd = $fopen(rtl_state_path, "w");
        if (rtl_state_fd == 0)
            $fatal(1, "could not open RTL GP state dump");
        for (compare_index = 0; compare_index < 8192;
             compare_index = compare_index + 1) begin
            compare_gp_index = (compare_index >= 7168) ?
                               compare_index - 1024 : compare_index;
            $fdisplay(rtl_state_fd, "%04x", {
                u_main.u_gp0.u_vram.u_hi.u_ram.mem[compare_gp_index],
                u_main.u_gp0.u_vram.u_lo.u_ram.mem[compare_gp_index]
            });
        end
        $fclose(rtl_state_fd);

        rtl_state_path = $sformatf(
            "%s/palette-frame-%06d.hex",
            rtl_state_directory, frame_count);
        rtl_state_fd = $fopen(rtl_state_path, "w");
        if (rtl_state_fd == 0)
            $fatal(1, "could not open RTL palette state dump");
        for (compare_index = 0; compare_index < 2048;
             compare_index = compare_index + 1)
            $fdisplay(rtl_state_fd, "%04x", {
                u_main.u_palette_ram.u_hi.u_ram.mem[compare_index],
                u_main.u_palette_ram.u_lo.u_ram.mem[compare_index]
            });
        $fclose(rtl_state_fd);

        rtl_state_path = $sformatf(
            "%s/work-frame-%06d.hex",
            rtl_state_directory, frame_count);
        rtl_state_fd = $fopen(rtl_state_path, "w");
        if (rtl_state_fd == 0)
            $fatal(1, "could not open RTL work-RAM state dump");
        for (compare_index = 0; compare_index < 8192;
             compare_index = compare_index + 1)
            $fdisplay(rtl_state_fd, "%04x", {
                u_main.u_wram.u_hi.u_ram.mem[compare_index],
                u_main.u_wram.u_lo.u_ram.mem[compare_index]
            });
        $fclose(rtl_state_fd);

        rtl_state_path = $sformatf(
            "%s/shared-frame-%06d.hex",
            rtl_state_directory, frame_count);
        rtl_state_fd = $fopen(rtl_state_path, "w");
        if (rtl_state_fd == 0)
            $fatal(1, "could not open RTL shared-RAM state dump");
        for (compare_index = 0; compare_index < 32768;
             compare_index = compare_index + 1)
            $fdisplay(rtl_state_fd, "%02x",
                u_main.u_shared_ram.u_ram.mem[compare_index]);
        $fclose(rtl_state_fd);

        rtl_state_path = $sformatf(
            "%s/scroll-frame-%06d.hex",
            rtl_state_directory, frame_count);
        rtl_state_fd = $fopen(rtl_state_path, "w");
        if (rtl_state_fd == 0)
            $fatal(1, "could not open RTL scroll state dump");
        for (compare_index = 0; compare_index < 8;
             compare_index = compare_index + 1)
            $fdisplay(rtl_state_fd, "%04x",
                u_main.u_gp0.scroll_reg[compare_index]);
        $fdisplay(rtl_state_fd, "%04x",
            {8'd0, u_main.u_gp0.flip_reg});
        $fclose(rtl_state_fd);

        rtl_state_path = $sformatf(
            "%s/object-active-frame-%06d.hex",
            rtl_state_directory, frame_count);
        rtl_state_fd = $fopen(rtl_state_path, "w");
        if (rtl_state_fd == 0)
            $fatal(1, "could not open RTL object state dump");
        for (compare_index = 0; compare_index < 1024;
             compare_index = compare_index + 1) begin
            if (u_main.u_gp0.obj_active_bank)
                compare_rtl_word = {
                    u_main.u_gp0.u_obj_bank1.u_hi.u_ram.mem[compare_index],
                    u_main.u_gp0.u_obj_bank1.u_lo.u_ram.mem[compare_index]
                };
            else
                compare_rtl_word = {
                    u_main.u_gp0.u_obj_bank0.u_hi.u_ram.mem[compare_index],
                    u_main.u_gp0.u_obj_bank0.u_lo.u_ram.mem[compare_index]
                };
            $fdisplay(rtl_state_fd, "%04x", compare_rtl_word);
        end
        $fclose(rtl_state_fd);

        rtl_state_path = $sformatf(
            "%s/manifest.txt", rtl_state_directory);
        rtl_state_fd = $fopen(rtl_state_path, "w");
        if (rtl_state_fd == 0)
            $fatal(1, "could not open RTL state manifest");
        $fdisplay(rtl_state_fd,
            "frame=%0d master_cycle=%0d pc=%06x fetch=%06x sr_i=%0d irq=%0b coin=%02x active_object_bank=%0d",
            frame_count, master_cycle, u_main.u_main68k.PC[23:0],
            last_program_fetch, u_main.u_main68k.pswI, irq4,
            coin_control, u_main.u_gp0.obj_active_bank);
        $fclose(rtl_state_fd);
        $display("RTL_STATE output=%s frame=%0d",
            rtl_state_directory, frame_count);
    end
endtask

task automatic compare_mame_state;
    begin
        mame_visual_state_match = 1'b0;
        for (compare_candidate = 0; compare_candidate < 3;
             compare_candidate = compare_candidate + 1) begin
            gp_mismatches[compare_candidate] = 0;
            object_mismatches[compare_candidate] = 0;
            palette_mismatches[compare_candidate] = 0;
            work_mismatches[compare_candidate] = 0;
            shared_mismatches[compare_candidate] = 0;
            scroll_mismatches[compare_candidate] = 0;

            for (compare_index = 0; compare_index < 8192;
                 compare_index = compare_index + 1) begin
                compare_gp_index = (compare_index >= 7168) ?
                                   compare_index - 1024 : compare_index;
                compare_rtl_word = {
                    u_main.u_gp0.u_vram.u_hi.u_ram.mem[compare_gp_index],
                    u_main.u_gp0.u_vram.u_lo.u_ram.mem[compare_gp_index]
                };
                case (compare_candidate)
                    0: compare_expected_word =
                        mame_gp_prev[compare_index];
                    1: compare_expected_word =
                        mame_gp_same[compare_index];
                    default: compare_expected_word =
                        mame_gp_next[compare_index];
                endcase
                if (compare_rtl_word !== compare_expected_word)
                    gp_mismatches[compare_candidate] =
                        gp_mismatches[compare_candidate] + 1;

                compare_rtl_word = {
                    u_main.u_wram.u_hi.u_ram.mem[compare_index],
                    u_main.u_wram.u_lo.u_ram.mem[compare_index]
                };
                case (compare_candidate)
                    0: compare_expected_word =
                        mame_work_prev[compare_index];
                    1: compare_expected_word =
                        mame_work_same[compare_index];
                    default: compare_expected_word =
                        mame_work_next[compare_index];
                endcase
                if (compare_rtl_word !== compare_expected_word)
                    work_mismatches[compare_candidate] =
                        work_mismatches[compare_candidate] + 1;
            end

            for (compare_index = 0; compare_index < 2048;
                 compare_index = compare_index + 1) begin
                compare_rtl_word = {
                    u_main.u_palette_ram.u_hi.u_ram.mem[compare_index],
                    u_main.u_palette_ram.u_lo.u_ram.mem[compare_index]
                };
                case (compare_candidate)
                    0: compare_expected_word =
                        mame_palette_prev[compare_index];
                    1: compare_expected_word =
                        mame_palette_same[compare_index];
                    default: compare_expected_word =
                        mame_palette_next[compare_index];
                endcase
                if (compare_rtl_word !== compare_expected_word)
                    palette_mismatches[compare_candidate] =
                        palette_mismatches[compare_candidate] + 1;
            end

            for (compare_index = 0; compare_index < 1024;
                 compare_index = compare_index + 1) begin
                if (u_main.u_gp0.obj_active_bank)
                    compare_rtl_word = {
                        u_main.u_gp0.u_obj_bank1.u_hi.u_ram.mem[
                            compare_index],
                        u_main.u_gp0.u_obj_bank1.u_lo.u_ram.mem[
                            compare_index]
                    };
                else
                    compare_rtl_word = {
                        u_main.u_gp0.u_obj_bank0.u_hi.u_ram.mem[
                            compare_index],
                        u_main.u_gp0.u_obj_bank0.u_lo.u_ram.mem[
                            compare_index]
                    };
                case (compare_candidate)
                    0: compare_expected_word =
                        mame_gp_prev[13'h1800 + compare_index];
                    1: compare_expected_word =
                        mame_gp_same[13'h1800 + compare_index];
                    default: compare_expected_word =
                        mame_gp_next[13'h1800 + compare_index];
                endcase
                if (compare_rtl_word !== compare_expected_word)
                    object_mismatches[compare_candidate] =
                        object_mismatches[compare_candidate] + 1;
            end

            for (compare_index = 0; compare_index < 32768;
                 compare_index = compare_index + 1) begin
                case (compare_candidate)
                    0: compare_expected_byte =
                        mame_shared_prev[compare_index];
                    1: compare_expected_byte =
                        mame_shared_same[compare_index];
                    default: compare_expected_byte =
                        mame_shared_next[compare_index];
                endcase
                if (u_main.u_shared_ram.u_ram.mem[compare_index] !==
                    compare_expected_byte)
                    shared_mismatches[compare_candidate] =
                        shared_mismatches[compare_candidate] + 1;
            end

            for (compare_index = 0; compare_index < 8;
                 compare_index = compare_index + 1) begin
                case (compare_candidate)
                    0: compare_expected_word =
                        mame_scroll_prev[compare_index];
                    1: compare_expected_word =
                        mame_scroll_same[compare_index];
                    default: compare_expected_word =
                        mame_scroll_next[compare_index];
                endcase
                if (u_main.u_gp0.scroll_reg[compare_index] !==
                    compare_expected_word)
                    scroll_mismatches[compare_candidate] =
                        scroll_mismatches[compare_candidate] + 1;
            end
            case (compare_candidate)
                0: compare_expected_word = mame_scroll_prev[8];
                1: compare_expected_word = mame_scroll_same[8];
                default: compare_expected_word = mame_scroll_next[8];
            endcase
            if ({8'd0, u_main.u_gp0.flip_reg} !== compare_expected_word)
                scroll_mismatches[compare_candidate] =
                    scroll_mismatches[compare_candidate] + 1;

            if ((gp_mismatches[compare_candidate] == 0) &&
                (object_mismatches[compare_candidate] == 0) &&
                (palette_mismatches[compare_candidate] == 0) &&
                (scroll_mismatches[compare_candidate] == 0))
                mame_visual_state_match = 1'b1;

            $display(
                "MAME_STATE candidate_frame=%0d rtl_frame=%0d gp=%0d/8192 object=%0d/1024 palette=%0d/2048 work=%0d/8192 shared=%0d/32768 scroll=%0d/9",
                mame_reference_frame + compare_candidate - 1,
                frame_count, gp_mismatches[compare_candidate],
                object_mismatches[compare_candidate],
                palette_mismatches[compare_candidate],
                work_mismatches[compare_candidate],
                shared_mismatches[compare_candidate],
                scroll_mismatches[compare_candidate]);
        end
        if (!mame_visual_state_match)
            $fatal(1,
                "no adjacent MAME frame matched complete RTL visual state");
    end
endtask

reg [63:0] sound_saved_v25 [0:38];
reg [63:0] sound_saved_policy;
integer sound_state_index;
integer sound_replay_ack_count = 0;
integer sound_replay_argument_writes = 0;
integer sound_replay_command_writes = 0;

always @(posedge clk) begin
    if (!rst) begin
        if ((u_sound.bgm_replay_state == 3'd4) &&
            u_sound.v25_mailbox_ready_write)
            sound_replay_ack_count <= sound_replay_ack_count + 1;
        if (u_sound.bgm_replay_write_argument)
            sound_replay_argument_writes <=
                sound_replay_argument_writes + 1;
        if (u_sound.bgm_replay_write_command)
            sound_replay_command_writes <=
                sound_replay_command_writes + 1;
    end
end

task automatic sound_read_state_word;
    input [7:0] select_value;
    input [31:0] address_value;
    output reg [63:0] value;
    integer wait_count;
    begin
        @(negedge clk);
        sound_ss_select = select_value;
        sound_ss_addr = address_value;
        sound_ss_read = 1'b1;
        wait_count = 0;
        while (!sound_ss_ack) begin
            @(negedge clk);
            wait_count = wait_count + 1;
            if (wait_count > 64)
                $fatal(1,
                    "sound state read timeout chunk=%0d address=%0d",
                    select_value, address_value);
        end
        value = sound_ss_data_out;
        sound_ss_read = 1'b0;
        @(negedge clk);
        sound_ss_select = 8'd0;
        sound_ss_addr = 32'd0;
    end
endtask

task automatic sound_write_state_word;
    input [7:0] select_value;
    input [31:0] address_value;
    input [63:0] value;
    integer wait_count;
    begin
        @(negedge clk);
        sound_ss_select = select_value;
        sound_ss_addr = address_value;
        sound_ss_data = value;
        sound_ss_write = 1'b1;
        wait_count = 0;
        while (!sound_ss_ack) begin
            @(negedge clk);
            wait_count = wait_count + 1;
            if (wait_count > 64)
                $fatal(1,
                    "sound state write timeout chunk=%0d address=%0d",
                    select_value, address_value);
        end
        sound_ss_write = 1'b0;
        @(negedge clk);
        sound_ss_select = 8'd0;
        sound_ss_addr = 32'd0;
        sound_ss_data = 64'd0;
    end
endtask

task automatic test_write_shared_byte;
    input [14:0] address_value;
    input [7:0] value;
    begin
        @(negedge clk);
        test_shared_addr = address_value;
        test_shared_data = value;
        test_shared_override = 1'b1;
        @(negedge clk);
        test_shared_override = 1'b0;
        test_shared_addr = 15'd0;
        test_shared_data = 8'd0;
    end
endtask

task automatic wait_sound_held;
    input integer max_cycles;
    integer wait_count;
    begin
        wait_count = 0;
        while (!sound_state_held) begin
            @(negedge clk);
            wait_count = wait_count + 1;
            if (wait_count > max_cycles)
                $fatal(1,
                    "sound hold timeout pc=%05x replay=%0d ready=%0b",
                    sound_pc, u_sound.bgm_replay_state,
                    u_sound.mailbox_ready);
        end
    end
endtask

task automatic dump_focused_sound_fixture;
    integer fixture_fd;
    integer fixture_index;
    begin
        if (sound_fixture_shared_path.len() == 0 ||
            sound_fixture_v25_path.len() == 0 ||
            sound_fixture_policy_path.len() == 0)
            disable dump_focused_sound_fixture;

        fixture_fd = $fopen(sound_fixture_shared_path, "w");
        if (fixture_fd == 0)
            $fatal(1, "could not create focused shared fixture");
        for (fixture_index = 0; fixture_index < 32768;
             fixture_index = fixture_index + 1)
            $fdisplay(fixture_fd, "%02x",
                u_main.u_shared_ram.u_ram.mem[fixture_index]);
        $fclose(fixture_fd);

        fixture_fd = $fopen(sound_fixture_v25_path, "w");
        if (fixture_fd == 0)
            $fatal(1, "could not create focused V25 fixture");
        for (fixture_index = 0; fixture_index < 39;
             fixture_index = fixture_index + 1)
            $fdisplay(fixture_fd, "%016x",
                sound_saved_v25[fixture_index]);
        $fclose(fixture_fd);

        fixture_fd = $fopen(sound_fixture_policy_path, "w");
        if (fixture_fd == 0)
            $fatal(1, "could not create focused policy fixture");
        $fdisplay(fixture_fd, "%016x", sound_saved_policy);
        $fclose(fixture_fd);

        $display(
            "LANDMARK focused_sound_fixture shared=%s v25=%s policy=%s",
            sound_fixture_shared_path,
            sound_fixture_v25_path,
            sound_fixture_policy_path);
    end
endtask

task automatic dump_ready_sound_baseline;
    integer baseline_fd;
    integer baseline_index;
    begin
        if (sound_baseline_v25_path.len() == 0 ||
            sound_baseline_work_path.len() == 0)
            disable dump_ready_sound_baseline;
        if (!u_sound.baseline_valid)
            $fatal(1, "sound baseline was not captured");

        baseline_fd = $fopen(sound_baseline_v25_path, "w");
        if (baseline_fd == 0)
            $fatal(1, "could not create V25 baseline fixture");
        for (baseline_index = 0; baseline_index < 39;
             baseline_index = baseline_index + 1)
            $fdisplay(baseline_fd, "%016x",
                u_sound.v25_ready_baseline[baseline_index]);
        $fclose(baseline_fd);

        baseline_fd = $fopen(sound_baseline_work_path, "w");
        if (baseline_fd == 0)
            $fatal(1, "could not create V25 work baseline fixture");
        for (baseline_index = 0; baseline_index < 2560;
             baseline_index = baseline_index + 1)
            $fdisplay(baseline_fd, "%02x",
                u_sound.v25_work_baseline[baseline_index]);
        $fclose(baseline_fd);

        $display(
            "LANDMARK sound_ready_baseline v25=%s work=%s pc=%05x",
            sound_baseline_v25_path,
            sound_baseline_work_path,
            sound_pc);
    end
endtask

task automatic run_sound_restore_test;
    integer wait_count;
    integer ym_before_restore;
    integer start_frame;
    begin
        start_frame = frame_count;
        while ((!u_sound.mailbox_ready || !sound_state_idle) &&
               (frame_count < start_frame + 4))
            @(negedge clk);
        if (!u_sound.mailbox_ready || !sound_state_idle)
            $fatal(1,
                "sound mailbox did not reach a save-safe boundary");
        $display(
            "LANDMARK focused_sound_idle frame=%0d cycle=%0d pc=%05x",
            frame_count, master_cycle, sound_pc);

        @(negedge clk);
        while (main_cpu_bus_active)
            @(negedge clk);
        main_cpu_run = 1'b0;
        sound_state_hold = 1'b1;
        wait_sound_held(100000);

        // MAME trace: argument 00 is durable BGM and command 01 starts music.
        test_write_shared_byte(15'h7801, 8'h00);
        test_write_shared_byte(15'h7800, 8'h01);
        sound_state_hold = 1'b0;
        main_cpu_run = 1'b1;

        wait_count = 0;
        while (!(u_sound.bgm_valid &&
                 (u_sound.bgm_command == 8'h01) &&
                 (u_sound.bgm_argument == 8'h00) &&
                 u_sound.mailbox_ready)) begin
            @(negedge clk);
            wait_count = wait_count + 1;
            if (wait_count > RAW_FRAME_CYCLES * 4)
                $fatal(1,
                    "real V25 did not acknowledge synthetic BGM command");
        end
        $display(
            "LANDMARK focused_bgm_ack frame=%0d cycle=%0d ym=%0d",
            frame_count, master_cycle, ym_write_count);

        @(negedge clk);
        while (main_cpu_bus_active)
            @(negedge clk);
        main_cpu_run = 1'b0;
        sound_state_hold = 1'b1;
        wait_sound_held(100000);

        for (sound_state_index = 0; sound_state_index < 39;
             sound_state_index = sound_state_index + 1)
            sound_read_state_word(
                8'd9, sound_state_index, sound_saved_v25[sound_state_index]);
        sound_read_state_word(8'd10, 32'd0, sound_saved_policy);
        if (sound_saved_policy[31:16] !== 16'h0003 ||
            sound_saved_policy[39:32] !== 8'h01 ||
            sound_saved_policy[47:40] !== 8'h00 ||
            !sound_saved_policy[48])
            $fatal(1,
                "saved BGM policy mismatch: %016x",
                sound_saved_policy);
        dump_focused_sound_fixture();

        sound_restore_enable = 1'b1;
        for (sound_state_index = 0; sound_state_index < 39;
             sound_state_index = sound_state_index + 1)
            sound_write_state_word(
                8'd9, sound_state_index, sound_saved_v25[sound_state_index]);
        sound_write_state_word(8'd10, 32'd0, sound_saved_policy);

        ym_before_restore = ym_write_count;
        @(negedge clk);
        sound_restore_commit = 1'b1;
        @(negedge clk);
        sound_restore_commit = 1'b0;

        // Require restore to leave the held state, replay, and return only
        // after the real V25 has acknowledged the injected command.
        wait_count = 0;
        while (sound_state_held && wait_count < 1024) begin
            @(negedge clk);
            wait_count = wait_count + 1;
        end
        if (sound_state_held)
            $fatal(1, "sound restore never entered its active phase");
        wait_sound_held(RAW_FRAME_CYCLES * 120);

        if (sound_replay_argument_writes != 1 ||
            sound_replay_command_writes != 1 ||
            sound_replay_ack_count != 1)
            $fatal(1,
                "BGM replay handshake mismatch arg=%0d command=%0d ack=%0d",
                sound_replay_argument_writes,
                sound_replay_command_writes,
                sound_replay_ack_count);
        if (ym_write_count <= ym_before_restore)
            $fatal(1, "BGM replay emitted no IKAOPM traffic");
        if (!u_sound.bgm_valid ||
            u_sound.bgm_command !== 8'h01 ||
            u_sound.bgm_argument !== 8'h00 ||
            !u_sound.mailbox_ready)
            $fatal(1, "durable BGM state changed across restore");

        sound_restore_enable = 1'b0;
        sound_state_hold = 1'b0;
        main_cpu_run = 1'b1;
        start_frame = frame_count;
        while (frame_count < start_frame + 12)
            @(negedge clk);
        $display(
            "PASS focused_sound_restore frame=%0d ym_before=%0d ym_after=%0d arg=%0d command=%0d ack=%0d",
            frame_count, ym_before_restore, ym_write_count,
            sound_replay_argument_writes,
            sound_replay_command_writes,
            sound_replay_ack_count);
    end
endtask

initial begin
    repeat (64) @(posedge clk);
    rst = 1'b0;

    timeout_cycles = 0;
    while ((coin_control !== 8'h10) && timeout_cycles < 1000000) begin
        @(posedge clk);
        timeout_cycles = timeout_cycles + 1;
    end
    if (timeout_cycles == 1000000)
        $fatal(1,
            "real-ROM V25 release timeout coin=%02x pc_addr=%06x fetch=%06x",
            coin_control, cpu_addr_debug, last_program_fetch);
    release_cycle = master_cycle;
    $display(
        "LANDMARK v25_release cycle=%0d frame=%0d fetch=%06x bus=%0d rom=%0d shared=%0d",
        release_cycle, frame_count, last_program_fetch, bus_count,
        rom_read_count, shared_write_count);
    if (shared_write_count != 32'd512)
        $fatal(1, "V25 upload wrote %0d bytes, expected 512",
            shared_write_count);
    for (upload_index = 0; upload_index < 512;
         upload_index = upload_index + 1) begin
        if (u_main.u_shared_ram.u_ram.mem[15'h7e00 + upload_index] !==
            upload_golden[upload_index])
            $fatal(1,
                "V25 upload byte %0d mismatch got=%02x expected=%02x",
                upload_index,
                u_main.u_shared_ram.u_ram.mem[15'h7e00 + upload_index],
                upload_golden[upload_index]);
    end
    if (release_cycle < 50000 || release_cycle > 500000)
        $fatal(1, "V25 release cycle out of range: %0d", release_cycle);

    timeout_cycles = 0;
    while (!sound_v25_reset_n && timeout_cycles < 100000) begin
        @(posedge clk);
        timeout_cycles = timeout_cycles + 1;
    end
    if (!sound_v25_reset_n)
        $fatal(1, "V25 remained in reset after main release");

    while ((ym_write_count < YM_GOLDEN_WRITES) &&
           (frame_count < MAX_FRAMES))
        @(posedge clk);

    if (ym_write_count < YM_GOLDEN_WRITES)
        $fatal(1,
            "YM prefix timeout writes=%0d frame=%0d main_fetch=%06x v25_pc=%05x",
            ym_write_count, frame_count, last_program_fetch, sound_pc);
    if ((first_ym_cycle < MAME_FIRST_YM_CYCLE - RAW_FRAME_CYCLES) ||
        (first_ym_cycle > MAME_FIRST_YM_CYCLE + RAW_FRAME_CYCLES))
        $fatal(1,
            "first YM outside one-frame MAME window frame=%0d cycle=%0d mame=%0d",
            first_ym_frame, first_ym_cycle, MAME_FIRST_YM_CYCLE);
    dump_ready_sound_baseline();
    if ($test$plusargs("BASELINE_ONLY")) begin
        $display(
            "PASS sound_ready_baseline frame=%0d cycle=%0d ym=%0d",
            frame_count, master_cycle, ym_write_count);
        $finish;
    end

    while (frame_count < POST_BOOT_FRAME)
        @(posedge clk);
    if (rtl_state_dump_enabled)
        dump_rtl_state();
    if (mame_compare_enabled)
        compare_mame_state();
    if (irq_count < POST_BOOT_FRAME - 2 || !irq4 ||
        polled_handler_count != 4 || iack_count != 0 ||
        u_main.u_main68k.pswI != 3'd7)
        $fatal(1,
            "incorrect polled IRQ4 boot irq=%0d handlers=%0d iack=%0d line=%0b sr_i=%0d ripl=%0d iipl=%0d pc=%06x fetch=%06x addr=%06x coin=%02x gp=%0d palette=%0d shared=%0d clears=%0d",
            irq_count, polled_handler_count, iack_count, irq4,
            u_main.u_main68k.pswI,
            u_main.u_main68k.rIpl, u_main.u_main68k.iIpl,
            u_main.u_main68k.PC[23:0], last_program_fetch,
            cpu_addr_debug, coin_control, gp_access_count,
            palette_write_count, shared_write_count, gp_irq_clear_count);
    if (gp_access_count == 0 || palette_write_count == 0 ||
        wram_write_count == 0 || rom_read_count == 0)
        $fatal(1,
            "missing mapped activity rom=%0d wram=%0d gp=%0d palette=%0d",
            rom_read_count, wram_write_count, gp_access_count,
            palette_write_count);
    if (!idle_sys_read_seen)
        $fatal(1, "main CPU never sampled the idle SYS input word");
    timeout_cycles = 0;
    while (!main_gp_idle && timeout_cycles < 100000) begin
        @(posedge clk);
        timeout_cycles = timeout_cycles + 1;
    end
    if (!main_gp_idle)
        $fatal(1, "GP9001 did not return idle");

    if (sound_restore_test_enabled)
        run_sound_restore_test();

    $display(
        "PASS realrom_board_tb release_cycle=%0d first_gp_cycle=%0d first_palette_cycle=%0d first_irq_cycle=%0d first_polled_handler_cycle=%0d first_iack_cycle=%0d first_ym_frame=%0d first_ym_cycle=%0d ym=%0d irq=%0d handlers=%0d iack=%0d rom=%0d shared=%0d gp=%0d palette=%0d unmapped=%0d",
        release_cycle, first_gp_cycle, first_palette_cycle,
        first_irq_cycle, first_polled_handler_cycle, first_iack_cycle,
        first_ym_frame, first_ym_cycle, ym_write_count,
        irq_count, polled_handler_count, iack_count, rom_read_count,
        shared_write_count, gp_access_count, palette_write_count,
        unmapped_count);
    if ((rtl_instruction_trace_fd != 0) &&
        !rtl_instruction_trace_closed)
        $fclose(rtl_instruction_trace_fd);
    $finish;
end

initial begin
    #750000000;
    $fatal(1, "wall-clock simulation timeout");
end

endmodule
