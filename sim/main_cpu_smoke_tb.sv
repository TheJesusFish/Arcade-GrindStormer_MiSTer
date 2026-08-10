`timescale 1ns/1ps

module main_cpu_smoke_tb;

reg clk = 1'b0;
always #5 clk = ~clk;

reg rst = 1'b1;
reg irq4_start = 1'b0;

wire        rom_cs;
wire [17:0] rom_addr;
reg  [15:0] rom_data;
wire        rom_ok = rom_cs;

wire [7:0]  coin_control;
wire        v25_reset_n;
wire [15:0] palette_scan_dout;
wire        irq4;
wire [23:0] last_program_fetch;
wire [31:0] bus_count;
wire [31:0] rom_read_count;
wire [31:0] wram_write_count;
wire [31:0] gp_access_count;
wire [31:0] palette_write_count;
wire [31:0] irq_count;
wire [31:0] iack_count;
wire [23:0] cpu_addr_debug;

function automatic [15:0] rom_word;
    input [17:0] word_addr;
    begin
        case (word_addr)
            // Reset SSP = $00103ffc, reset PC = $00000100.
            18'h00000: rom_word = 16'h0010;
            18'h00001: rom_word = 16'h3ffc;
            18'h00002: rom_word = 16'h0000;
            18'h00003: rom_word = 16'h0100;

            // Level-4 autovector ($70) -> $00000180.
            18'h00038: rom_word = 16'h0000;
            18'h00039: rom_word = 16'h0180;

            // MOVE.B #$10,$0020001d: release the V25 reset latch.
            18'h00080: rom_word = 16'h13fc;
            18'h00081: rom_word = 16'h0010;
            18'h00082: rom_word = 16'h0020;
            18'h00083: rom_word = 16'h001d;

            // MOVE.W #$7fff,$00400000: exercise mapped palette RAM.
            18'h00084: rom_word = 16'h33fc;
            18'h00085: rom_word = 16'h7fff;
            18'h00086: rom_word = 16'h0040;
            18'h00087: rom_word = 16'h0000;

            // Rewind GP pointer, write/read one longword, and compare it.
            18'h00088: rom_word = 16'h33fc;
            18'h00089: rom_word = 16'h0000;
            18'h0008a: rom_word = 16'h0030;
            18'h0008b: rom_word = 16'h0000;
            18'h0008c: rom_word = 16'h23fc;
            18'h0008d: rom_word = 16'haaaa;
            18'h0008e: rom_word = 16'h5555;
            18'h0008f: rom_word = 16'h0030;
            18'h00090: rom_word = 16'h0004;
            18'h00091: rom_word = 16'h33fc;
            18'h00092: rom_word = 16'h0000;
            18'h00093: rom_word = 16'h0030;
            18'h00094: rom_word = 16'h0000;
            18'h00095: rom_word = 16'h2039;
            18'h00096: rom_word = 16'h0030;
            18'h00097: rom_word = 16'h0004;
            18'h00098: rom_word = 16'h0c80;
            18'h00099: rom_word = 16'haaaa;
            18'h0009a: rom_word = 16'h5555;
            18'h0009b: rom_word = 16'h6612;

            // Success marker, then lower the interrupt mask.
            18'h0009c: rom_word = 16'h33fc;
            18'h0009d: rom_word = 16'h1234;
            18'h0009e: rom_word = 16'h0040;
            18'h0009f: rom_word = 16'h0002;
            18'h000a0: rom_word = 16'h46fc;
            18'h000a1: rom_word = 16'h2000;
            18'h000a2: rom_word = 16'h4e71;
            18'h000a3: rom_word = 16'h60fc;
            18'h000a4: rom_word = 16'h4e71;
            18'h000a5: rom_word = 16'h60fe;

            // IRQ4: select GP9001 register $0e, write to clear, then RTE.
            18'h000c0: rom_word = 16'h33fc;
            18'h000c1: rom_word = 16'h000e;
            18'h000c2: rom_word = 16'h0030;
            18'h000c3: rom_word = 16'h0008;
            18'h000c4: rom_word = 16'h33fc;
            18'h000c5: rom_word = 16'h0000;
            18'h000c6: rom_word = 16'h0030;
            18'h000c7: rom_word = 16'h000c;
            18'h000c8: rom_word = 16'h4e73;

            default: rom_word = 16'h4e71;
        endcase
    end
endfunction

always @* rom_data = rom_word(rom_addr);

grind_stormer_main dut (
    .clk                     (clk),
    .rst                     (rst),
    .halt_n                  (1'b1),
    .rom_cs                  (rom_cs),
    .rom_addr                (rom_addr),
    .rom_data                (rom_data),
    .rom_ok                  (rom_ok),
    .in1_data                (16'hffff),
    .in2_data                (16'hffff),
    .sys_data                (16'hffff),
    .hcnt                    (10'd0),
    .vcnt                    (9'd0),
    .irq4_start              (irq4_start),
    .sound_clk               (clk),
    .sound_shared_addr       (15'd0),
    .sound_shared_din        (8'd0),
    .sound_shared_we         (1'b0),
    .sound_shared_dout       (),
    .coin_control            (coin_control),
    .v25_reset_n             (v25_reset_n),
    .wram_scan_addr          (13'd0),
    .wram_scan_dout          (),
    .palette_scan_addr       (11'd0),
    .palette_scan_dout       (palette_scan_dout),
    .gp0_scan_addr           (13'd0),
    .gp0_scan_dout           (),
    .gp_obj_buf_start        (1'b0),
    .gp0_obj_scan_addr       (10'd0),
    .gp0_obj_scan_dout       (),
    .gp0_obj_buf_busy        (),
    .gp0_obj_buf_miss        (),
    .gp0_scrolls             (),
    .gp0_scroll_flip         (),
    .cpu_cen                 (),
    .cpu_cenb                (),
    .cpu_bus_active          (),
    .cpu_rw                  (),
    .irq4                    (irq4),
    .last_program_fetch      (last_program_fetch),
    .bus_count               (bus_count),
    .rom_read_count          (rom_read_count),
    .wram_write_count        (wram_write_count),
    .shared_write_count      (),
    .gp_access_count         (gp_access_count),
    .palette_write_count     (palette_write_count),
    .io_access_count         (),
    .unmapped_count          (),
    .irq_count               (irq_count),
    .iack_count              (iack_count),
    .cpu_addr_debug          (cpu_addr_debug),
    .cpu_dout_debug          (),
    .cpu_din_debug           (),
    .gp0_ptr                 (),
    .debug_events            (),
    .ss_irq                  (1'b0),
    .ss_override             (1'b0),
    .ss_reset                (1'b0),
    .ss_cpu_run              (1'b1),
    .ss_hold                 (1'b0),
    .ss_restore_enable       (1'b0),
    .ss_restore_commit       (1'b0),
    .ss_restore_irq4         (1'b0),
    .ss_restore_coin_control (8'd0),
    .ss_reset_vector         (64'd0),
    .cpu_ack_debug           (),
    .cpu_iack_debug          (),
    .cpu_lds_n_debug         (),
    .cpu_fc_debug            (),
    .gp_idle                 (),
    .ss_data                 (64'd0),
    .ss_addr                 (32'd0),
    .ss_select               (8'd0),
    .ss_write                (1'b0),
    .ss_read                 (1'b0),
    .ss_query                (1'b0),
    .ss_data_out             (),
    .ss_ack                  ()
);

task automatic pulse_and_service_irq;
    input integer expected_count;
    integer timeout;
    reg [31:0] reads_before;
    begin
        @(negedge clk);
        irq4_start = 1'b1;
        @(negedge clk);
        irq4_start = 1'b0;

        timeout = 0;
        while (((irq_count < expected_count) ||
                (iack_count < expected_count) ||
                (gp_access_count < (expected_count * 2)) ||
                irq4) && (timeout < 500000)) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (timeout == 500000)
            $fatal(1,
                "IRQ%0d timeout: irq=%0b irq_count=%0d iack=%0d gp=%0d pc=%06x",
                expected_count, irq4, irq_count, iack_count,
                gp_access_count, cpu_addr_debug);

        reads_before = rom_read_count;
        repeat (4000) @(posedge clk);
        if (rom_read_count <= reads_before)
            $fatal(1, "68000 did not resume ROM execution after IRQ%0d",
                expected_count);
    end
endtask

integer boot_timeout;
initial begin
    repeat (64) @(posedge clk);
    rst = 1'b0;

    boot_timeout = 0;
    while (((coin_control !== 8'h10) ||
            (palette_write_count < 2) ||
            (rom_read_count < 12)) && (boot_timeout < 500000)) begin
        @(posedge clk);
        boot_timeout = boot_timeout + 1;
    end

    if (boot_timeout == 500000)
        $fatal(1,
            "boot timeout: coin=%02x palette=%0d rom=%0d pc=%06x",
            coin_control, palette_write_count, rom_read_count,
            cpu_addr_debug);
    if (!v25_reset_n)
        $fatal(1, "coin-control bit 4 did not release the V25");

    repeat (8) @(posedge clk);
    if ({dut.u_palette_ram.u_hi.u_ram.mem[1],
         dut.u_palette_ram.u_lo.u_ram.mem[1]} !== 16'h1234)
        $fatal(1,
            "GP longword readback did not reach the success marker; gp0=%04x gp1=%04x ptr=%04x",
            {dut.u_gp0.u_vram.u_hi.u_ram.mem[0],
             dut.u_gp0.u_vram.u_lo.u_ram.mem[0]},
            {dut.u_gp0.u_vram.u_hi.u_ram.mem[1],
             dut.u_gp0.u_vram.u_lo.u_ram.mem[1]},
            dut.u_gp0.ptr);

    pulse_and_service_irq(1);
    pulse_and_service_irq(2);
    pulse_and_service_irq(3);

    if (irq_count != 3)
        $fatal(1, "unexpected IRQ latch count: %0d", irq_count);
    if (iack_count < 3)
        $fatal(1, "missing 68000 interrupt acknowledges: %0d", iack_count);
    if (gp_access_count < 6)
        $fatal(1, "missing GP9001 IRQ-clear writes: %0d", gp_access_count);
    if (wram_write_count == 0)
        $fatal(1, "interrupt stack never wrote work RAM");
    if ((last_program_fetch < 24'h000100) ||
        (last_program_fetch >= 24'h000200))
        $fatal(1, "program fetch escaped synthetic ROM body: %06x",
            last_program_fetch);

    $display(
        "PASS main_cpu_smoke_tb bus=%0d rom=%0d wram=%0d gp=%0d iack=%0d",
        bus_count, rom_read_count, wram_write_count, gp_access_count,
        iack_count);
    $finish;
end

endmodule
