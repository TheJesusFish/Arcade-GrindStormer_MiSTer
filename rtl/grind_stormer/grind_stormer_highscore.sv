// SPDX-License-Identifier: GPL-3.0-or-later

// Grind Stormer-local high-score persistence. The MRA supplies one exact
// MAME hiscore descriptor at index 4 and a 264-byte NVRAM image at index 2.
module grind_stormer_highscore (
    input              clk,
    input              reset,
    input              cpu_reset,

    input      [1:0]   rom_set_id,
    input              rom_identity_valid,

    input              config_download,
    input              config_wr,
    input      [26:0]  config_addr,
    input      [7:0]   config_data,

    input              nvram_download,
    input              nvram_upload,
    input              nvram_wr,
    input              nvram_rd,
    input      [26:0]  nvram_addr,
    input      [7:0]   nvram_data,
    output     [7:0]   nvram_q,
    output             nvram_wait,

    input              ss_active,
    input      [12:0]  normal_ram_addr,
    input      [1:0]   normal_ram_we,
    input      [15:0]  normal_ram_data,

    output             hold_request,
    input              hold_ack,
    output             ram_owned,
    output     [12:0]  ram_addr,
    output     [1:0]   ram_we,
    output     [15:0]  ram_data,
    input      [15:0]  ram_q,

    output             dirty,
    output             active,
    output             config_valid,
    output     [1:0]   active_profile
);

localparam [8:0] NVRAM_SIZE = 9'd264;
localparam [8:0] SCORE_WINDOW_SIZE = 9'd256;
localparam [7:0] SCORE_DATA_SIZE = 8'd149;
localparam [4:0] CONFIG_SIZE = 5'd24;

localparam [3:0] ST_IDLE                 = 4'd0;
localparam [3:0] ST_RESTORE_HOLD         = 4'd1;
localparam [3:0] ST_RESTORE_BUFFER_READ  = 4'd2;
localparam [3:0] ST_RESTORE_RAM_WRITE    = 4'd3;
localparam [3:0] ST_CAPTURE_HOLD         = 4'd4;
localparam [3:0] ST_CAPTURE_RAM_READ     = 4'd5;
localparam [3:0] ST_CAPTURE_BUFFER_WRITE = 4'd6;

