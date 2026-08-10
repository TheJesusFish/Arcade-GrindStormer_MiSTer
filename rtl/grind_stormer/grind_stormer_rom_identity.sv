// SPDX-License-Identifier: BSD-3-Clause
//
// Identity for the normalized 0x280000-byte TP-027 download stream. CRC64 is
// over every accepted byte. The program CRC32 identifies the three official
// MAME 0.288 sets without relying on filenames or MRA ordering metadata.
module grind_stormer_rom_identity #(
    parameter [31:0] EXPECTED_LENGTH = 32'h0028_0000,
    parameter [31:0] CRC_GRINDSTM  = 32'h4923_f790,
    parameter [31:0] CRC_GRINDSTMA = 32'h8d8c_0392,
    parameter [31:0] CRC_VFIVE     = 32'h731d_50f4
) (
    input              clk,
    input              rst,
    input              download,
    input              accepted,
    input      [26:0]  addr,
    input      [7:0]   data,
    output reg [63:0]  stream_crc64,
    output reg [31:0]  program_crc32,
    output reg [31:0]  stream_length,
    output reg [1:0]   set_id,
    output reg         valid,
    output reg         sequence_error
);

reg download_d = 1'b0;
reg [63:0] crc64_state = 64'd0;
reg [31:0] crc32_state = 32'hffff_ffff;
reg [31:0] byte_count = 32'd0;

function automatic [63:0] crc64_ecma_byte;
    input [63:0] crc;
    input [7:0] byte_value;
    integer i;
    reg [63:0] next;
    begin
        next = crc ^ {byte_value, 56'd0};
        for (i = 0; i < 8; i = i + 1)
            next = next[63] ?
                (next << 1) ^ 64'h42f0_e1eb_a9ea_3693 :
                (next << 1);
        crc64_ecma_byte = next;
    end
endfunction

function automatic [31:0] crc32_byte;
    input [31:0] crc;
    input [7:0] byte_value;
    integer i;
    reg [31:0] next;
    begin
        next = crc ^ {24'd0, byte_value};
        for (i = 0; i < 8; i = i + 1)
            next = next[0] ?
                (next >> 1) ^ 32'hedb8_8320 :
                (next >> 1);
        crc32_byte = next;
    end
endfunction

wire [31:0] final_program_crc = ~crc32_state;

always @(posedge clk) begin
    download_d <= download;

    if (rst) begin
        stream_crc64 <= 64'd0;
        program_crc32 <= 32'd0;
        stream_length <= 32'd0;
        set_id <= 2'd0;
        valid <= 1'b0;
        sequence_error <= 1'b0;
        crc64_state <= 64'd0;
        crc32_state <= 32'hffff_ffff;
        byte_count <= 32'd0;
        download_d <= 1'b0;
    end else begin
        if (download && !download_d) begin
            stream_crc64 <= 64'd0;
            program_crc32 <= 32'd0;
            stream_length <= 32'd0;
            set_id <= 2'd0;
            valid <= 1'b0;
            sequence_error <= 1'b0;
            crc64_state <= 64'd0;
            crc32_state <= 32'hffff_ffff;
            byte_count <= 32'd0;
            if (accepted) begin
                sequence_error <= addr != 27'd0;
                crc64_state <= crc64_ecma_byte(64'd0, data);
                crc32_state <= (addr < 27'h008_0000) ?
                    crc32_byte(32'hffff_ffff, data) :
                    32'hffff_ffff;
                byte_count <= 32'd1;
            end
        end else if (download && accepted) begin
            if (addr != byte_count[26:0])
                sequence_error <= 1'b1;
            crc64_state <= crc64_ecma_byte(crc64_state, data);
            if (addr < 27'h008_0000)
                crc32_state <= crc32_byte(crc32_state, data);
            byte_count <= byte_count + 32'd1;
        end

        if (!download && download_d) begin
            stream_crc64 <= crc64_state;
            program_crc32 <= final_program_crc;
            stream_length <= byte_count;
            case (final_program_crc)
                CRC_GRINDSTM:  set_id <= 2'd1;
                CRC_GRINDSTMA: set_id <= 2'd2;
                CRC_VFIVE:     set_id <= 2'd3;
                default:       set_id <= 2'd0;
            endcase
            valid <= (byte_count == EXPECTED_LENGTH) &&
                     !sequence_error &&
                     ((final_program_crc == CRC_GRINDSTM) ||
                      (final_program_crc == CRC_GRINDSTMA) ||
                      (final_program_crc == CRC_VFIVE));
        end
    end
end

endmodule
