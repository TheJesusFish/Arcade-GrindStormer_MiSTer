`timescale 1ns/1ps

module sound_clock_restore_tb;

reg clk = 1'b0;
reg reset = 1'b1;
reg v25_enable = 1'b0;
reg ss_restore_enable = 1'b0;
reg ss_restore_commit = 1'b0;
reg main_shared_write = 1'b0;
reg [14:0] main_shared_addr = 15'd0;
reg [7:0] main_shared_data = 8'd0;
wire debug_v25_cen;
wire debug_ym_cen;
wire debug_ym_cen_p1;
wire [14:0] shared_addr;
wire [7:0] shared_dout;
wire shared_we;
wire signed [15:0] snd_mono;
wire sample;
integer v25_count;
integer ym_count;
integer ym_p1_count;
integer i;

always #5 clk = ~clk;

grind_stormer_sound dut (
    .reset               (reset),
    .clk                 (clk),
    .v25_enable          (v25_enable),
    .dip_a               (8'h00),
    .dip_b               (8'h00),
    .jmpr                (8'h90),
    .ym_enable           (1'b1),
    .state_hold          (1'b0),
    .main_shared_write   (main_shared_write),
    .main_shared_addr    (main_shared_addr),
    .main_shared_data    (main_shared_data),
    .ss_restore_enable   (ss_restore_enable),
    .ss_restore_commit   (ss_restore_commit),
    .ss_data             (64'd0),
    .ss_addr             (32'd0),
    .ss_select           (8'd0),
    .ss_write            (1'b0),
    .ss_read             (1'b0),
    .ss_query            (1'b0),
    .ss_data_out         (),
    .ss_ack              (),
    .shared_addr         (shared_addr),
    .shared_dout         (shared_dout),
    .shared_we           (shared_we),
    .shared_din          (8'h00),
    .snd_mono            (snd_mono),
    .sample              (sample),
    .debug_fault         (),
    .debug_halted        (),
    .debug_pc            (),
    .debug_state_idle    (),
    .state_idle          (),
    .state_held          (),
    .debug_v25_reset_n   (),
    .debug_ym_write      (),
    .debug_ym_a0         (),
    .debug_ym_data       (),
    .debug_v25_cen       (debug_v25_cen),
    .debug_ym_cen        (debug_ym_cen),
    .debug_ym_cen_p1     (debug_ym_cen_p1),
    .debug_ym_status     ()
);

task automatic count_window;
    input integer cycles;
    begin
        v25_count = 0;
        ym_count = 0;
        ym_p1_count = 0;
        for (i = 0; i < cycles; i = i + 1) begin
            @(posedge clk);
            #1;
            if (debug_v25_cen)
                v25_count = v25_count + 1;
            if (debug_ym_cen)
                ym_count = ym_count + 1;
            if (debug_ym_cen_p1)
                ym_p1_count = ym_p1_count + 1;
        end
    end
endtask

initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset <= 1'b0;
    dut.baseline_valid = 1'b1;

    count_window(756);
    if (v25_count != 80)
        $fatal(1, "V25 enable ratio is %0d/756, expected 80", v25_count);
    if (ym_count != 27)
        $fatal(1, "IKAOPM enable ratio is %0d/756, expected 27", ym_count);
    if (ym_p1_count != 13)
        $fatal(1, "IKAOPM p1 ratio is %0d/756, expected 13", ym_p1_count);

    @(negedge clk);
    ss_restore_enable <= 1'b1;
    ss_restore_commit <= 1'b1;
    @(posedge clk);
    #1;
    if (debug_v25_cen || debug_ym_cen || debug_ym_cen_p1)
        $fatal(1, "clock enable escaped on restore commit");
    @(negedge clk);
    ss_restore_commit <= 1'b0;

    if (!dut.baseline_restore_memory_active)
        $fatal(1, "baseline-work restore did not start");
    while (dut.baseline_restore_memory_active) begin
        @(posedge clk);
        #1;
        if (debug_v25_cen || debug_ym_cen || debug_ym_cen_p1)
            $fatal(1, "clock enable escaped during baseline-work restore");
    end

    // Both phase accumulators restart from phase zero after the captured
    // post-bootstrap workspace has been reconstructed.
    count_window(756);
    if (v25_count != 80 || ym_count != 27 || ym_p1_count != 13)
        $fatal(1, "restore changed deterministic clock phases");

    $display("PASS sound_clock_restore_tb");
    $finish;
end

initial begin
    #1000000;
    $fatal(1, "timeout");
end

endmodule