function automatic [7:0] expected_config_byte;
    input [1:0] profile;
    input [4:0] address;
    begin
        case (profile)
            2'd1: begin // grindstm
                case (address)
                    5'd0:  expected_config_byte = 8'h00;
                    5'd1:  expected_config_byte = 8'h10;
                    5'd2:  expected_config_byte = 8'h05;
                    5'd3:  expected_config_byte = 8'h00;
                    5'd4:  expected_config_byte = 8'h00;
                    5'd5:  expected_config_byte = 8'h90;
                    5'd6:  expected_config_byte = 8'h00;
                    5'd7:  expected_config_byte = 8'h00;
                    5'd8:  expected_config_byte = 8'h00;
                    5'd9:  expected_config_byte = 8'h10;
                    5'd10: expected_config_byte = 8'h05;
                    5'd11: expected_config_byte = 8'h7f;
                    5'd12: expected_config_byte = 8'h00;
                    5'd13: expected_config_byte = 8'h01;
                    5'd14: expected_config_byte = 8'h2d;
                    5'd15: expected_config_byte = 8'h2d;
                    5'd16: expected_config_byte = 8'h00;
                    5'd17: expected_config_byte = 8'h10;
                    5'd18: expected_config_byte = 8'h04;
                    5'd19: expected_config_byte = 8'h3c;
                    5'd20: expected_config_byte = 8'h00;
                    5'd21: expected_config_byte = 8'h04;
                    5'd22: expected_config_byte = 8'h00;
                    default: expected_config_byte = 8'h00;
                endcase
            end
            2'd2: begin // grindstma
                case (address)
                    5'd0:  expected_config_byte = 8'h00;
                    5'd1:  expected_config_byte = 8'h10;
                    5'd2:  expected_config_byte = 8'h04;
                    5'd3:  expected_config_byte = 8'hfc;
                    5'd4:  expected_config_byte = 8'h00;
                    5'd5:  expected_config_byte = 8'h90;
                    5'd6:  expected_config_byte = 8'h00;
                    5'd7:  expected_config_byte = 8'h00;
                    5'd8:  expected_config_byte = 8'h00;
                    5'd9:  expected_config_byte = 8'h10;
                    5'd10: expected_config_byte = 8'h05;
                    5'd11: expected_config_byte = 8'h7b;
                    5'd12: expected_config_byte = 8'h00;
                    5'd13: expected_config_byte = 8'h01;
                    5'd14: expected_config_byte = 8'h2d;
                    5'd15: expected_config_byte = 8'h2d;
                    5'd16: expected_config_byte = 8'h00;
                    5'd17: expected_config_byte = 8'h10;
                    5'd18: expected_config_byte = 8'h04;
                    5'd19: expected_config_byte = 8'h38;
                    5'd20: expected_config_byte = 8'h00;
                    5'd21: expected_config_byte = 8'h04;
                    5'd22: expected_config_byte = 8'h00;
                    default: expected_config_byte = 8'h00;
                endcase
            end
            default: begin // vfive, profile 3
                case (address)
                    5'd0:  expected_config_byte = 8'h00;
                    5'd1:  expected_config_byte = 8'h10;
                    5'd2:  expected_config_byte = 8'h04;
                    5'd3:  expected_config_byte = 8'hfa;
                    5'd4:  expected_config_byte = 8'h00;
                    5'd5:  expected_config_byte = 8'h90;
                    5'd6:  expected_config_byte = 8'h00;
                    5'd7:  expected_config_byte = 8'h00;
                    5'd8:  expected_config_byte = 8'h00;
                    5'd9:  expected_config_byte = 8'h10;
                    5'd10: expected_config_byte = 8'h04;
                    5'd11: expected_config_byte = 8'h36;
                    5'd12: expected_config_byte = 8'h00;
                    5'd13: expected_config_byte = 8'h04;
                    5'd14: expected_config_byte = 8'h00;
                    5'd15: expected_config_byte = 8'h00;
                    5'd16: expected_config_byte = 8'h00;
                    5'd17: expected_config_byte = 8'h10;
                    5'd18: expected_config_byte = 8'h05;
                    5'd19: expected_config_byte = 8'h79;
                    5'd20: expected_config_byte = 8'h00;
                    5'd21: expected_config_byte = 8'h01;
                    5'd22: expected_config_byte = 8'h2d;
                    default: expected_config_byte = 8'h2d;
                endcase
            end
        endcase
    end
endfunction

