`timescale 1ns/1ps

module v25_debug_coverage_tb;

reg clk = 1'b0;
reg reset_n = 1'b0;
reg clock_enable = 1'b1;
reg bus_write_start = 1'b0;
reg [19:0] bus_write_addr = 20'd0;
reg [7:0] bus_write_data = 8'd0;
reg [31:0] control = 32'd0;
wire [127:0] probe;

always #5 clk = ~clk;

grind_stormer_v25_debug_trace #(
    .CE_PER_EPOCH(1000),
    .SILENCE_CE(3000)
) dut (
    .clk(clk),
    .reset_n(reset_n),
    .clock_enable(clock_enable),
    .instruction_done(1'b1),
    .debug_pc(20'ha0100),
    .active_bank(3'd0),
    .arch_flags(16'h0200),
    .arch_cx(16'd0),
    .arch_ix(16'd0),
    .halted(1'b0),
    .fault(1'b0),
    .timer2_pending(1'b0),
    .timer2_irq_request(1'b0),
    .irq_entry_pending(1'b0),
    .tmic0_reg(8'd0),
    .ispr_reg(8'd0),
    .escape_state(5'd0),
    .escape_opcode(8'd0),
    .bus_write_start(bus_write_start),
    .bus_write_addr(bus_write_addr),
    .bus_write_data(bus_write_data),
    .bank_commit(1'b0),
    .bank_cause(3'd0),
    .bank_source(3'd0),
    .bank_target(3'd0),
    .bank_psw(16'd0),
    .bank_ip(16'd0),
    .restore_event(1'b0),
    .control(control),
    .probe(probe)
);

task automatic write_byte(
    input [19:0] address,
    input [7:0] data
);
begin
    @(negedge clk);
    bus_write_addr = address;
    bus_write_data = data;
    bus_write_start = 1'b1;
    @(negedge clk);
    bus_write_start = 1'b0;
end
endtask

task automatic write_ym(
    input [7:0] address,
    input [7:0] data
);
begin
    write_byte(20'h00000, address);
    write_byte(20'h00001, data);
end
endtask

integer channel;
integer operator_index;
initial begin
    repeat (3) @(negedge clk);
    reset_n = 1'b1;
    repeat (2) @(negedge clk);
    control[0] = 1'b1;
    repeat (2) @(negedge clk);

    for (channel = 0; channel < 8; channel = channel + 1) begin
        write_ym(8'h08, 8'h78 | channel[7:0]);
        write_ym(8'h08, channel[7:0]);
        for (
            operator_index = 0;
            operator_index < 4;
            operator_index = operator_index + 1
        ) begin
            write_ym(
                8'h40 | (operator_index[7:0] << 3) | channel[7:0],
                8'h55
            );
        end
    end

    control[23:20] = 4'd9;
    repeat (2) @(negedge clk);
    if (probe[127:112] !== 16'hd259)
        $fatal(1, "coverage page marker mismatch: %h", probe[127:112]);
    if (probe[7:0] !== 8'hff)
        $fatal(1, "key-on channel mask mismatch: %h", probe[7:0]);
    if (probe[15:8] !== 8'hff)
        $fatal(1, "key-off channel mask mismatch: %h", probe[15:8]);
    if (probe[47:16] !== 32'hffffffff)
        $fatal(1, "keyed-operator mask mismatch: %h", probe[47:16]);
    if (probe[79:48] !== 32'hffffffff)
        $fatal(
            1,
            "programmed-operator mask mismatch: %h",
            probe[79:48]
        );

    $display("PASS v25_debug_coverage_tb: cumulative YM coverage masks");
    $finish;
end

endmodule
