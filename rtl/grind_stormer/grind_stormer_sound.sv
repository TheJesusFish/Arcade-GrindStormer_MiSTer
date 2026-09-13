// SPDX-License-Identifier: BSD-3-Clause
//
// TP-027 V25 and IKAOPM sound subsystem. All logic is synchronous to the
// 94.5 MHz game clock and uses exact clock-enable pulses.

module grind_stormer_sound #(
    parameter integer V25_BUS_PHASES_USE_CEN = 1,
    parameter integer V25_BUS_BYTE_PHASES = 4,
    parameter integer V25_SOUND_WRITE_EXTRA_PHASES = 17,
    parameter integer V25_INSTRUCTION_GAP_PHASES = 8,
    parameter integer V25_REGISTER_INC_GAP_PHASES = 4,
    parameter integer V25_OPCODE_TIMING_PROFILE = 1,
    parameter [19:0] V25_TIMING_PROFILE_START = 20'ha0000,
    parameter [19:0] V25_TIMING_PROFILE_END = 20'ha8000,
    parameter integer V25_TEST1_IMMEDIATE_DELAY = 26,
    parameter integer V25_TEST1_MEMORY_DELAY = 4
) (
    input                       reset,
    input                       clk,
    input                       v25_enable,
    input      [7:0]            dip_a,
    input      [7:0]            dip_b,
    input      [7:0]            jmpr,
    input                       ym_enable,
    input                       state_hold,
    input                       pause,
    input                       main_shared_write,
    input      [14:0]           main_shared_addr,
    input      [7:0]            main_shared_data,

    input                       ss_restore_enable,
    input                       ss_restore_commit,
    input      [63:0]           ss_data,
    input      [31:0]           ss_addr,
    input      [7:0]            ss_select,
    input                       ss_write,
    input                       ss_read,
    input                       ss_query,
    output     [63:0]           ss_data_out,
    output                      ss_ack,

    output     [14:0]           shared_addr,
    output     [7:0]            shared_dout,
    output                      shared_we,
    input      [7:0]            shared_din,

    output signed [15:0]        snd_mono,
    output                      sample,

    output                      debug_fault,
    output                      debug_halted,
    output     [19:0]           debug_pc,
    output                      debug_state_idle,
    output                      state_idle,
    output                      state_held,
    output                      debug_v25_reset_n,
    output reg                  debug_ym_write,
    output reg                  debug_ym_a0,
    output reg [7:0]            debug_ym_data,
    output                      debug_v25_cen,
    output                      debug_ym_cen,
    output                      debug_ym_cen_p1,
    output     [7:0]            debug_ym_status
);

localparam [19:0] YM_ADDR = 20'h00000;
localparam [19:0] YM_DATA = 20'h00001;

// Grind Stormer's encrypted bootstrap is a live two-CPU protocol: MAME shows
// the 68000 streaming changing tables while the V25 expands its program. A
// late-game restore cannot repeat that exchange. Capture the first idle
// architecture after execution enters the expanded program, before its YM
// initialization, plus the private workspace. Restore resumes there against
// a cold IKAOPM and reaches the real mailbox-ready acknowledgement again.
localparam [14:0] BASELINE_WORK_FIRST = 15'h7400;
localparam [11:0] BASELINE_WORK_LAST = 12'h9ff;
localparam [5:0] BASELINE_V25_LAST = 6'd38;
localparam [3:0]
    BASE_IDLE                 = 4'd0,
    BASE_CAPTURE_WAIT_IDLE    = 4'd1,
    BASE_CAPTURE_V25_REQ      = 4'd2,
    BASE_CAPTURE_V25_RELEASE  = 4'd3,
    BASE_CAPTURE_WORK_PRIME   = 4'd4,
    BASE_CAPTURE_WORK         = 4'd5,
    BASE_RESTORE_WORK_PRIME   = 4'd6,
    BASE_RESTORE_WORK         = 4'd7,
    BASE_RESTORE_WAIT_READY   = 4'd8,
    BASE_RESTORE_V25_REQ      = 4'd9,
    BASE_RESTORE_V25_RELEASE  = 4'd10,
    BASE_RESTORE_V25_COMMIT   = 4'd11,
    BASE_RESTORE_V25_SETTLE   = 4'd12,
    BASE_RESTORE_DONE         = 4'd13,
    BASE_RESTORE_V25_PRIME    = 4'd14;

