`timescale 1ns/1ps

module board_contract_tb;

reg [23:0] addr = 24'd0;
reg bus_active = 1'b0;
reg rw = 1'b1;
wire rom_cs;
wire rom_read_cs;
wire wram_cs;
wire in1_cs;
wire in2_cs;
wire sys_cs;
wire sound_ctrl_cs;
wire shared_cs;
wire gp0_cs;
wire palette_cs;
wire vcount_cs;
wire io_cs;
wire gp_cs;
wire mapped_cs;
wire unmapped_cs;

reg [5:0] joy1_n = 6'h3f;
reg [5:0] joy2_n = 6'h3f;
reg [3:0] start_n = 4'hf;
reg [3:0] coin_n = 4'hf;
reg service_n = 1'b1;
reg tilt_n = 1'b1;
reg test_n = 1'b1;
wire [15:0] in1;
wire [15:0] in2;
wire [15:0] sys;

grind_stormer_main_decode u_decode (
    .addr          (addr),
    .bus_active    (bus_active),
    .rw            (rw),
    .rom_cs        (rom_cs),
    .rom_read_cs   (rom_read_cs),
    .wram_cs       (wram_cs),
    .in1_cs        (in1_cs),
    .in2_cs        (in2_cs),
    .sys_cs        (sys_cs),
    .sound_ctrl_cs (sound_ctrl_cs),
    .shared_cs     (shared_cs),
    .gp0_cs        (gp0_cs),
    .palette_cs    (palette_cs),
    .vcount_cs     (vcount_cs),
    .io_cs         (io_cs),
    .gp_cs         (gp_cs),
    .mapped_cs     (mapped_cs),
    .unmapped_cs   (unmapped_cs)
);

grind_stormer_inputs u_inputs (
    .joy1_n    (joy1_n),
    .joy2_n    (joy2_n),
    .start_n   (start_n),
    .coin_n    (coin_n),
    .service_n (service_n),
    .tilt_n    (tilt_n),
    .test_n    (test_n),
    .in1       (in1),
    .in2       (in2),
    .sys       (sys)
);

task automatic check_select;
    input [23:0] test_addr;
    input test_rw;
    input [8:0] expected;
    begin
        addr = test_addr;
        rw = test_rw;
        bus_active = 1'b1;
        #1;
        if ({vcount_cs, palette_cs, gp0_cs, shared_cs, sound_ctrl_cs,
             sys_cs, in2_cs, in1_cs, wram_cs} != expected)
            $fatal(1, "decode mismatch at %06x rw=%0d", test_addr, test_rw);
        if (!mapped_cs || unmapped_cs)
            $fatal(1, "mapped flags mismatch at %06x", test_addr);
    end
endtask

initial begin
    bus_active = 1'b1;
    addr = 24'h000000;
    rw = 1'b1;
    #1;
    if (!rom_cs || !rom_read_cs || !mapped_cs || unmapped_cs)
        $fatal(1, "program ROM read decode failed");
    rw = 1'b0;
    #1;
    if (!rom_cs || rom_read_cs)
        $fatal(1, "program ROM write qualification failed");

    check_select(24'h100000, 1'b1, 9'b000000001);
    check_select(24'h103fff, 1'b0, 9'b000000001);
    check_select(24'h200010, 1'b1, 9'b000000010);
    check_select(24'h200015, 1'b1, 9'b000000100);
    check_select(24'h200018, 1'b1, 9'b000001000);
    check_select(24'h20001d, 1'b0, 9'b000010000);
    check_select(24'h210000, 1'b1, 9'b000100000);
    check_select(24'h21ffff, 1'b0, 9'b000100000);
    check_select(24'h300000, 1'b1, 9'b001000000);
    check_select(24'h30000d, 1'b0, 9'b001000000);
    check_select(24'h400000, 1'b1, 9'b010000000);
    check_select(24'h400fff, 1'b0, 9'b010000000);
    check_select(24'h700001, 1'b1, 9'b100000000);

    addr = 24'h080000;
    rw = 1'b1;
    #1;
    if (mapped_cs || !unmapped_cs)
        $fatal(1, "unmapped boundary was claimed");
    bus_active = 1'b0;
    #1;
    if (mapped_cs || unmapped_cs)
        $fatal(1, "inactive bus decoded a device");

    if (in1 != 16'd0 || in2 != 16'd0 || sys != 16'd0)
        $fatal(1, "released active-low inputs are not zero");

    joy1_n = 6'b000000;
    #1;
    if (in1[7:0] != 8'h3f)
        $fatal(1, "player input bit order mismatch");
    joy1_n = 6'h3f;
    start_n[0] = 1'b0;
    start_n[1] = 1'b0;
    coin_n[0] = 1'b0;
    coin_n[1] = 1'b0;
    service_n = 1'b0;
    tilt_n = 1'b0;
    test_n = 1'b0;
    #1;
    if (sys[7:0] != 8'h7f)
        $fatal(1, "system input bit order mismatch");

    $display("PASS board_contract_tb");
    $finish;
end

endmodule
