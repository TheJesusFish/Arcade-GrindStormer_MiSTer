`timescale 1ns/1ps

module sound_restore_longevity_tb;

`ifdef GRINDSTORMER_SOUND_ACCELERATED_SIM
localparam integer FRAME_CYCLES = 167680;
localparam longint unsigned REPLAY_TIMEOUT_CYCLES = 64'd50000000;
`else
localparam integer FRAME_CYCLES = 14 * 432 * 262;
localparam longint unsigned REPLAY_TIMEOUT_CYCLES = 64'd220000000;
`endif
localparam integer YM_CAPTURE_WRITES = 16;
localparam [63:0] FNV_OFFSET = 64'hcbf2_9ce4_8422_2325;
localparam [63:0] FNV_PRIME = 64'h0000_0100_0000_01b3;

reg clk = 1'b0;
always #1 clk = ~clk;

reg reset = 1'b1;
reg v25_enable = 1'b0;
reg state_hold = 1'b0;
reg main_shared_write = 1'b0;
reg [14:0] main_shared_addr = 15'd0;
reg [7:0] main_shared_data = 8'd0;
reg ss_restore_enable = 1'b0;
reg ss_restore_commit = 1'b0;
reg [63:0] ss_data = 64'd0;
reg [31:0] ss_addr = 32'd0;
reg [7:0] ss_select = 8'd0;
reg ss_write = 1'b0;

wire [63:0] ss_data_out;
wire ss_ack;
wire [14:0] shared_addr;
wire [7:0] shared_dout;
wire shared_we;
reg [7:0] shared_din = 8'd0;
wire signed [15:0] snd_mono;
wire sample;
wire debug_fault;
wire debug_halted;
wire [19:0] debug_pc;
wire debug_state_idle;
wire state_idle;
wire state_held;
wire debug_v25_reset_n;
wire debug_ym_write;
wire debug_ym_a0;
wire [7:0] debug_ym_data;

reg [7:0] shared_fixture [0:32767];
reg [7:0] shared_ram [0:32767];
reg [63:0] v25_state [0:38];
reg [63:0] ready_v25_baseline [0:38];
reg [7:0] ready_work_baseline [0:2559];
reg [63:0] policy_state [0:0];
string shared_path;
string v25_path;
string baseline_v25_path;
string baseline_work_path;
string policy_path;

integer longevity_frames = 60;
integer restore_count = 2;
integer fixture_index;
integer restore_index;
longint unsigned master_cycle = 0;
longint unsigned ym_write_count = 0;
longint unsigned sample_count = 0;
longint unsigned nonzero_sample_count = 0;
reg [63:0] sample_hash = FNV_OFFSET;

reg [8:0] baseline_ym [0:YM_CAPTURE_WRITES-1];
integer ym_capture_count = 0;
integer ym_capture_restore = 0;
integer replay_argument_writes = 0;
integer replay_command_writes = 0;
integer replay_ack_writes = 0;

function automatic [63:0] fnv_byte;
    input [63:0] hash;
    input [7:0] value;
    begin
        fnv_byte = (hash ^ value) * FNV_PRIME;
    end
endfunction

