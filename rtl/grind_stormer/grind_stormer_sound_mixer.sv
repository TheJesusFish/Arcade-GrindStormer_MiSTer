// TP-027 routes both YM2151 outputs to one mono path at equal gain.
module grind_stormer_sound_mixer (
    input                     clk,
    input                     reset,
    input                     sample,
    input signed      [15:0]  ym_left,
    input signed      [15:0]  ym_right,
    input                     ym_enable,
    output reg signed [15:0]  mono
);

wire signed [16:0] stereo_sum =
    $signed({ym_left[15], ym_left}) +
    $signed({ym_right[15], ym_right});
wire signed [15:0] mono_average = stereo_sum >>> 1;

always @(posedge clk) begin
    if (reset)
        mono <= 16'sd0;
    else if (sample)
        mono <= ym_enable ? mono_average : 16'sd0;
end

endmodule
