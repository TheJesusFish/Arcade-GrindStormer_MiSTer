derive_pll_clocks
derive_clock_uncertainty

create_generated_clock -name SDRAM_CLK -source \
    [get_pins {emu|pll|raizingpll_inst|altera_pll_i|general[5].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 1 \
    [get_ports SDRAM_CLK]

# joy_db15 captures its serial input on JCLOCKS[4]. JTFRAME_SDRAM96 selects
# counter bit 4, so this fabric clock is exactly clk_sys / 32.
create_generated_clock -name DB15_JOY_CLK -source \
    [get_pins {emu|u_joymux|u_db15|JCLOCKS[0]|clk}] \
    -divide_by 32 \
    [get_pins {emu|u_joymux|u_db15|JCLOCKS[4]|q}]

set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to [get_clocks {emu|pll|raizingpll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to [get_clocks {emu|pll|raizingpll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] -hold -end 2

# The restored shell uses the Raizing PLL instance. Keep SDRAM/game clocks
# related and cut unrelated framework, audio, video, and HPS clock domains.
set_clock_groups -exclusive \
    -group [get_clocks {emu|pll|raizingpll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk emu|pll|raizingpll_inst|altera_pll_i|general[5].gpll~PLL_OUTPUT_COUNTER|divclk SDRAM_CLK}] \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {sysmem|fpga_interfaces|clocks_resets|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

# SDRAM timing constraints for the inlined JTFrame/MiSTer hierarchy.
set_multicycle_path -setup -end -from [get_keepers {SDRAM_DQ[*]}] -to [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|dout[*]}] 2
set_multicycle_path -hold  -end -from [get_keepers {SDRAM_DQ[*]}] -to [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|dout[*]}] 2
set_multicycle_path -setup -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|dq_pad[*]}] -to [get_keepers {SDRAM_DQ[*]}] 2
set_multicycle_path -hold  -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|dq_pad[*]}] -to [get_keepers {SDRAM_DQ[*]}] 2
set_multicycle_path -setup -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|sdram_a[12]}] -to [get_keepers {SDRAM_DQMH}] 2
set_multicycle_path -hold  -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|sdram_a[12]}] -to [get_keepers {SDRAM_DQMH}] 2
set_multicycle_path -setup -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|sdram_a[11]}] -to [get_keepers {SDRAM_DQML}] 2
set_multicycle_path -hold  -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|sdram_a[11]}] -to [get_keepers {SDRAM_DQML}] 2

# The compact V25 advances only when its exact 10 MHz enable is asserted.
# At least nine 94.5 MHz clocks separate enables and every sequential element
# inside u_cpu is gated by that enable. Keep wrapper and device buses outside
# this exception so they remain single-cycle constrained.
set v25_cpu_keepers [get_keepers {emu:emu|grind_stormer_game:u_game|grind_stormer_sound:u_sound|grind_stormer_v25_cpu:u_v25|grind_stormer_z8086:u_cpu|*}]
set_multicycle_path -setup -from $v25_cpu_keepers -to $v25_cpu_keepers 5
set_multicycle_path -hold  -from $v25_cpu_keepers -to $v25_cpu_keepers 4

# The skeleton raster advances once every 14 master clocks (94.5 / 14 =
# 6.75 MHz). Constrain only its registered video outputs to that cadence.
set_multicycle_path -setup -end -from [get_clocks {emu|pll|raizingpll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to [get_keepers {emu:emu|grind_stormer_game:u_game|red[*] emu:emu|grind_stormer_game:u_game|green[*] emu:emu|grind_stormer_game:u_game|blue[*] emu:emu|grind_stormer_game:u_game|HS emu:emu|grind_stormer_game:u_game|VS}] 14
set_multicycle_path -hold -end -from [get_clocks {emu|pll|raizingpll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to [get_keepers {emu:emu|grind_stormer_game:u_game|red[*] emu:emu|grind_stormer_game:u_game|green[*] emu:emu|grind_stormer_game:u_game|blue[*] emu:emu|grind_stormer_game:u_game|HS emu:emu|grind_stormer_game:u_game|VS}] 13

# The object-line FSM latches scroll_flip_latched and the initial old_y in
# ST_IDLE, and updates old_y only in ST_DESC_PROCESS. The shortest route back to
# the next ST_DESC_PROCESS is DECIDE->CAPTURE0->WAIT1->CAPTURE1->WAIT2->CAPTURE2
# ->WAIT3->CAPTURE3->PROCESS, nine clocks; scroll_flip_latched is stable for the
# whole build pass. Claim two, which both trivially satisfy.
# desc_y is deliberately NOT included: ST_DESC_CAPTURE3 writes it and the very
# next state consumes it, so that path is honestly single-cycle.
set obj_slow [get_keepers {emu:emu|grind_stormer_game:u_game|grind_stormer_gp9001_video:u_video|grind_stormer_gp9001_object_line:u_object|old_y[*] \
    emu:emu|grind_stormer_game:u_game|grind_stormer_gp9001_video:u_video|grind_stormer_gp9001_object_line:u_object|scroll_flip_latched[*] \
    emu:emu|grind_stormer_game:u_game|grind_stormer_gp9001_video:u_video|grind_stormer_gp9001_object_line:u_object|scrolls_latched[*]}]
set obj_hits [get_keepers {emu:emu|grind_stormer_game:u_game|grind_stormer_gp9001_video:u_video|grind_stormer_gp9001_object_line:u_object|process_hits_line*}]
set_multicycle_path -setup -from $obj_slow -to $obj_hits 2
set_multicycle_path -hold  -from $obj_slow -to $obj_hits 1

# jtframe_reset drives game_rst from negedge clk_rom (jtframe_reset.v:88), so its
# loads get half a period. It is held for GAME_RSTW=8 shift steps and changes at
# most once per reset event, so two cycles is a conservative claim.
set game_rst_reg [get_keepers {emu:emu|jtframe_board:u_board|jtframe_reset:u_reset|game_rst}]
set_multicycle_path -setup -from $game_rst_reg 2
set_multicycle_path -hold  -from $game_rst_reg 1

# Every register in the hq2x blender advances on ce_x4i. sys/scandoubler.v
# places it at pc_in == pixsz4, pixsz2, pixsz2+pixsz4 and pixsz; with pxl_cen
# at one clock in fourteen (grind_stormer_game.sv:1387) that is 3, 7, 10 and
# 14, so the blender gets at least three master clocks between updates. Does
# not hold before pixsz is first measured, which is display-only and
# self-clears. Scoped to blender-internal paths so the other scandoubler
# enables stay honest.
set hq2x_keepers [get_keepers {*|Hq2x:Hq2x|Blend:blender|*}]
set_multicycle_path -setup -from $hq2x_keepers -to $hq2x_keepers 3
set_multicycle_path -hold  -from $hq2x_keepers -to $hq2x_keepers 2

# JTFrame framework exceptions.
set_false_path -to [get_keepers {audio_out:audio_out|cl1[*]}]
set_false_path -to [get_keepers {audio_out:audio_out|cr1[*]}]
set_false_path -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_reset:u_reset|rst_rom[0]}] -to [get_keepers {emu:emu|jtframe_board:u_board|jtframe_reset:u_reset|rst_rom_sync}]
set_false_path -to emu:emu|jtframe_board:u_board|jtframe_reset:u_reset|rst_req_sync[0]
set_false_path -from FB_EN
set_false_path -to deb_osd[0]
set_false_path -from emu:emu|jtframe_board:u_board|jtframe_led:u_led|led
set_false_path -to [get_keepers {*altera_std_synchronizer:*|din_s1}]