grind_stormer_sound dut (
    .reset               (reset),
    .clk                 (clk),
    .v25_enable          (v25_enable),
    .dip_a               (8'h00),
    .dip_b               (8'h00),
    .jmpr                (8'h90),
    .ym_enable           (1'b1),
    .state_hold          (state_hold),
    .pause               (1'b0),
    .main_shared_write   (main_shared_write),
    .main_shared_addr    (main_shared_addr),
    .main_shared_data    (main_shared_data),
    .ss_restore_enable   (ss_restore_enable),
    .ss_restore_commit   (ss_restore_commit),
    .ss_data             (ss_data),
    .ss_addr             (ss_addr),
    .ss_select           (ss_select),
    .ss_write            (ss_write),
    .ss_read             (1'b0),
    .ss_query            (1'b0),
    .ss_data_out         (ss_data_out),
    .ss_ack              (ss_ack),
    .shared_addr         (shared_addr),
    .shared_dout         (shared_dout),
    .shared_we           (shared_we),
    .shared_din          (shared_din),
    .snd_mono            (snd_mono),
    .sample              (sample),
    .debug_fault         (debug_fault),
    .debug_halted        (debug_halted),
    .debug_pc            (debug_pc),
    .debug_state_idle    (debug_state_idle),
    .state_idle          (state_idle),
    .state_held          (state_held),
    .debug_v25_reset_n   (debug_v25_reset_n),
    .debug_ym_write      (debug_ym_write),
    .debug_ym_a0         (debug_ym_a0),
    .debug_ym_data       (debug_ym_data),
    .debug_v25_cen       (),
    .debug_ym_cen        (),
    .debug_ym_cen_p1     (),
    .debug_ym_status     ()
);

// Match the registered-read, read-before-write behavior of jtframe_dual_ram.
always @(posedge clk) begin
    shared_din <= shared_ram[shared_addr];
    if (shared_we)
        shared_ram[shared_addr] <= shared_dout;
end

always @(posedge clk) begin
    master_cycle <= master_cycle + 1;

    if (!reset) begin
        if (debug_fault)
            $fatal(1, "V25 fault pc=%05x cycle=%0d",
                debug_pc, master_cycle);
        if (debug_halted)
            $fatal(1, "V25 halted pc=%05x cycle=%0d",
                debug_pc, master_cycle);

        if (debug_ym_write) begin
            ym_write_count <= ym_write_count + 1;
            if (ym_capture_restore != 0 &&
                ym_capture_count < YM_CAPTURE_WRITES) begin
                if (ym_capture_restore == 1)
                    baseline_ym[ym_capture_count] <= {
                        debug_ym_a0, debug_ym_data
                    };
                else if ({debug_ym_a0, debug_ym_data} !==
                         baseline_ym[ym_capture_count])
                    $fatal(1,
                        "restore %0d YM mismatch index=%0d got=%03x expected=%03x",
                        ym_capture_restore, ym_capture_count,
                        {debug_ym_a0, debug_ym_data},
                        baseline_ym[ym_capture_count]);
                ym_capture_count <= ym_capture_count + 1;
            end
        end

        if (sample) begin
            sample_count <= sample_count + 1;
            if (snd_mono != 16'sd0)
                nonzero_sample_count <= nonzero_sample_count + 1;
            sample_hash <= fnv_byte(
                fnv_byte(sample_hash, snd_mono[7:0]),
                snd_mono[15:8]);
        end

        if (dut.bgm_replay_write_argument)
            replay_argument_writes <= replay_argument_writes + 1;
        if (dut.bgm_replay_write_command)
            replay_command_writes <= replay_command_writes + 1;
        if ((dut.bgm_replay_state == 3'd4) &&
            dut.v25_mailbox_ready_write)
            replay_ack_writes <= replay_ack_writes + 1;
    end
end

task automatic reload_shared_fixture;
    begin
        for (fixture_index = 0; fixture_index < 32768;
             fixture_index = fixture_index + 1)
            shared_ram[fixture_index] = shared_fixture[fixture_index];
        shared_din = shared_fixture[0];
    end
endtask

task automatic write_state_word;
    input [7:0] select_value;
    input [31:0] address_value;
    input [63:0] data_value;
    begin
        @(negedge clk);
        ss_select = select_value;
        ss_addr = address_value;
        ss_data = data_value;
        ss_write = 1'b1;
        while (!ss_ack)
            @(negedge clk);
        @(negedge clk);
        ss_write = 1'b0;
        ss_select = 8'd0;
        ss_addr = 32'd0;
        ss_data = 64'd0;
        while (ss_ack)
            @(negedge clk);
    end
endtask

task automatic wait_for_v25_boundary;
    longint unsigned deadline;
    begin
        deadline = master_cycle + 64'd20000000;
        while (!debug_state_idle) begin
            @(negedge clk);
            if (master_cycle > deadline)
                $fatal(1,
                    "V25 hold-boundary timeout pc=%05x ready=%0b",
                    debug_pc, dut.mailbox_ready);
        end
    end
endtask

task automatic wait_for_replay_complete;
    longint unsigned deadline;
    begin
        deadline = master_cycle + REPLAY_TIMEOUT_CYCLES;
        while (!state_held) begin
            @(negedge clk);
            if (master_cycle > deadline)
                $fatal(1,
                    "BGM replay timeout pc=%05x state=%0d ready=%0b",
                    debug_pc, dut.bgm_replay_state, dut.mailbox_ready);
        end
    end
endtask

task automatic verify_restored_baseline;
    begin
        while (!dut.baseline_restore_memory_active)
            @(negedge clk);
        while (dut.baseline_restore_memory_active)
            @(negedge clk);
        if (debug_v25_reset_n)
            $fatal(1, "V25 released before baseline-work check");
        for (fixture_index = 0; fixture_index < 2560;
             fixture_index = fixture_index + 1)
            if (shared_ram[15'h7400 + fixture_index] !==
                ready_work_baseline[fixture_index])
                $fatal(1,
                    "baseline-work mismatch at %04x got=%02x expected=%02x",
                    15'h7400 + fixture_index,
                    shared_ram[15'h7400 + fixture_index],
                    ready_work_baseline[fixture_index]);
    end
endtask

task automatic restore_saved_sound;
    input integer this_restore;
    begin
        state_hold = 1'b1;
        if (v25_enable)
            wait_for_v25_boundary();
        reload_shared_fixture();

        ss_restore_enable = 1'b1;
        if (v25_enable)
            for (fixture_index = 0; fixture_index < 39;
                 fixture_index = fixture_index + 1)
                write_state_word(
                    8'd9, fixture_index, v25_state[fixture_index]);
        write_state_word(8'd10, 32'd0, policy_state[0]);

        replay_argument_writes = 0;
        replay_command_writes = 0;
        replay_ack_writes = 0;
        ym_capture_restore = this_restore;
        ym_capture_count = 0;

        @(negedge clk);
        ss_restore_commit = 1'b1;
        @(negedge clk);
        ss_restore_commit = 1'b0;
        v25_enable = 1'b1;
        verify_restored_baseline();
        wait_for_replay_complete();

        if (replay_argument_writes != 1 ||
            replay_command_writes != 1 ||
            replay_ack_writes != 1)
            $fatal(1,
                "restore %0d replay mismatch arg=%0d command=%0d ack=%0d",
                this_restore, replay_argument_writes,
                replay_command_writes, replay_ack_writes);

        state_hold = 1'b0;
        while (ym_capture_count < YM_CAPTURE_WRITES)
            @(negedge clk);
        ym_capture_restore = 0;
        ss_restore_enable = 1'b0;

        $display(
            "LANDMARK sound_restore index=%0d cycle=%0d ym=%0d pc=%05x",
            this_restore, master_cycle, ym_write_count, debug_pc);
    end
endtask

task automatic run_longevity_window;
    input integer this_restore;
    integer window_frames;
    integer frames_remaining;
    longint unsigned target_cycle;
    longint unsigned ym_before;
    longint unsigned samples_before;
    begin
        frames_remaining = longevity_frames;
        while (frames_remaining > 0) begin
            window_frames = (frames_remaining > 600) ?
                            600 : frames_remaining;
            target_cycle = master_cycle +
                (64'(window_frames) * 64'(FRAME_CYCLES));
            ym_before = ym_write_count;
            samples_before = nonzero_sample_count;
            while (master_cycle < target_cycle)
                @(negedge clk);
            if (ym_write_count <= ym_before)
                $fatal(1,
                    "restore %0d has no YM writes in %0d-frame window",
                    this_restore, window_frames);
            if (nonzero_sample_count <= samples_before)
                $fatal(1,
                    "restore %0d has no nonzero samples in %0d-frame window",
                    this_restore, window_frames);
            frames_remaining = frames_remaining - window_frames;
            $display(
                "LANDMARK sound_longevity restore=%0d elapsed_frames=%0d ym_delta=%0d nonzero_delta=%0d pc=%05x",
                this_restore, longevity_frames - frames_remaining,
                ym_write_count - ym_before,
                nonzero_sample_count - samples_before,
                debug_pc);
        end
    end
endtask

initial begin
    if (!$value$plusargs("SHARED_HEX=%s", shared_path))
        $fatal(1, "missing +SHARED_HEX");
    if (!$value$plusargs("V25_HEX=%s", v25_path))
        $fatal(1, "missing +V25_HEX");
    if (!$value$plusargs("BASELINE_V25_HEX=%s", baseline_v25_path))
        $fatal(1, "missing +BASELINE_V25_HEX");
    if (!$value$plusargs("BASELINE_WORK_HEX=%s", baseline_work_path))
        $fatal(1, "missing +BASELINE_WORK_HEX");
    if (!$value$plusargs("POLICY_HEX=%s", policy_path))
        $fatal(1, "missing +POLICY_HEX");
    void'($value$plusargs(
        "LONGEVITY_FRAMES=%d", longevity_frames));
    void'($value$plusargs("RESTORE_COUNT=%d", restore_count));
    if (longevity_frames < 1 || restore_count < 2)
        $fatal(1, "invalid longevity matrix frames=%0d restores=%0d",
            longevity_frames, restore_count);

    $readmemh(shared_path, shared_fixture);
    $readmemh(v25_path, v25_state);
    $readmemh(baseline_v25_path, ready_v25_baseline);
    $readmemh(baseline_work_path, ready_work_baseline);
    $readmemh(policy_path, policy_state);
    if (policy_state[0][31:16] === 16'h0002) begin
        $display(
            "LANDMARK migrate_policy2_fixture_to_policy3 old=%016x",
            policy_state[0]);
        policy_state[0][31:16] = 16'h0003;
    end
    if (policy_state[0][31:16] !== 16'h0003 ||
        policy_state[0][2:0] !== 3'b111 ||
        policy_state[0][47:40] !== 8'h00 ||
        !policy_state[0][48])
        $fatal(1, "invalid policy-3 fixture %016x", policy_state[0]);
    reload_shared_fixture();
    shared_din = shared_ram[0];

    repeat (16) @(negedge clk);
    reset = 1'b0;
    for (fixture_index = 0; fixture_index < 39;
         fixture_index = fixture_index + 1)
        dut.v25_ready_baseline[fixture_index] =
            ready_v25_baseline[fixture_index];
    for (fixture_index = 0; fixture_index < 2560;
         fixture_index = fixture_index + 1)
        dut.v25_work_baseline[fixture_index] =
            ready_work_baseline[fixture_index];
    dut.baseline_valid = 1'b1;

    for (restore_index = 1; restore_index <= restore_count;
         restore_index = restore_index + 1) begin
        restore_saved_sound(restore_index);
        run_longevity_window(restore_index);
    end

    $display(
        "PASS sound_restore_longevity_tb restores=%0d frames_each=%0d total_frames=%0d ym=%0d samples=%0d nonzero=%0d sample_hash=%016x",
        restore_count, longevity_frames,
        restore_count * longevity_frames,
        ym_write_count, sample_count, nonzero_sample_count, sample_hash);
    $finish;
end

initial begin
    #100000000000;
    $fatal(1, "sound restore longevity timeout");
end

endmodule