reg [3:0] baseline_state = BASE_IDLE;
reg [5:0] baseline_v25_index = 6'd0;
reg [11:0] baseline_work_index = 12'd0;
reg [3:0] baseline_settle_count = 4'd0;
reg baseline_valid = 1'b0;
(* ramstyle = "M10K" *) reg [63:0] v25_ready_baseline [0:38];
(* ramstyle = "M10K" *) reg [7:0] v25_work_baseline [0:2559];
reg [63:0] v25_ready_baseline_q = 64'd0;
reg [7:0] v25_work_baseline_q = 8'd0;

wire baseline_restore_memory_active =
    (baseline_state == BASE_RESTORE_WORK_PRIME) ||
    (baseline_state == BASE_RESTORE_WORK);
wire baseline_restore_write =
    baseline_state == BASE_RESTORE_WORK;
wire baseline_capture_memory_active =
    (baseline_state == BASE_CAPTURE_WORK_PRIME) ||
    (baseline_state == BASE_CAPTURE_WORK);
wire baseline_controller_active = baseline_state != BASE_IDLE;
wire [11:0] baseline_work_read_addr =
    baseline_state == BASE_RESTORE_WORK ?
        (baseline_work_index == BASELINE_WORK_LAST ?
            BASELINE_WORK_LAST :
            baseline_work_index + 12'd1) :
    12'd0;

always @(posedge clk) begin
    v25_ready_baseline_q <=
        v25_ready_baseline[baseline_v25_index];
    v25_work_baseline_q <=
        v25_work_baseline[baseline_work_read_addr];
    if (baseline_state == BASE_CAPTURE_WORK)
        v25_work_baseline[baseline_work_index] <= shared_din;
end

wire restore_restart =
    baseline_restore_memory_active ||
    (ss_restore_commit && ss_restore_enable);
wire sound_domain_reset = reset || restore_restart;
// GRSS0001 intentionally runs IKAOPM while state_hold is asserted so the
// rebooted V25 can consume and acknowledge its replayed BGM command.
wire playback_hold = pause;

// Exact 94.5 MHz * 20 / 189 = 10 MHz V25 enable.
reg [7:0] v25_cen_accum = 8'd0;
reg       v25_cen = 1'b0;
`ifdef GRINDSTORMER_SOUND_ACCELERATED_SIM
// Long-run tests restore after the bootstrap and can step one 10 MHz V25
// phase per host edge. YM below retains the exact 80:27 phase ratio.
always @(posedge clk) begin
    if (sound_domain_reset) begin
        v25_cen <= 1'b0;
        v25_cen_accum <= 8'd0;
    end else if (pause) begin
        v25_cen <= 1'b0;
    end else begin
        v25_cen <= 1'b1;
    end
end
`else
always @(posedge clk) begin
    v25_cen <= 1'b0;
    if (sound_domain_reset) begin
        v25_cen_accum <= 8'd0;
    end else if (!pause) begin
        if (v25_cen_accum >= 8'd169) begin
            v25_cen_accum <= v25_cen_accum + 8'd20 - 8'd189;
            v25_cen <= 1'b1;
        end else begin
            v25_cen_accum <= v25_cen_accum + 8'd20;
        end
    end
end
`endif

// One phiM enable every 28 master clocks. cen_p1 marks every second phiM
// edge and is used to hold host writes for a complete IKAOPM slot.
reg [5:0] ym_divider = 6'd0;
reg       ym_cen = 1'b0;
reg       ym_cen_p1 = 1'b0;
wire      ym_ready;
`ifdef GRINDSTORMER_SOUND_ACCELERATED_SIM
reg [6:0] ym_accum = 7'd0;
reg       ym_half_toggle = 1'b0;
always @(posedge clk) begin
    ym_cen <= 1'b0;
    ym_cen_p1 <= 1'b0;
    if (sound_domain_reset) begin
        ym_divider <= 6'd0;
        ym_accum <= 7'd0;
        ym_half_toggle <= 1'b0;
    end else if (!playback_hold || !ym_ready) begin
        if (ym_accum >= 7'd53) begin
            ym_accum <= ym_accum - 7'd53;
            ym_cen <= 1'b1;
            ym_cen_p1 <= ym_half_toggle;
            ym_half_toggle <= !ym_half_toggle;
        end else begin
            ym_accum <= ym_accum + 7'd27;
        end
    end
end
`else
always @(posedge clk) begin
    ym_cen <= 1'b0;
    ym_cen_p1 <= 1'b0;
    if (sound_domain_reset) begin
        ym_divider <= 6'd0;
    end else if (!playback_hold || !ym_ready) begin
        if (ym_divider == 6'd55) begin
            ym_divider <= 6'd0;
            ym_cen <= 1'b1;
            ym_cen_p1 <= 1'b1;
        end else begin
            ym_divider <= ym_divider + 6'd1;
            if (ym_divider == 6'd27)
                ym_cen <= 1'b1;
        end
    end
end
`endif

// Hold reset through a complete OPM slot rotation after the restart pulse.
reg [5:0] ym_reset_count = 6'd0;
always @(posedge clk or posedge sound_domain_reset) begin
    if (sound_domain_reset)
        ym_reset_count <= 6'd0;
    else if (!ym_reset_count[5] && ym_cen_p1)
        ym_reset_count <= ym_reset_count + 6'd1;
end
wire ym_reset = sound_domain_reset || !ym_reset_count[5];
assign ym_ready = !ym_reset;

// Both initial boot and restore release the V25 only after IKAOPM has
// completed a full reset rotation.
wire v25_reset_async = sound_domain_reset ||
                       !v25_enable ||
                       !ym_ready;
reg [1:0] v25_reset_pipe = 2'b11;
always @(posedge clk or posedge v25_reset_async) begin
    if (v25_reset_async)
        v25_reset_pipe <= 2'b11;
    else
        v25_reset_pipe <= {v25_reset_pipe[0], 1'b0};
end
wire v25_reset_n = !v25_reset_pipe[1];

wire [19:0] v25_bus_addr;
wire [7:0]  v25_bus_dout;
reg  [7:0]  v25_bus_din;
wire        v25_bus_doe;
wire        v25_bus_r_w;
wire        v25_bus_mreq_n;
wire        v25_bus_mstb_n;
wire        v25_bus_iostb_n;
wire        v25_state_idle;
wire [63:0] v25_ss_data_out;
wire        v25_ss_ack;

localparam [2:0]
    BGM_REPLAY_IDLE          = 3'd0,
    BGM_REPLAY_WAIT_READY    = 3'd1,
    BGM_REPLAY_WRITE_ARG     = 3'd2,
    BGM_REPLAY_WRITE_COMMAND = 3'd3,
    BGM_REPLAY_WAIT_ACK      = 3'd4,
    BGM_REPLAY_RELEASE       = 3'd5;

reg [2:0] bgm_replay_state = BGM_REPLAY_IDLE;
reg [7:0] bgm_replay_command = 8'd0;
reg [7:0] bgm_replay_argument = 8'd0;
reg       bgm_replay_valid = 1'b0;
reg       mailbox_ready = 1'b0;
wire bgm_replay_write_argument =
    (bgm_replay_state == BGM_REPLAY_WRITE_ARG) && !pause;
wire bgm_replay_write_command =
    (bgm_replay_state == BGM_REPLAY_WRITE_COMMAND) && !pause;
wire bgm_replay_hold_v25 =
    (bgm_replay_state == BGM_REPLAY_WRITE_ARG) ||
    (bgm_replay_state == BGM_REPLAY_WRITE_COMMAND) ||
    (bgm_replay_state == BGM_REPLAY_RELEASE);
wire bgm_replay_run_for_ack =
    bgm_replay_state == BGM_REPLAY_WAIT_ACK;
wire bgm_replay_run_for_ready =
    bgm_replay_state == BGM_REPLAY_WAIT_READY;

wire [7:0] restored_bgm_command;
wire [7:0] restored_bgm_argument;
wire       restored_bgm_valid;

wire baseline_capture_hold_v25 =
    ((baseline_state == BASE_CAPTURE_WAIT_IDLE) && v25_state_idle) ||
    (baseline_state == BASE_CAPTURE_V25_REQ) ||
    (baseline_state == BASE_CAPTURE_V25_RELEASE) ||
    baseline_capture_memory_active;
wire baseline_restore_hold_v25 =
    baseline_state >= BASE_RESTORE_WORK_PRIME;
wire v25_hold_boundary =
    (state_hold && v25_state_idle &&
     !bgm_replay_run_for_ready && !bgm_replay_run_for_ack) ||
    bgm_replay_hold_v25 ||
    baseline_capture_hold_v25 ||
    baseline_restore_hold_v25;

wire baseline_v25_ss_active =
    (baseline_state == BASE_CAPTURE_V25_REQ) ||
    (baseline_state == BASE_CAPTURE_V25_RELEASE) ||
    (baseline_state == BASE_RESTORE_V25_REQ) ||
    (baseline_state == BASE_RESTORE_V25_RELEASE);
wire baseline_v25_ss_read =
    baseline_state == BASE_CAPTURE_V25_REQ;
wire baseline_v25_ss_write =
    baseline_state == BASE_RESTORE_V25_REQ;
wire baseline_v25_ss_commit =
    baseline_state == BASE_RESTORE_V25_COMMIT;
wire baseline_v25_restore_enable =
    (baseline_state == BASE_RESTORE_V25_REQ) ||
    (baseline_state == BASE_RESTORE_V25_RELEASE) ||
    baseline_v25_ss_commit;
wire [63:0] v25_ss_data_in =
    baseline_v25_ss_active ?
        v25_ready_baseline_q :
        ss_data;
wire [31:0] v25_ss_addr_in =
    baseline_v25_ss_active ?
        {26'd0, baseline_v25_index} :
        ss_addr;
wire [7:0] v25_ss_select_in =
    baseline_v25_ss_active ? 8'd9 : ss_select;
wire v25_ss_write_in =
    baseline_v25_ss_active ? baseline_v25_ss_write : ss_write;
wire v25_ss_read_in =
    baseline_v25_ss_active ? baseline_v25_ss_read : ss_read;
wire v25_ss_query_in =
    baseline_v25_ss_active ? 1'b0 : ss_query;

grind_stormer_v25_cpu #(
    .SS_IDX                  (8'd9),
    .BUS_PHASES_USE_CEN      (V25_BUS_PHASES_USE_CEN),
    .BUS_BYTE_PHASES         (V25_BUS_BYTE_PHASES),
    .SOUND_WRITE_EXTRA_PHASES(V25_SOUND_WRITE_EXTRA_PHASES),
    .INSTRUCTION_GAP_PHASES  (V25_INSTRUCTION_GAP_PHASES),
    .REGISTER_INC_GAP_PHASES (V25_REGISTER_INC_GAP_PHASES),
    .OPCODE_TIMING_PROFILE   (V25_OPCODE_TIMING_PROFILE),
    .TIMING_PROFILE_START    (V25_TIMING_PROFILE_START),
    .TIMING_PROFILE_END      (V25_TIMING_PROFILE_END),
    .TEST1_IMMEDIATE_DELAY   (V25_TEST1_IMMEDIATE_DELAY),
    .TEST1_MEMORY_DELAY      (V25_TEST1_MEMORY_DELAY)
) u_v25 (
    .clk               (clk),
    .reset             (reset),
    .reset_n           (v25_reset_n),
    .clock_enable      (v25_cen && !pause && !v25_hold_boundary),
    // TP-027 active-low V25 ports: P0=DSWB, P1=JMPR, PT=DSWA.
    .port0_in          (~dip_b),
    .port1_in          (~jmpr),
    .portt_in          (~dip_a),
    .bus_addr          (v25_bus_addr),
    .bus_dout          (v25_bus_dout),
    .bus_din           (v25_bus_din),
    .bus_doe           (v25_bus_doe),
    .bus_r_w           (v25_bus_r_w),
    .bus_mreq_n        (v25_bus_mreq_n),
    .bus_mstb_n        (v25_bus_mstb_n),
    .bus_iostb_n       (v25_bus_iostb_n),
    .halted            (debug_halted),
    .fault             (debug_fault),
    .debug_pc          (debug_pc),
    .state_idle        (v25_state_idle),
    // External chunk-9 writes preserve stream geometry but are discarded.
    // The internal controller applies the ROM-boot-specific ready baseline.
    .ss_restore_enable (baseline_v25_restore_enable),
    .ss_restore_commit (baseline_v25_ss_commit),
    .ss_data           (v25_ss_data_in),
    .ss_addr           (v25_ss_addr_in),
    .ss_select         (v25_ss_select_in),
    .ss_write          (v25_ss_write_in),
    .ss_read           (v25_ss_read_in),
    .ss_query          (v25_ss_query_in),
    .ss_data_out       (v25_ss_data_out),
    .ss_ack            (v25_ss_ack)
);

wire v25_mem_active = !v25_bus_mreq_n && !v25_bus_mstb_n;
wire v25_write_active = v25_mem_active && !v25_bus_r_w && v25_bus_doe;
reg  v25_write_active_d = 1'b0;
wire v25_write_start = v25_write_active && !v25_write_active_d;
wire v25_shared_cs = v25_bus_addr[19];
wire v25_mailbox_ready_write =
    v25_write_start &&
    v25_shared_cs &&
    (v25_bus_addr[14:0] == 15'h7800) &&
    (v25_bus_dout == 8'hff);
wire baseline_capture_point =
    v25_state_idle &&
    (debug_pc >= 20'ha0000) &&
    (debug_pc < 20'ha7400);
wire [14:0] baseline_capture_shared_addr =
    baseline_state == BASE_CAPTURE_WORK_PRIME ?
        BASELINE_WORK_FIRST :
    baseline_state == BASE_CAPTURE_WORK ?
        BASELINE_WORK_FIRST +
        (baseline_work_index == BASELINE_WORK_LAST ?
            BASELINE_WORK_LAST :
            baseline_work_index + 12'd1) :
    BASELINE_WORK_FIRST;

always @(posedge clk) begin
    if (reset) begin
        baseline_state <= BASE_IDLE;
        baseline_v25_index <= 6'd0;
        baseline_work_index <= 12'd0;
        baseline_settle_count <= 4'd0;
        baseline_valid <= 1'b0;
    end else if (ss_restore_commit && ss_restore_enable) begin
        baseline_state <= baseline_valid ?
                          BASE_RESTORE_WORK_PRIME :
                          BASE_IDLE;
        baseline_v25_index <= 6'd0;
        baseline_work_index <= 12'd0;
        baseline_settle_count <= 4'd0;
    end else begin
        case (baseline_state)
            BASE_IDLE: begin
                if (baseline_capture_point && !baseline_valid)
                    baseline_state <= BASE_CAPTURE_WAIT_IDLE;
            end

            BASE_CAPTURE_WAIT_IDLE: begin
                if (v25_state_idle) begin
                    baseline_v25_index <= 6'd0;
                    baseline_state <= BASE_CAPTURE_V25_REQ;
                end
            end

            BASE_CAPTURE_V25_REQ: begin
                if (v25_ss_ack) begin
                    v25_ready_baseline[baseline_v25_index] <=
                        v25_ss_data_out;
                    baseline_state <= BASE_CAPTURE_V25_RELEASE;
                end
            end

            BASE_CAPTURE_V25_RELEASE: begin
                if (!v25_ss_ack) begin
                    if (baseline_v25_index == BASELINE_V25_LAST) begin
                        baseline_work_index <= 12'd0;
                        baseline_state <= BASE_CAPTURE_WORK_PRIME;
                    end else begin
                        baseline_v25_index <=
                            baseline_v25_index + 6'd1;
                        baseline_state <= BASE_CAPTURE_V25_REQ;
                    end
                end
            end

            BASE_CAPTURE_WORK_PRIME: begin
                baseline_work_index <= 12'd0;
                baseline_state <= BASE_CAPTURE_WORK;
            end

            BASE_CAPTURE_WORK: begin
                if (baseline_work_index == BASELINE_WORK_LAST) begin
                    baseline_valid <= 1'b1;
                    baseline_work_index <= 12'd0;
                    baseline_state <= BASE_IDLE;
                end else begin
                    baseline_work_index <=
                        baseline_work_index + 12'd1;
                end
            end

            BASE_RESTORE_WORK_PRIME: begin
                baseline_work_index <= 12'd0;
                baseline_state <= BASE_RESTORE_WORK;
            end

            BASE_RESTORE_WORK: begin
                if (baseline_work_index == BASELINE_WORK_LAST) begin
                    baseline_work_index <= 12'd0;
                    baseline_state <= BASE_RESTORE_WAIT_READY;
                end else begin
                    baseline_work_index <=
                        baseline_work_index + 12'd1;
                end
            end

            BASE_RESTORE_WAIT_READY: begin
                if (ym_ready && v25_reset_n && v25_state_idle) begin
                    baseline_v25_index <= 6'd0;
                    baseline_state <= BASE_RESTORE_V25_PRIME;
                end
            end

            BASE_RESTORE_V25_PRIME:
                baseline_state <= BASE_RESTORE_V25_REQ;

            BASE_RESTORE_V25_REQ: begin
                if (v25_ss_ack)
                    baseline_state <= BASE_RESTORE_V25_RELEASE;
            end

            BASE_RESTORE_V25_RELEASE: begin
                if (!v25_ss_ack) begin
                    if (baseline_v25_index == BASELINE_V25_LAST) begin
                        baseline_state <= BASE_RESTORE_V25_COMMIT;
                    end else begin
                        baseline_v25_index <=
                            baseline_v25_index + 6'd1;
                        baseline_state <= BASE_RESTORE_V25_PRIME;
                    end
                end
            end

            BASE_RESTORE_V25_COMMIT: begin
                baseline_settle_count <= 4'd0;
                baseline_state <= BASE_RESTORE_V25_SETTLE;
            end

            BASE_RESTORE_V25_SETTLE: begin
                if (baseline_settle_count == 4'd8) begin
                    baseline_state <= BASE_RESTORE_DONE;
                end else begin
                    baseline_settle_count <=
                        baseline_settle_count + 4'd1;
                end
            end

            BASE_RESTORE_DONE:
                baseline_state <= BASE_IDLE;

            default:
                baseline_state <= BASE_IDLE;
        endcase
    end
end

wire ym_read_active = v25_mem_active && v25_bus_r_w &&
                      !v25_shared_cs &&
                      ((v25_bus_addr == YM_ADDR) ||
                       (v25_bus_addr == YM_DATA));

// Main traffic proves 7801=argument, 7800=command, and V25 7800=ff is the
// acknowledgement. Argument 00 is the durable BGM class; argument 06 is SFX.
reg [7:0] bgm_pending_argument = 8'd0;
reg [7:0] bgm_candidate_command = 8'd0;
reg [7:0] bgm_candidate_argument = 8'd0;
reg       bgm_candidate_pending = 1'b0;
reg [7:0] bgm_command = 8'd0;
reg [7:0] bgm_argument = 8'd0;
reg       bgm_valid = 1'b0;

always @(posedge clk) begin
    if (reset) begin
        bgm_pending_argument <= 8'd0;
        bgm_candidate_command <= 8'd0;
        bgm_candidate_argument <= 8'd0;
        bgm_candidate_pending <= 1'b0;
        bgm_command <= 8'd0;
        bgm_argument <= 8'd0;
        bgm_valid <= 1'b0;
        mailbox_ready <= 1'b0;
    end else if (ss_restore_commit && ss_restore_enable) begin
        bgm_pending_argument <= restored_bgm_argument;
        bgm_candidate_command <= 8'd0;
        bgm_candidate_argument <= 8'd0;
        bgm_candidate_pending <= 1'b0;
        bgm_command <= restored_bgm_command;
        bgm_argument <= restored_bgm_argument;
        bgm_valid <= restored_bgm_valid;
        mailbox_ready <= 1'b0;
    end else begin
        if (main_shared_write &&
            (main_shared_addr == 15'h7801))
            bgm_pending_argument <= main_shared_data;

        if (main_shared_write &&
            (main_shared_addr == 15'h7800) &&
            (main_shared_data != 8'hff)) begin
            bgm_candidate_command <= main_shared_data;
            bgm_candidate_argument <= bgm_pending_argument;
            bgm_candidate_pending <= 1'b1;
            mailbox_ready <= 1'b0;
        end

        if (bgm_replay_write_command)
            mailbox_ready <= 1'b0;

        if (v25_mailbox_ready_write) begin
            mailbox_ready <= 1'b1;
            if (bgm_candidate_pending) begin
                bgm_candidate_pending <= 1'b0;
                if ((bgm_candidate_command == 8'h00) &&
                    (bgm_candidate_argument == 8'h01)) begin
                    bgm_valid <= 1'b0;
                end else if (bgm_candidate_argument == 8'h00) begin
                    bgm_command <= bgm_candidate_command;
                    bgm_argument <= bgm_candidate_argument;
                    bgm_valid <= 1'b1;
                end
            end
        end
    end
end

// Keep the 68000 held while the restored V25 consumes and acknowledges one
// saved BGM transaction against the freshly reset IKAOPM.
always @(posedge clk) begin
    if (reset) begin
        bgm_replay_state <= BGM_REPLAY_IDLE;
        bgm_replay_command <= 8'd0;
        bgm_replay_argument <= 8'd0;
        bgm_replay_valid <= 1'b0;
    end else if (ss_restore_commit && ss_restore_enable) begin
        bgm_replay_state <= BGM_REPLAY_WAIT_READY;
        bgm_replay_command <= restored_bgm_command;
        bgm_replay_argument <= restored_bgm_argument;
        bgm_replay_valid <= restored_bgm_valid;
    end else if (!pause) begin
        case (bgm_replay_state)
            BGM_REPLAY_WAIT_READY: begin
                if (state_hold && ym_ready && !restore_restart &&
                    v25_state_idle && mailbox_ready)
                    bgm_replay_state <= bgm_replay_valid ?
                                        BGM_REPLAY_WRITE_ARG :
                                        BGM_REPLAY_RELEASE;
            end
            BGM_REPLAY_WRITE_ARG:
                bgm_replay_state <= BGM_REPLAY_WRITE_COMMAND;
            BGM_REPLAY_WRITE_COMMAND:
                bgm_replay_state <= BGM_REPLAY_WAIT_ACK;
            BGM_REPLAY_WAIT_ACK: begin
                if (v25_mailbox_ready_write)
                    bgm_replay_state <= BGM_REPLAY_RELEASE;
            end
            BGM_REPLAY_RELEASE: begin
                bgm_replay_state <= BGM_REPLAY_IDLE;
                bgm_replay_valid <= 1'b0;
            end
            default:
                bgm_replay_state <= BGM_REPLAY_IDLE;
        endcase
    end
end

assign shared_addr =
    baseline_restore_write ?
        BASELINE_WORK_FIRST + baseline_work_index :
    baseline_capture_memory_active ?
        baseline_capture_shared_addr :
    bgm_replay_write_argument ? 15'h7801 :
    bgm_replay_write_command ? 15'h7800 :
    v25_bus_addr[14:0];
assign shared_dout =
    baseline_restore_write ? v25_work_baseline_q :
    bgm_replay_write_argument ? bgm_replay_argument :
    bgm_replay_write_command ? bgm_replay_command :
    v25_bus_dout;
assign shared_we =
    baseline_restore_write ||
    bgm_replay_write_argument ||
    bgm_replay_write_command ||
    (v25_write_start && v25_shared_cs);

wire [7:0] ym_dout;
always @(*) begin
    v25_bus_din = 8'h00;
    if (v25_mem_active && v25_bus_r_w) begin
        if (v25_shared_cs)
            v25_bus_din = shared_din;
        else if ((v25_bus_addr == YM_ADDR) ||
                 (v25_bus_addr == YM_DATA))
            v25_bus_din = ym_dout;
    end
end

reg       ym_write_cs_n = 1'b1;
reg       ym_write_wr_n = 1'b1;
reg       ym_host_a0 = 1'b0;
reg [7:0] ym_host_data = 8'h00;
reg       ym_write_pending = 1'b0;

always @(posedge clk) begin
    if (!v25_reset_n || restore_restart) begin
        v25_write_active_d <= 1'b0;
        ym_write_cs_n <= 1'b1;
        ym_write_wr_n <= 1'b1;
        ym_host_a0 <= 1'b0;
        ym_host_data <= 8'h00;
        ym_write_pending <= 1'b0;
        debug_ym_write <= 1'b0;
        debug_ym_a0 <= 1'b0;
        debug_ym_data <= 8'h00;
    end else begin
        v25_write_active_d <= v25_write_active;
        debug_ym_write <= 1'b0;

        if (ym_write_pending) begin
            ym_write_cs_n <= 1'b0;
            ym_write_wr_n <= 1'b0;
            if (ym_cen_p1) begin
                ym_write_cs_n <= 1'b1;
                ym_write_wr_n <= 1'b1;
                ym_write_pending <= 1'b0;
            end
        end else begin
            ym_write_cs_n <= 1'b1;
            ym_write_wr_n <= 1'b1;
        end

        if (v25_write_start && !v25_shared_cs &&
            ((v25_bus_addr == YM_ADDR) ||
             (v25_bus_addr == YM_DATA))) begin
            ym_write_cs_n <= 1'b0;
            ym_write_wr_n <= 1'b0;
            ym_host_a0 <= v25_bus_addr[0];
            ym_host_data <= v25_bus_dout;
            ym_write_pending <= 1'b1;
            debug_ym_write <= 1'b1;
            debug_ym_a0 <= v25_bus_addr[0];
            debug_ym_data <= v25_bus_dout;
        end
    end
end

wire ym_cs_n = ym_read_active ? 1'b0 : ym_write_cs_n;
wire ym_wr_n = ym_read_active ? 1'b1 : ym_write_wr_n;
wire ym_sample;
wire signed [15:0] ym_left;
wire signed [15:0] ym_right;

grind_stormer_opm u_ym2151 (
    .rst    (ym_reset),
    .clk    (clk),
    .cen    (ym_cen),
    .cs_n   (ym_cs_n),
    .wr_n   (ym_wr_n),
    .a0     (ym_read_active ? v25_bus_addr[0] : ym_host_a0),
    .din    (ym_host_data),
    .dout   (ym_dout),
    .sample (ym_sample),
    .left   (ym_left),
    .right  (ym_right)
);

wire signed [15:0] mixed_mono;

grind_stormer_sound_mixer u_mixer (
    .clk       (clk),
    .reset     (ym_reset),
    .sample    (ym_sample),
    .ym_left   (ym_left),
    .ym_right  (ym_right),
    .ym_enable (ym_enable),
    .mono      (mixed_mono)
);

assign snd_mono = pause ? 16'sd0 : mixed_mono;

wire [63:0] policy_ss_data_out;
wire policy_ss_ack;
grind_stormer_sound_policy #(.SS_IDX(8'd10)) u_sound_policy (
    .clk               (clk),
    .reset             (reset),
    .ss_restore_enable (ss_restore_enable),
    .bgm_command       (bgm_command),
    .bgm_argument      (bgm_argument),
    .bgm_valid         (bgm_valid),
    .ss_data           (ss_data),
    .ss_addr           (ss_addr),
    .ss_select         (ss_select),
    .ss_write          (ss_write),
    .ss_read           (ss_read),
    .ss_query          (ss_query),
    .ss_data_out       (policy_ss_data_out),
    .ss_ack            (policy_ss_ack),
    .restored_bgm_command(restored_bgm_command),
    .restored_bgm_argument(restored_bgm_argument),
    .restored_bgm_valid(restored_bgm_valid)
);

wire v25_external_ss_ack = v25_ss_ack && !baseline_v25_ss_active;
assign ss_data_out = policy_ss_ack ? policy_ss_data_out :
                     v25_external_ss_ack ? v25_ss_data_out :
                     64'd0;
assign ss_ack = policy_ss_ack || v25_external_ss_ack;
assign sample = ym_sample;
assign debug_state_idle = v25_state_idle;
wire replay_quiescent = bgm_replay_state == BGM_REPLAY_IDLE;
assign state_idle = !restore_restart &&
                    baseline_valid &&
                    !baseline_controller_active &&
                    ym_ready &&
                    mailbox_ready &&
                    replay_quiescent &&
                    v25_state_idle &&
                    !v25_write_active &&
                    !ym_write_pending &&
                    ym_write_cs_n && ym_write_wr_n;
assign state_held = state_hold && state_idle;
assign debug_v25_reset_n = v25_reset_n;
assign debug_v25_cen = v25_cen;
assign debug_ym_cen = ym_cen;
assign debug_ym_cen_p1 = ym_cen_p1;
assign debug_ym_status = ym_dout;

endmodule

module grind_stormer_sound_policy #(
    parameter [7:0] SS_IDX = 8'd10
) (
    input             clk,
    input             reset,
    input             ss_restore_enable,
    input      [7:0]  bgm_command,
    input      [7:0]  bgm_argument,
    input             bgm_valid,
    input      [63:0] ss_data,
    input      [31:0] ss_addr,
    input      [7:0]  ss_select,
    input             ss_write,
    input             ss_read,
    input             ss_query,
    output reg [63:0] ss_data_out,
    output reg        ss_ack,
    output     [7:0]  restored_bgm_command,
    output     [7:0]  restored_bgm_argument,
    output            restored_bgm_valid
);

localparam [31:0] SS_WORD_COUNT = 32'd1;
wire [63:0] policy_word = {
    15'd0,
    bgm_valid,
    bgm_argument,
    bgm_command,
    16'h0003, // policy schema
    13'd0,
    1'b1,     // acknowledged TP-027 BGM replay
    1'b1,     // IKAOPM cold restart
    1'b1      // post-bootstrap V25 baseline restart
};

reg [63:0] restored_policy = 64'd0;
wire selected = ss_select == SS_IDX;
wire restored_policy_valid =
    (restored_policy[31:16] == 16'h0003) &&
    (restored_policy[2:0] == 3'b111);
assign restored_bgm_command =
    restored_policy_valid ? restored_policy[39:32] : 8'd0;
assign restored_bgm_argument =
    restored_policy_valid ? restored_policy[47:40] : 8'd0;
assign restored_bgm_valid =
    restored_policy_valid && restored_policy[48];

always @(posedge clk) begin
    ss_ack <= 1'b0;
    if (reset) begin
        ss_data_out <= 64'd0;
        restored_policy <= 64'd0;
    end else if (selected) begin
        if (ss_query) begin
            ss_data_out <= {SS_IDX, 22'd0, 2'd3, SS_WORD_COUNT};
            ss_ack <= 1'b1;
        end else if (ss_read) begin
            ss_data_out <= (ss_addr == 32'd0) ? policy_word : 64'd0;
            ss_ack <= 1'b1;
        end else if (ss_write) begin
            if (ss_restore_enable && ss_addr == 32'd0)
                restored_policy <= ss_data;
            ss_ack <= 1'b1;
        end
    end
end

endmodule
