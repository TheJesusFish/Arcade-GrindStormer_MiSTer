// Keep corresponding words from TP-027's two 1 MiB bitplane halves adjacent
// in physical SDRAM. A lower/upper pair then shares one JTFrame cache burst.
module grind_stormer_gfx_repack (
    input      [21:0] logical_addr,
    output     [21:0] physical_addr
);

assign physical_addr = {2'b00, logical_addr[18:0], logical_addr[19]};

endmodule
