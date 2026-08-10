`timescale 1ns/1ps

module savestate_ui_tb;

reg clk = 1'b0;
always #5 clk = ~clk;

reg [10:0] ps2_key = 11'd0;
reg allow_ss = 1'b1;
reg joySS = 1'b0;
reg joyRight = 1'b0;
reg joyLeft = 1'b0;
reg joyDown = 1'b0;
reg joyUp = 1'b0;
reg [1:0] status_slot = 2'd0;
reg autoincslot = 1'b0;
reg [1:0] OSD_saveload = 2'd0;

wire       ss_save;
wire       ss_load;
wire       ss_info_req;
wire [7:0] ss_info;
wire       statusUpdate;
wire [1:0] selected_slot;

savestate_ui #(.INFO_TIMEOUT_BITS(25)) dut (
    .clk           (clk),
    .ps2_key       (ps2_key),
    .allow_ss      (allow_ss),
    .joySS         (joySS),
    .joyRight      (joyRight),
    .joyLeft       (joyLeft),
    .joyDown       (joyDown),
    .joyUp         (joyUp),
    .joyStart      (1'b0),
    .joyRewind     (1'b0),
    .rewindEnable  (1'b0),
    .status_slot   (status_slot),
    .autoincslot   (autoincslot),
    .OSD_saveload  (OSD_saveload),
    .ss_save       (ss_save),
    .ss_load       (ss_load),
    .ss_info_req   (ss_info_req),
    .ss_info       (ss_info),
    .statusUpdate  (statusUpdate),
    .selected_slot (selected_slot)
);

task automatic pulse_gamepad;
    input integer control;
    begin
        @(negedge clk);
        joySS = 1'b1;
        case (control)
            0: joyRight = 1'b1;
            1: joyLeft = 1'b1;
            2: joyDown = 1'b1;
            default: joyUp = 1'b1;
        endcase
        @(posedge clk);
        #1;
        @(negedge clk);
        joyRight = 1'b0;
        joyLeft = 1'b0;
        joyDown = 1'b0;
        joyUp = 1'b0;
        joySS = 1'b0;
        @(posedge clk);
        #1;
    end
endtask

task automatic ps2_event;
    input [7:0] code;
    input       pressed;
    begin
        @(negedge clk);
        ps2_key[10] = ~ps2_key[10];
        ps2_key[9] = pressed;
        ps2_key[7:0] = code;
        @(posedge clk);
        #1;
    end
endtask

task automatic osd_pulse;
    input [1:0] request;
    begin
        @(negedge clk);
        OSD_saveload = request;
        @(posedge clk);
        #1;
        @(negedge clk);
        OSD_saveload = 2'd0;
        @(posedge clk);
        #1;
    end
endtask

integer i;
initial begin
    repeat (4) @(posedge clk);
    #1;
    if (selected_slot != 2'd0)
        $fatal(1, "initial slot is not zero");

    // Gamepad slot selection saturates at both ends.
    pulse_gamepad(0);
    if (selected_slot != 2'd1)
        $fatal(1, "right did not select slot 1");
    pulse_gamepad(0);
    pulse_gamepad(0);
    pulse_gamepad(0);
    if (selected_slot != 2'd3)
        $fatal(1, "right did not saturate at slot 3");
    pulse_gamepad(1);
    if (selected_slot != 2'd2)
        $fatal(1, "left did not select slot 2");

    // Model hps_io accepting statusUpdate/status_in from the local selector.
    @(negedge clk);
    status_slot = selected_slot;
    repeat (2) @(posedge clk);

    // External OSD slot status reaches every slot.
    for (i = 0; i < 4; i = i + 1) begin
        @(negedge clk);
        status_slot = i[1:0];
        @(posedge clk);
        #1;
        if (selected_slot != i[1:0] || !statusUpdate)
            $fatal(1, "OSD slot %0d did not propagate", i);
    end

    // Slot 3 save wraps to slot 0 when autoincrement is enabled.
    autoincslot = 1'b1;
    pulse_gamepad(2);
    if (selected_slot != 2'd0)
        $fatal(1, "gamepad save did not wrap slot 3 to slot 0");
    @(negedge clk);
    status_slot = selected_slot;
    repeat (2) @(posedge clk);

    // OSD save increments; OSD load preserves the selected slot.
    @(negedge clk);
    OSD_saveload = 2'b01;
    @(posedge clk);
    #1;
    if (!ss_save || ss_load || selected_slot != 2'd1)
        $fatal(1, "OSD save/autoincrement contract failed");
    @(negedge clk);
    OSD_saveload = 2'b00;
    @(posedge clk);
    #1;

    @(negedge clk);
    OSD_saveload = 2'b10;
    @(posedge clk);
    #1;
    if (!ss_load || ss_save || selected_slot != 2'd1)
        $fatal(1, "OSD load changed slot or missed pulse");
    @(negedge clk);
    OSD_saveload = 2'b00;
    @(posedge clk);
    #1;

    // F1..F4 select all four slots and load without Alt.
    autoincslot = 1'b0;
    ps2_event(8'h05, 1'b1);
    if (!ss_load || selected_slot != 2'd0)
        $fatal(1, "F1 load contract failed");
    ps2_event(8'h06, 1'b1);
    if (!ss_load || selected_slot != 2'd1)
        $fatal(1, "F2 load contract failed");
    ps2_event(8'h04, 1'b1);
    if (!ss_load || selected_slot != 2'd2)
        $fatal(1, "F3 load contract failed");
    ps2_event(8'h0c, 1'b1);
    if (!ss_load || selected_slot != 2'd3)
        $fatal(1, "F4 load contract failed");

    // Alt+F2 produces save rather than load.
    ps2_event(8'h11, 1'b1);
    ps2_event(8'h06, 1'b1);
    if (!ss_save || ss_load || selected_slot != 2'd1)
        $fatal(1, "Alt+F2 save contract failed");
    ps2_event(8'h11, 1'b0);

    // Requests are suppressed while the surrounding controller is active.
    allow_ss = 1'b0;
    @(negedge clk);
    OSD_saveload = 2'b01;
    @(posedge clk);
    #1;
    if (ss_save || ss_load)
        $fatal(1, "request escaped allow_ss gate");
    @(negedge clk);
    OSD_saveload = 2'b00;
    allow_ss = 1'b1;
    @(posedge clk);
    #1;

    $display("PASS savestate_ui_tb");
    $finish;
end

endmodule
