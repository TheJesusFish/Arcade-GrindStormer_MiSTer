// TP-027 raw MRA byte stream to JTFrame SDRAM programming bridge.
module grind_stormer_rom_loader #(
    parameter integer AW = 22
) (
    input                   clk,
    input                   rst,

    input                   ioctl_rom,
    input      [26:0]       ioctl_addr,
    input      [7:0]        ioctl_dout,
    input                   ioctl_wr,

    output                  dwnld_busy,
    output reg [1:0]        prog_ba,
    output reg [AW-1:0]     prog_addr,
    output reg [15:0]       prog_data,
    output reg [1:0]        prog_mask,
    output                  prog_rd,
    output reg              prog_we,
    input                   prog_rdy,
    input                   prog_ack,

    output                  accepted,
    output reg              range_error,
    output reg              overflow_error,
    output reg [26:0]       last_addr
);

localparam [26:0] PROGRAM_END = 27'h0080000;
localparam [26:0] IMAGE_END   = 27'h0280000;

wire in_range = ioctl_addr < IMAGE_END;
wire terminal_sentinel = ioctl_addr == IMAGE_END;
wire in_program = ioctl_addr < PROGRAM_END;
wire [1:0] target_bank = in_program ? 2'd0 : 2'd1;
wire [26:0] local_byte_addr =
    in_program ? ioctl_addr : ioctl_addr - PROGRAM_END;
wire [21:0] local_word_addr = local_byte_addr[22:1];
wire [21:0] graphics_word_addr;
// Program uses MAME ROM_LOAD16_WORD_SWAP: source byte 0 becomes the low byte
// of the CPU word. Graphics are raw and retain byte order: source byte 0
// becomes the high byte of the renderer word.
wire write_low_lane = in_program ?
                      ~local_byte_addr[0] : local_byte_addr[0];
wire can_accept = !prog_we || prog_ack;

grind_stormer_gfx_repack u_gfx_repack (
    .logical_addr  (local_word_addr),
    .physical_addr (graphics_word_addr)
);

assign prog_rd = 1'b0;
assign dwnld_busy = ioctl_rom || prog_we;
assign accepted = !rst && ioctl_wr && ioctl_rom && in_range && can_accept;

// prog_mask is active-low. Data is duplicated so the selected byte lane alone
// determines the transform.
always @(posedge clk) begin
    if (rst) begin
        prog_ba       <= 2'd0;
        prog_addr     <= {AW{1'b0}};
        prog_data     <= 16'h0000;
        prog_mask     <= 2'b11;
        prog_we       <= 1'b0;
        range_error   <= 1'b0;
        overflow_error <= 1'b0;
        last_addr     <= 27'd0;
    end else begin
        if (prog_we && prog_ack)
            prog_we <= 1'b0;

        if (ioctl_wr && ioctl_rom) begin
            last_addr <= ioctl_addr;
            if (!in_range) begin
                // JTFrame's DDR replay can emit one final strobe at the
                // reported byte length. It is an end marker, not ROM data.
                if (!terminal_sentinel)
                    range_error <= 1'b1;
            end else if (can_accept) begin
                prog_ba   <= target_bank;
                // The raw MRA order stays unchanged. Only graphics storage is
                // paired physically so lower/upper bitplanes share a burst.
                prog_addr <= in_program ? local_word_addr[AW-1:0] :
                                          graphics_word_addr[AW-1:0];
                prog_data <= {ioctl_dout, ioctl_dout};
                prog_mask <= write_low_lane ? 2'b10 : 2'b01;
                prog_we   <= 1'b1;
            end else begin
                overflow_error <= 1'b1;
            end
        end

        // prog_rdy is deliberately not used as an acceptance pulse. A request
        // is held stable until prog_ack; the upstream MiSTer bridge uses the
        // programming ready/write state to apply download backpressure.
    end
end

endmodule