function automatic [7:0] expected_trailer_byte;
    input [1:0] profile;
    input [2:0] address;
    begin
        case (address)
            3'd0: expected_trailer_byte = 8'h47; // G
            3'd1: expected_trailer_byte = 8'h53; // S
            3'd2: expected_trailer_byte = 8'h48; // H
            3'd3: expected_trailer_byte = 8'h53; // S
            3'd4: expected_trailer_byte = 8'h10 + {6'd0, profile};
            3'd5: expected_trailer_byte = 8'h08;
            3'd6: expected_trailer_byte = 8'h00;
            default: expected_trailer_byte = 8'h95;
        endcase
    end
endfunction

function automatic [13:0] score_byte_address;
    input [1:0] profile;
    input [7:0] offset;
    begin
        case (profile)
            2'd1: begin
                if (offset < 8'h90)
                    score_byte_address = 14'h0500 + {6'd0, offset};
                else if (offset == 8'h90)
                    score_byte_address = 14'h057f;
                else
                    score_byte_address = 14'h043c +
                                         {6'd0, offset - 8'h91};
            end
            2'd2: begin
                if (offset < 8'h90)
                    score_byte_address = 14'h04fc + {6'd0, offset};
                else if (offset == 8'h90)
                    score_byte_address = 14'h057b;
                else
                    score_byte_address = 14'h0438 +
                                         {6'd0, offset - 8'h91};
            end
            default: begin
                if (offset < 8'h90)
                    score_byte_address = 14'h04fa + {6'd0, offset};
                else if (offset < 8'h94)
                    score_byte_address = 14'h0436 +
                                         {6'd0, offset - 8'h90};
                else
                    score_byte_address = 14'h0579;
            end
        endcase
    end
endfunction

function automatic score_byte_selected;
    input [1:0] profile;
    input [13:0] address;
    begin
        case (profile)
            2'd1: score_byte_selected =
                ((address >= 14'h0500) && (address < 14'h0590)) ||
                ((address >= 14'h043c) && (address < 14'h0440));
            2'd2: score_byte_selected =
                ((address >= 14'h04fc) && (address < 14'h058c)) ||
                ((address >= 14'h0438) && (address < 14'h043c));
            2'd3: score_byte_selected =
                ((address >= 14'h04fa) && (address < 14'h058a)) ||
                ((address >= 14'h0436) && (address < 14'h043a));
            default: score_byte_selected = 1'b0;
        endcase
    end
endfunction

function automatic [7:0] select_ram_byte;
    input [15:0] word_data;
    input        byte_lane;
    begin
        select_ram_byte = byte_lane ? word_data[7:0] : word_data[15:8];
    end
endfunction

reg        config_download_d = 1'b0;
reg [4:0]  config_count = 5'd0;
reg [2:0]  config_match = 3'b000;
reg        config_error = 1'b0;
reg        config_valid_r = 1'b0;
reg [1:0]  config_profile_r = 2'd0;

reg        nvram_download_d = 1'b0;
reg [8:0]  nvram_count = 9'd0;
reg        nvram_error = 1'b0;
reg        nvram_valid = 1'b0;

wire profile_valid = config_valid_r && rom_identity_valid &&
                     (config_profile_r == rom_set_id) &&
                     (config_profile_r != 2'd0);

wire load_buffer_wr = nvram_download && nvram_wr &&
                      (nvram_addr < SCORE_WINDOW_SIZE);
wire [7:0] load_buffer_cpu_q;
wire [7:0] snapshot_buffer_hps_q;

reg [3:0] state = ST_IDLE;
reg [7:0] score_offset = 8'd0;
reg [17:0] sentinel_seen = 18'd0;
reg [1:0] rom_set_id_d = 2'd0;
reg       rom_identity_valid_d = 1'b0;
reg       restore_applied = 1'b0;
reg       dirty_r = 1'b0;
reg       snapshot_valid = 1'b0;

reg       nvram_upload_d = 1'b0;
reg       upload_started = 1'b0;
reg       capture_ready = 1'b0;
reg       upload_post_write = 1'b0;
reg [8:0] upload_read_count = 9'd0;
reg       upload_read_error = 1'b0;

wire identity_changed = (rom_set_id != rom_set_id_d) ||
                        (rom_identity_valid != rom_identity_valid_d);
wire config_started = config_download && !config_download_d;
wire nvram_started = nvram_download && !nvram_download_d;

wire [13:0] current_score_byte_address =
    score_byte_address(config_profile_r, score_offset);
wire [13:0] normal_even_byte_address = {normal_ram_addr, 1'b0};
wire [13:0] normal_odd_byte_address = {normal_ram_addr, 1'b1};
wire normal_score_write = profile_valid &&
    ((normal_ram_we[1] && score_byte_selected(
        config_profile_r, normal_even_byte_address)) ||
     (normal_ram_we[0] && score_byte_selected(
        config_profile_r, normal_odd_byte_address)));

wire scores_ready =
    (config_profile_r == 2'd1) ? &sentinel_seen[5:0] :
    (config_profile_r == 2'd2) ? &sentinel_seen[11:6] :
    (config_profile_r == 2'd3) ? &sentinel_seen[17:12] : 1'b0;

wire snapshot_buffer_wr = state == ST_CAPTURE_BUFFER_WRITE;
wire [7:0] capture_byte = select_ram_byte(
    ram_q, current_score_byte_address[0]
);

jtframe_dual_ram #(.DW(8), .AW(8)) u_load_buffer (
    .clk0  ( clk                    ),
    .data0 ( nvram_data             ),
    .addr0 ( nvram_addr[7:0]        ),
    .we0   ( load_buffer_wr         ),
    .q0    (                        ),
    .clk1  ( clk                    ),
    .data1 ( 8'd0                   ),
    .addr1 ( score_offset           ),
    .we1   ( 1'b0                   ),
    .q1    ( load_buffer_cpu_q      )
);

jtframe_dual_ram #(.DW(8), .AW(8)) u_snapshot_buffer (
    .clk0  ( clk                    ),
    .data0 ( 8'd0                   ),
    .addr0 ( nvram_addr[7:0]        ),
    .we0   ( 1'b0                   ),
    .q0    ( snapshot_buffer_hps_q  ),
    .clk1  ( clk                    ),
    .data1 ( capture_byte           ),
    .addr1 ( score_offset           ),
    .we1   ( snapshot_buffer_wr     ),
    .q1    (                        )
);

always @(posedge clk) begin
    config_download_d <= config_download;
    nvram_download_d <= nvram_download;

    if (reset) begin
        config_download_d <= 1'b0;
        config_count <= 5'd0;
        config_match <= 3'b000;
        config_error <= 1'b0;
        config_valid_r <= 1'b0;
        config_profile_r <= 2'd0;
        nvram_download_d <= 1'b0;
        nvram_count <= 9'd0;
        nvram_error <= 1'b0;
        nvram_valid <= 1'b0;
    end else begin
        if (config_download && !config_download_d) begin
            config_count <= 5'd0;
            config_match <= 3'b111;
            config_error <= 1'b0;
            config_valid_r <= 1'b0;
            config_profile_r <= 2'd0;
            nvram_valid <= 1'b0;
        end

        if (config_download && config_wr) begin
            if ((config_addr == {22'd0, config_count}) &&
                (config_count < CONFIG_SIZE)) begin
                if (config_data != expected_config_byte(2'd1, config_count))
                    config_match[0] <= 1'b0;
                if (config_data != expected_config_byte(2'd2, config_count))
                    config_match[1] <= 1'b0;
                if (config_data != expected_config_byte(2'd3, config_count))
                    config_match[2] <= 1'b0;
                config_count <= config_count + 5'd1;
            end else begin
                config_error <= 1'b1;
            end
        end

        if (!config_download && config_download_d) begin
            config_valid_r <= !config_error &&
                              (config_count == CONFIG_SIZE) &&
                              ((config_match == 3'b001) ||
                               (config_match == 3'b010) ||
                               (config_match == 3'b100));
            case (config_match)
                3'b001: config_profile_r <= 2'd1;
                3'b010: config_profile_r <= 2'd2;
                3'b100: config_profile_r <= 2'd3;
                default: config_profile_r <= 2'd0;
            endcase
        end

        if (nvram_download && !nvram_download_d) begin
            nvram_count <= 9'd0;
            nvram_error <= 1'b0;
            nvram_valid <= 1'b0;
        end

        if (nvram_download && nvram_wr) begin
            if ((nvram_addr == {18'd0, nvram_count}) &&
                (nvram_count < NVRAM_SIZE)) begin
                nvram_count <= nvram_count + 9'd1;
                if ((nvram_count >= SCORE_DATA_SIZE) &&
                    (nvram_count < SCORE_WINDOW_SIZE) &&
                    (nvram_data != 8'h00))
                    nvram_error <= 1'b1;
                if ((nvram_count >= SCORE_WINDOW_SIZE) &&
                    (nvram_data != expected_trailer_byte(
                        config_profile_r, nvram_count[2:0])))
                    nvram_error <= 1'b1;
            end else begin
                nvram_error <= 1'b1;
            end
        end

        if (!nvram_download && nvram_download_d)
            nvram_valid <= profile_valid && !nvram_error &&
                           (nvram_count == NVRAM_SIZE);

        if (!rom_identity_valid ||
            (config_valid_r && (config_profile_r != rom_set_id)))
            nvram_valid <= 1'b0;
    end
end

always @(posedge clk) begin
    nvram_upload_d <= nvram_upload;
    rom_set_id_d <= rom_set_id;
    rom_identity_valid_d <= rom_identity_valid;

    if (reset || cpu_reset) begin
        state <= ST_IDLE;
        score_offset <= 8'd0;
        sentinel_seen <= 18'd0;
        rom_set_id_d <= rom_set_id;
        rom_identity_valid_d <= rom_identity_valid;
        restore_applied <= 1'b0;
        dirty_r <= 1'b0;
        snapshot_valid <= 1'b0;
        nvram_upload_d <= 1'b0;
        upload_started <= 1'b0;
        capture_ready <= 1'b0;
        upload_post_write <= 1'b0;
        upload_read_count <= 9'd0;
        upload_read_error <= 1'b0;
    end else begin
        if (identity_changed) begin
            sentinel_seen <= 18'd0;
            restore_applied <= 1'b0;
            dirty_r <= 1'b0;
            snapshot_valid <= 1'b0;
            upload_started <= 1'b0;
            capture_ready <= 1'b0;
            upload_post_write <= 1'b0;
            upload_read_count <= 9'd0;
            upload_read_error <= 1'b0;
        end

        if (config_started) begin
            restore_applied <= 1'b0;
            snapshot_valid <= 1'b0;
            upload_started <= 1'b0;
            capture_ready <= 1'b0;
            upload_post_write <= 1'b0;
        end

        if (nvram_started) begin
            restore_applied <= 1'b0;
            snapshot_valid <= 1'b0;
        end

        // Readiness values are initialization writes, not stable table data.
        // Watch all three exact profiles so writes may precede the descriptor.
        if (normal_ram_we[1]) begin
            case (normal_even_byte_address)
                14'h0500: if (normal_ram_data[15:8] == 8'h00)
                               sentinel_seen[0] <= 1'b1;
                14'h043c: if (normal_ram_data[15:8] == 8'h00)
                               sentinel_seen[4] <= 1'b1;
                14'h04fc: if (normal_ram_data[15:8] == 8'h00)
                               sentinel_seen[6] <= 1'b1;
                14'h0438: if (normal_ram_data[15:8] == 8'h00)
                               sentinel_seen[10] <= 1'b1;
                14'h04fa: if (normal_ram_data[15:8] == 8'h00)
                               sentinel_seen[12] <= 1'b1;
                14'h0436: if (normal_ram_data[15:8] == 8'h00)
                               sentinel_seen[14] <= 1'b1;
                default: begin end
            endcase
        end
        if (normal_ram_we[0]) begin
            case (normal_odd_byte_address)
                14'h058f: if (normal_ram_data[7:0] == 8'h00)
                               sentinel_seen[1] <= 1'b1;
                14'h057f: if (normal_ram_data[7:0] == 8'h2d)
                               sentinel_seen[3:2] <= 2'b11;
                14'h043f: if (normal_ram_data[7:0] == 8'h00)
                               sentinel_seen[5] <= 1'b1;
                14'h058b: if (normal_ram_data[7:0] == 8'h00)
                               sentinel_seen[7] <= 1'b1;
                14'h057b: if (normal_ram_data[7:0] == 8'h2d)
                               sentinel_seen[9:8] <= 2'b11;
                14'h043b: if (normal_ram_data[7:0] == 8'h00)
                               sentinel_seen[11] <= 1'b1;
                14'h0589: if (normal_ram_data[7:0] == 8'h00)
                               sentinel_seen[13] <= 1'b1;
                14'h0439: if (normal_ram_data[7:0] == 8'h00)
                               sentinel_seen[15] <= 1'b1;
                14'h0579: if (normal_ram_data[7:0] == 8'h2d)
                               sentinel_seen[17:16] <= 2'b11;
                default: begin end
            endcase
        end

        if (!identity_changed && !config_started && !nvram_started &&
            scores_ready && (restore_applied || !nvram_valid) &&
            normal_score_write)
            dirty_r <= 1'b1;

        if (upload_started && capture_ready && normal_score_write)
            upload_post_write <= 1'b1;

        if (nvram_upload && !nvram_upload_d) begin
            upload_started <= 1'b1;
            capture_ready <= !profile_valid;
            snapshot_valid <= 1'b0;
            upload_post_write <= 1'b0;
            upload_read_count <= 9'd0;
            upload_read_error <= 1'b0;
        end

        if (nvram_upload && nvram_rd) begin
            if ((nvram_addr == {18'd0, upload_read_count}) &&
                (upload_read_count < NVRAM_SIZE))
                upload_read_count <= upload_read_count + 9'd1;
            else
                upload_read_error <= 1'b1;
        end

        if (!nvram_upload && nvram_upload_d) begin
            if (capture_ready && snapshot_valid && !upload_read_error &&
                !upload_post_write && !normal_score_write &&
                (upload_read_count == NVRAM_SIZE))
                dirty_r <= 1'b0;
            upload_started <= 1'b0;
            capture_ready <= 1'b0;
            upload_post_write <= 1'b0;
            upload_read_count <= 9'd0;
            upload_read_error <= 1'b0;
        end

        if (identity_changed || config_started || nvram_started) begin
            state <= ST_IDLE;
        end else if (ss_active && (state != ST_IDLE)) begin
            state <= ST_IDLE;
            snapshot_valid <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (profile_valid && nvram_valid && scores_ready &&
                        !restore_applied && !ss_active) begin
                        state <= ST_RESTORE_HOLD;
                    end else if (upload_started && profile_valid &&
                                 scores_ready && !ss_active) begin
                        state <= ST_CAPTURE_HOLD;
                    end
                end

                ST_RESTORE_HOLD: begin
                    if (hold_ack) begin
                        score_offset <= 8'd0;
                        state <= ST_RESTORE_BUFFER_READ;
                    end
                end

                ST_RESTORE_BUFFER_READ:
                    state <= ST_RESTORE_RAM_WRITE;

                ST_RESTORE_RAM_WRITE: begin
                    if (score_offset == SCORE_DATA_SIZE - 8'd1) begin
                        restore_applied <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        score_offset <= score_offset + 8'd1;
                        state <= ST_RESTORE_BUFFER_READ;
                    end
                end

                ST_CAPTURE_HOLD: begin
                    if (hold_ack) begin
                        score_offset <= 8'd0;
                        state <= ST_CAPTURE_RAM_READ;
                    end
                end

                ST_CAPTURE_RAM_READ:
                    state <= ST_CAPTURE_BUFFER_WRITE;

                ST_CAPTURE_BUFFER_WRITE: begin
                    if (score_offset == SCORE_DATA_SIZE - 8'd1) begin
                        snapshot_valid <= 1'b1;
                        capture_ready <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        score_offset <= score_offset + 8'd1;
                        state <= ST_CAPTURE_RAM_READ;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
end

assign hold_request = !reset && !cpu_reset && !ss_active &&
                      (state != ST_IDLE);
assign ram_owned = (state == ST_RESTORE_BUFFER_READ) ||
                   (state == ST_RESTORE_RAM_WRITE) ||
                   (state == ST_CAPTURE_RAM_READ) ||
                   (state == ST_CAPTURE_BUFFER_WRITE);

assign ram_addr = current_score_byte_address[13:1];
assign ram_we = (state == ST_RESTORE_RAM_WRITE) ?
                (current_score_byte_address[0] ? 2'b01 : 2'b10) : 2'b00;
assign ram_data = current_score_byte_address[0] ?
                  {8'd0, load_buffer_cpu_q} :
                  {load_buffer_cpu_q, 8'd0};

wire nvram_score_address = nvram_addr < SCORE_DATA_SIZE;
wire nvram_padding_address = (nvram_addr >= SCORE_DATA_SIZE) &&
                             (nvram_addr < SCORE_WINDOW_SIZE);
wire nvram_trailer_address = (nvram_addr >= SCORE_WINDOW_SIZE) &&
                             (nvram_addr < NVRAM_SIZE);

assign nvram_q = !snapshot_valid ? 8'h00 :
                 nvram_score_address ? snapshot_buffer_hps_q :
                 nvram_padding_address ? 8'h00 :
                 nvram_trailer_address ? expected_trailer_byte(
                    config_profile_r, nvram_addr[2:0]) : 8'h00;

// Unknown descriptors complete as a zero-filled fail-closed image. Reset also
// releases a stale HPS transaction immediately.
assign nvram_wait = nvram_upload && profile_valid && !capture_ready &&
                    !reset && !cpu_reset;
assign dirty = dirty_r && profile_valid;
assign active = (state != ST_IDLE) ||
                (upload_started && !capture_ready);
assign config_valid = profile_valid;
assign active_profile = config_profile_r;

endmodule
