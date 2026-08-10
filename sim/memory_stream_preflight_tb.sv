`timescale 1ns/1ps

module memory_stream_preflight_tb;

localparam [63:0] FOOTER_MAGIC = 64'h4752_4352_4330_3031;

reg clk = 1'b0;
reg reset = 1'b1;
always #5 clk = ~clk;

ddr_if ddr();

reg write_start = 1'b0;
reg read_start = 1'b0;
reg restore_allowed = 1'b0;
wire write_req;
wire [63:0] write_data;
wire read_req;
reg [63:0] read_data = 64'd0;
reg data_ack = 1'b0;
wire query_req;
wire [31:0] chunk_address;
wire [7:0] chunk_select;
wire busy;
wire validation_error;

memory_stream #(
    .COUNT(4),
    .REQUIRED_CHUNKS(4'hf)
) dut (
    .clk              (clk),
    .reset            (reset),
    .ddr              (ddr),
    .write_req        (write_req),
    .write_data       (write_data),
    .data_ack         (data_ack),
    .read_req         (read_req),
    .read_data        (read_data),
    .start_addr       (32'd0),
    .length           (32'd32768),
    .read_start       (read_start),
    .write_start      (write_start),
    .restore_allowed  (restore_allowed),
    .query_req        (query_req),
    .chunk_address    (chunk_address),
    .chunk_select     (chunk_select),
    .busy             (busy),
    .validation_error (validation_error)
);

reg [63:0] memory [0:4095];
reg read_seen = 1'b0;
reg write_seen = 1'b0;
integer i;
integer b;

assign ddr.busy = 1'b0;

always @(posedge clk) begin
    ddr.rdata_ready <= 1'b0;

    if (reset) begin
        ddr.rdata <= 64'd0;
        read_seen <= 1'b0;
        write_seen <= 1'b0;
    end else begin
        if (!ddr.read)
            read_seen <= 1'b0;
        if (!ddr.write)
            write_seen <= 1'b0;

        if (ddr.read && !read_seen) begin
            ddr.rdata <= memory[ddr.addr[14:3]];
            ddr.rdata_ready <= 1'b1;
            read_seen <= 1'b1;
        end

        if (ddr.write && !write_seen) begin
            for (b = 0; b < 8; b = b + 1)
                if (ddr.byteenable[b])
                    memory[ddr.addr[14:3]][b*8 +: 8] <=
                        ddr.wdata[b*8 +: 8];
            write_seen <= 1'b1;
        end
    end
end

function automatic [31:0] client_count;
    input [7:0] select;
    begin
        case (select)
            8'd0: client_count = 32'd2;
            8'd1: client_count = 32'd4;
            8'd2: client_count = 32'd5;
            default: client_count = 32'd3;
        endcase
    end
endfunction

function automatic [1:0] client_width;
    input [7:0] select;
    begin
        case (select)
            8'd0: client_width = 2'd3;
            8'd1: client_width = 2'd3;
            8'd2: client_width = 2'd1;
            default: client_width = 2'd0;
        endcase
    end
endfunction

function automatic [63:0] client_data;
    input [7:0] select;
    input [31:0] address;
    begin
        client_data = 64'ha55a_0000_0000_0000 ^
                      {select, 24'd0, address};
    end
endfunction

function automatic [63:0] crc64_byte;
    input [63:0] crc;
    input [7:0] byte_value;
    integer k;
    reg [63:0] next;
    begin
        next = crc ^ {byte_value, 56'd0};
        for (k = 0; k < 8; k = k + 1)
            next = next[63] ?
                (next << 1) ^ 64'h42f0_e1eb_a9ea_3693 :
                (next << 1);
        crc64_byte = next;
    end
endfunction

function automatic [63:0] crc64_word;
    input [63:0] crc;
    input [63:0] word_value;
    reg [63:0] next;
    begin
        next = crc64_byte(crc, word_value[7:0]);
        next = crc64_byte(next, word_value[15:8]);
        next = crc64_byte(next, word_value[23:16]);
        next = crc64_byte(next, word_value[31:24]);
        next = crc64_byte(next, word_value[39:32]);
        next = crc64_byte(next, word_value[47:40]);
        next = crc64_byte(next, word_value[55:48]);
        crc64_word = crc64_byte(next, word_value[63:56]);
    end
endfunction

reg request_armed = 1'b1;
reg pending = 1'b0;
reg [1:0] pending_kind = 2'd0;
reg [2:0] pending_delay = 3'd0;
reg [7:0] pending_select = 8'd0;
reg [31:0] pending_address = 32'd0;
reg [63:0] pending_data = 64'd0;
reg [7:0] latency_lfsr = 8'h5a;
reg [63:0] restored [0:3][0:7];
integer architectural_writes = 0;
integer metadata_writes = 0;
wire any_client_request = query_req || write_req || read_req;

always @(posedge clk) begin
    data_ack <= 1'b0;
    latency_lfsr <= {latency_lfsr[6:0],
                     latency_lfsr[7] ^ latency_lfsr[5] ^
                     latency_lfsr[4] ^ latency_lfsr[3]};

    if (reset) begin
        request_armed <= 1'b1;
        pending <= 1'b0;
        pending_delay <= 3'd0;
        read_data <= 64'd0;
    end else begin
        if (!any_client_request)
            request_armed <= 1'b1;

        if (pending) begin
            if (pending_delay == 0) begin
                case (pending_kind)
                    2'd0: read_data <= {
                        pending_select,
                        22'd0,
                        client_width(pending_select),
                        client_count(pending_select)
                    };
                    2'd1: begin
                        restored[pending_select][pending_address] <=
                            pending_data;
                        if (pending_select >= 2)
                            architectural_writes <=
                                architectural_writes + 1;
                        else
                            metadata_writes <= metadata_writes + 1;
                    end
                    default: read_data <= client_data(
                        pending_select, pending_address);
                endcase
                data_ack <= 1'b1;
                pending <= 1'b0;
            end else begin
                pending_delay <= pending_delay - 1'b1;
            end
        end else if (request_armed && any_client_request) begin
            request_armed <= 1'b0;
            pending <= 1'b1;
            pending_delay <= {1'b0, latency_lfsr[1:0]};
            pending_select <= chunk_select;
            pending_address <= chunk_address;
            pending_data <= write_data;
            if (query_req)
                pending_kind <= 2'd0;
            else if (write_req)
                pending_kind <= 2'd1;
            else
                pending_kind <= 2'd2;
        end
    end
end

task automatic run_save;
    begin
        @(posedge clk);
        write_start <= 1'b1;
        @(posedge clk);
        write_start <= 1'b0;
        wait (busy);
        wait (!busy);
        repeat (4) @(posedge clk);
    end
endtask

task automatic run_restore;
    begin
        @(posedge clk);
        read_start <= 1'b1;
        @(posedge clk);
        read_start <= 1'b0;
        wait (busy);
        wait (!busy);
        repeat (4) @(posedge clk);
    end
endtask

integer footer_index;
reg [63:0] saved_last_payload;
reg [63:0] saved_descriptor;
reg [63:0] saved_footer_crc;
reg [63:0] rebuilt_crc;

initial begin
    ddr.rdata = 64'd0;
    ddr.rdata_ready = 1'b0;
    for (i = 0; i < 4096; i = i + 1)
        memory[i] = 64'd0;
    for (i = 0; i < 4; i = i + 1)
        for (b = 0; b < 8; b = b + 1)
            restored[i][b] = 64'd0;

    repeat (5) @(posedge clk);
    reset <= 1'b0;
    repeat (2) @(posedge clk);

    run_save();

    footer_index = -1;
    for (i = 1; i < 4096; i = i + 1)
        if (memory[i] == FOOTER_MAGIC)
            footer_index = i;

    if (footer_index < 3)
        $fatal(1, "footer marker was not written");
    if (memory[footer_index + 2] != ~64'd0)
        $fatal(1, "footer terminator is missing");
    if (memory[0][31:0] != 32'd1)
        $fatal(1, "change detector was not committed last");

    architectural_writes = 0;
    metadata_writes = 0;
    restore_allowed = 1'b1;
    run_restore();
    if (validation_error)
        $fatal(1, "valid state failed preflight");
    if (architectural_writes != 8)
        $fatal(1, "valid restore wrote %0d architectural words",
               architectural_writes);
    if (restored[2][4][15:0] != client_data(8'd2, 32'd4)[15:0])
        $fatal(1, "16-bit client restore mismatch");
    if (restored[3][2][7:0] != client_data(8'd3, 32'd2)[7:0])
        $fatal(1, "8-bit client restore mismatch");

    architectural_writes = 0;
    metadata_writes = 0;
    restore_allowed = 1'b0;
    run_restore();
    if (!validation_error)
        $fatal(1, "wrong identity was not rejected");
    if (architectural_writes != 0)
        $fatal(1, "wrong identity mutated architectural clients");

    // Preserve byte geometry while changing the declared element width/count,
    // then rebuild the footer. This isolates descriptor validation from CRC.
    saved_descriptor = memory[1];
    saved_footer_crc = memory[footer_index + 1];
    memory[1][31:0] = 32'd4;
    memory[1][33:32] = 2'd2;
    rebuilt_crc = 64'd0;
    for (i = 1; i < footer_index; i = i + 1)
        rebuilt_crc = crc64_word(rebuilt_crc, memory[i]);
    memory[footer_index + 1] = rebuilt_crc;
    architectural_writes = 0;
    metadata_writes = 0;
    restore_allowed = 1'b1;
    run_restore();
    if (!validation_error)
        $fatal(1, "wrong chunk geometry was not rejected");
    if (architectural_writes != 0)
        $fatal(1, "wrong geometry mutated architectural clients");
    memory[1] = saved_descriptor;
    memory[footer_index + 1] = saved_footer_crc;

    saved_last_payload = memory[footer_index - 1];
    memory[footer_index - 1] =
        memory[footer_index - 1] ^ 64'h0000_0000_0000_0001;
    architectural_writes = 0;
    metadata_writes = 0;
    restore_allowed = 1'b1;
    run_restore();
    if (!validation_error)
        $fatal(1, "corrupt payload was not rejected");
    if (architectural_writes != 0)
        $fatal(1, "corrupt payload mutated architectural clients");
    memory[footer_index - 1] = saved_last_payload;

    // A rejected image must not poison a later valid load. Repeat the valid
    // restore to exercise controller re-entry and durable request teardown.
    for (b = 0; b < 2; b = b + 1) begin
        architectural_writes = 0;
        metadata_writes = 0;
        restore_allowed = 1'b1;
        run_restore();
        if (validation_error)
            $fatal(1, "repeat valid restore %0d failed preflight", b);
        if (architectural_writes != 8)
            $fatal(1,
                "repeat valid restore %0d wrote %0d architectural words",
                b, architectural_writes);
    end

    $display("PASS memory_stream_preflight_tb footer=%0d", footer_index);
    $finish;
end

initial begin
    #5000000;
    $fatal(1, "timeout");
end

endmodule
