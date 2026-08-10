// Adapted from MiSTer-devel/Arcade-TaitoF2_MiSTer.
// Chunk descriptors let later builds skip state domains they do not know.
module memory_stream #(
    parameter COUNT = 32,
    parameter [COUNT-1:0] REQUIRED_CHUNKS = 32'h0000_07ff
)
(
    input               clk,
    input               reset,

    ddr_if.to_host      ddr,

    // 8-bit stream interface for reading from memory
    output reg          write_req,
    output reg [63:0]   write_data,
    input               data_ack,

    // 8-bit stream interface for writing to memory
    output reg          read_req,
    input      [63:0]   read_data,

    // Control signals
    input      [31:0]   start_addr,
    input      [31:0]   length,
    input               read_start,
    input               write_start,
    input               restore_allowed,

    output reg          query_req,
    output reg [31:0]   chunk_address,
    output reg  [7:0]   chunk_select,

    output              busy,
    output reg          validation_error
);

    typedef enum
    {
        IDLE,
        READ_MEM_REQ,
        READ_MEM_WAIT,
        READ_DESCRIPTOR_CRC,
        READ_PAYLOAD_CRC,
        READ_STREAM,
        WRITE_GATHER,
        WRITE_MEM_REQ,
        WRITE_PAYLOAD_CRC,
        WRITE_MEM_ISSUE,
        WRITE_MEM_FINAL_REQ,
        WRITE_MEM_FINAL_WAIT,
        WRITE_MEM_WAIT,
        QUERY_GATHER_FIRST,
        QUERY_GATHER_NEXT,
        QUERY_GATHER_WAIT,
        QUERY_SCATTER_WAIT,
        READ_HEADER,
        READ_HEADER_WAIT,
        WRITE_HEADER_SIZE,
        WRITE_HEADER_SIZE_WAIT,
        WRITE_HEADER_CHANGE,
        WRITE_HEADER_CHANGE_WAIT,
        WRITE_FOOTER_MARKER_REQ,
        WRITE_FOOTER_MARKER_WAIT,
        WRITE_FOOTER_CRC_REQ,
        WRITE_FOOTER_CRC_WAIT,
        READ_FOOTER_CRC_REQ,
        READ_FOOTER_CRC_WAIT,
        READ_FOOTER_END_REQ,
        READ_FOOTER_END_WAIT,
        RESTORE_DECIDE
    } state_t;

    state_t state;

    assign busy = state != IDLE;

    localparam CHUNK_BITS = $clog2(COUNT);

    function automatic [2:0] word_end_for_width;
        input [1:0] width;
        begin
            case (width)
                2'd0: word_end_for_width = 3'd7;
                2'd1: word_end_for_width = 3'd3;
                2'd2: word_end_for_width = 3'd1;
                default: word_end_for_width = 3'd0;
            endcase
        end
    endfunction

    // Counters for reading/writing
    reg [31:0] end_addr;
    reg [31:0] current_addr;
    reg [2:0]  word_counter;  // 0-7 for tracking position in 64-bit word
    reg [63:0] buffer;        // Buffer for read/write operations
    reg [31:0] chunk_remaining;
    reg [3:0]  query_delay;
    reg [1:0]  chunk_width;
    reg [CHUNK_BITS-1:0] chunk_index;
    reg        is_reading;
    reg        preflight;
    reg        validation_failed;
    reg [COUNT-1:0] seen_chunks;

    reg [31:0] next_chunk_address;
    wire chunk_data_ack = data_ack;
    wire [63:0] chunk_read_data = read_data;

    reg [63:0] header_data;
    reg [63:0] descriptor_data;
    reg [63:0] payload_crc;
    reg [63:0] crc_word;
    reg [2:0]  crc_byte_counter;
    wire [31:0] chunk_byte_count = chunk_remaining << chunk_width;
    localparam [63:0] FOOTER_MAGIC = 64'h4752_4352_4330_3031;

    function automatic [63:0] crc64_ecma_byte;
        input [63:0] crc;
        input [7:0] byte_value;
        integer i;
        reg [63:0] next;
        begin
            next = crc ^ {byte_value, 56'd0};
            for (i = 0; i < 8; i = i + 1)
                next = next[63] ?
                    (next << 1) ^ 64'h42f0_e1eb_a9ea_3693 :
                    (next << 1);
            crc64_ecma_byte = next;
        end
    endfunction

    always_comb begin
        chunk_select = 0;
        if (busy) begin
            chunk_select = 8'(chunk_index);
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            ddr.acquire <= 0;
            ddr.read <= 0;
            ddr.write <= 0;
            ddr.burstcnt <= 8'd1; // Initialize to 1 for non-burst operations
            ddr.byteenable <= 8'hFF; // All bytes enabled by default
            write_req <= 0;
            read_req <= 0;
            word_counter <= 0;
            query_req <= 0;
            chunk_index <= 0;
            is_reading <= 0;
            preflight <= 0;
            validation_failed <= 0;
            validation_error <= 0;
            seen_chunks <= 0;
            payload_crc <= 0;
            crc_word <= 0;
            crc_byte_counter <= 0;
        end
        else begin
            case (state)
                IDLE: begin
                    // Default signals
                    ddr.acquire <= 0;
                    ddr.read <= 0;
                    ddr.write <= 0;
                    ddr.burstcnt <= 8'd1; // Always set to 1 for non-burst operations
                    ddr.byteenable <= 8'hFF; // All bytes enabled by default
                    write_req <= 0;
                    read_req <= 0;
                    chunk_index <= 0;
                    chunk_remaining <= 0;
                    current_addr <= start_addr + 32'd8;
                    end_addr <= start_addr + length;
                    word_counter <= 0;
                    buffer <= 64'h0;

                    // Check for start signals
                    if (read_start) begin
                        state <= READ_HEADER;
                        is_reading <= 1;
                        preflight <= 1;
                        validation_failed <= 0;
                        validation_error <= 0;
                        seen_chunks <= 0;
                        payload_crc <= 0;
                        ddr.acquire <= 1;
                    end else if (write_start) begin
                        state <= READ_HEADER;
                        is_reading <= 0;
                        preflight <= 0;
                        validation_failed <= 0;
                        validation_error <= 0;
                        seen_chunks <= 0;
                        payload_crc <= 0;
                        ddr.acquire <= 1;
                    end
                end

                READ_HEADER: begin
                    if (~ddr.busy) begin
                        ddr.read <= 1;
                        ddr.addr <= start_addr;
                        state <= READ_HEADER_WAIT;
                    end
                end

                READ_HEADER_WAIT: begin
                    if (~ddr.busy) begin
                        ddr.read <= 0;
                        if (ddr.rdata_ready) begin
                            header_data <= ddr.rdata;

                            if (is_reading) begin
                                end_addr <= current_addr + { ddr.rdata[61:32], 2'b00 };
                                if (({ddr.rdata[61:32], 2'b00} < 32'd24) ||
                                    ({ddr.rdata[61:32], 2'b00} > length)) begin
                                    validation_error <= 1;
                                    state <= IDLE;
                                end else begin
                                    state <= READ_MEM_REQ;
                                end
                            end else begin
                                state <= QUERY_GATHER_FIRST;
                            end
                        end
                    end
                end

                // Main_MiSTer polls the low change-detector word. Commit the
                // size first and update the detector only after that write
                // has completed, so it cannot flush an incomplete state.
                WRITE_HEADER_SIZE: begin
                    bit [31:0] len;
                    if (~ddr.busy) begin
                        ddr.write <= 1;
                        ddr.addr <= start_addr;
                        ddr.byteenable <= 8'hf0;
                        len = current_addr - (start_addr + 32'd8);
                        ddr.wdata[63:32] <= { 2'b00, len[31:2] };
                        state <= WRITE_HEADER_SIZE_WAIT;
                    end
                end

                WRITE_HEADER_SIZE_WAIT: begin
                    if (~ddr.busy) begin
                        ddr.write <= 0;
                        ddr.byteenable <= 8'hff;
                        state <= WRITE_HEADER_CHANGE;
                    end
                end

                WRITE_HEADER_CHANGE: begin
                    if (~ddr.busy) begin
                        ddr.write <= 1;
                        ddr.addr <= start_addr;
                        ddr.byteenable <= 8'h0f;
                        ddr.wdata[31:0] <= header_data[31:0] + 32'd1;
                        state <= WRITE_HEADER_CHANGE_WAIT;
                    end
                end

                WRITE_HEADER_CHANGE_WAIT: begin
                    if (~ddr.busy) begin
                        ddr.write <= 0;
                        ddr.byteenable <= 8'hff;
                        state <= IDLE;
                    end
                end

                READ_MEM_REQ: begin
                    if (current_addr >= end_addr) begin
                        if (preflight)
                            validation_error <= 1;
                        state <= IDLE;
                    end else if (!ddr.busy) begin
                        ddr.addr <= current_addr & 32'hFFFFFFF8; // Align to 8-byte boundary
                        current_addr <= current_addr + 8;
                        ddr.read <= 1;
                        state <= READ_MEM_WAIT;
                    end
                end

                READ_MEM_WAIT: begin
                    if (!ddr.busy) begin
                        ddr.read <= 0;
                        if (ddr.rdata_ready) begin
                            buffer <= ddr.rdata;
                            if (chunk_remaining == 0) begin
                                if (ddr.rdata == FOOTER_MAGIC) begin
                                    if (preflight)
                                        state <= READ_FOOTER_CRC_REQ;
                                    else
                                        state <= IDLE;
                                end else if (&ddr.rdata[63:56]) begin
                                    if (preflight)
                                        validation_error <= 1;
                                    state <= IDLE;
                                end else begin
                                    descriptor_data <= ddr.rdata;
                                    chunk_remaining <= ddr.rdata[31:0];
                                    chunk_width <= ddr.rdata[33:32];
                                    chunk_index <= ddr.rdata[56+CHUNK_BITS-1:56];
                                    if (preflight) begin
                                        crc_word <= ddr.rdata;
                                        crc_byte_counter <= 0;
                                        state <= READ_DESCRIPTOR_CRC;
                                        if ((ddr.rdata[63:61] != 3'd0) ||
                                            (ddr.rdata[55:34] != 22'd0) ||
                                            (ddr.rdata[31:0] == 32'd0) ||
                                            seen_chunks[
                                                ddr.rdata[
                                                    56+CHUNK_BITS-1:56
                                                ]
                                            ])
                                            validation_failed <= 1;
                                        seen_chunks[
                                            ddr.rdata[
                                                56+CHUNK_BITS-1:56
                                            ]
                                        ] <= 1;
                                    end else begin
                                        write_req <= 1;
                                        query_req <= 1;
                                        query_delay <= 0;
                                        state <= QUERY_SCATTER_WAIT;
                                    end
                                end
                            end else begin
                                if (preflight) begin
                                    crc_word <= ddr.rdata;
                                    crc_byte_counter <= 0;
                                    state <= READ_PAYLOAD_CRC;
                                end else begin
                                    state <= READ_STREAM;
                                end
                            end
                        end
                    end
                end

                READ_DESCRIPTOR_CRC: begin
                    payload_crc <= crc64_ecma_byte(
                        payload_crc, crc_word[7:0]);
                    crc_word <= {8'd0, crc_word[63:8]};
                    if (&crc_byte_counter) begin
                        write_req <= 1;
                        query_req <= 1;
                        query_delay <= 0;
                        state <= QUERY_SCATTER_WAIT;
                    end else begin
                        crc_byte_counter <= crc_byte_counter + 1'b1;
                    end
                end

                READ_PAYLOAD_CRC: begin
                    payload_crc <= crc64_ecma_byte(
                        payload_crc, crc_word[7:0]);
                    crc_word <= {8'd0, crc_word[63:8]};
                    if (&crc_byte_counter) begin
                        state <= READ_STREAM;
                    end else begin
                        crc_byte_counter <= crc_byte_counter + 1'b1;
                    end
                end

                QUERY_SCATTER_WAIT: begin
                    if (chunk_data_ack) begin
                        if (preflight &&
                            ((chunk_read_data[33:0] !=
                              descriptor_data[33:0]) ||
                             (chunk_read_data[63:56] !=
                              {{(8-CHUNK_BITS){1'b0}}, chunk_index})))
                            validation_failed <= 1;
                        query_req <= 0;
                        write_req <= 0;
                        state <= READ_MEM_REQ;
                        next_chunk_address <= 0;
                        word_counter <= 0;
                    end else if (&query_delay) begin
                        if (preflight)
                            validation_failed <= 1;
                        write_req <= 0;
                        query_req <= 0;
                        current_addr <= current_addr +
                            ((chunk_byte_count + 32'd7) & 32'hFFFFFFF8);
                        chunk_remaining <= 0;
                        word_counter <= 0;
                        state <= READ_MEM_REQ;
                    end else begin
                        query_delay <= query_delay + 1;
                    end
                end

                READ_STREAM: begin
                    if (chunk_remaining == 0) begin
                        // Done with all reading
                        state <= READ_MEM_REQ;
                        write_req <= 0;
                        word_counter <= 0;
                    end else begin
                        case(chunk_width)
                            0: case (word_counter)
                                3'd0: write_data[7:0] <= buffer[7:0];
                                3'd1: write_data[7:0] <= buffer[15:8];
                                3'd2: write_data[7:0] <= buffer[23:16];
                                3'd3: write_data[7:0] <= buffer[31:24];
                                3'd4: write_data[7:0] <= buffer[39:32];
                                3'd5: write_data[7:0] <= buffer[47:40];
                                3'd6: write_data[7:0] <= buffer[55:48];
                                3'd7: write_data[7:0] <= buffer[63:56];
                                default: begin end
                            endcase
                            1: case (word_counter)
                                3'd0: write_data[15:0] <= buffer[15:0];
                                3'd1: write_data[15:0] <= buffer[31:16];
                                3'd2: write_data[15:0] <= buffer[47:32];
                                3'd3: write_data[15:0] <= buffer[63:48];
                                default: begin end
                            endcase
                            2: case (word_counter)
                                3'd0: write_data[31:0] <= buffer[31:0];
                                3'd1: write_data[31:0] <= buffer[63:32];
                                default: begin end
                            endcase
                            3: begin
                                write_data[63:0] <= buffer[63:0];
                            end
                        endcase

                        if (preflight && (chunk_index > 1)) begin
                            write_req <= 0;
                            if (word_counter ==
                                word_end_for_width(chunk_width)) begin
                                word_counter <= 0;
                                state <= READ_MEM_REQ;
                            end else begin
                                word_counter <= word_counter + 1;
                            end
                            chunk_remaining <= chunk_remaining - 1;
                            next_chunk_address <= next_chunk_address + 1;
                        end else if (chunk_data_ack & write_req) begin
                            // Advance to next byte
                            if (word_counter ==
                                word_end_for_width(chunk_width)) begin
                                // Need to fetch next word
                                word_counter <= 0;
                                state <= READ_MEM_REQ;
                            end
                            else begin
                                word_counter <= word_counter + 1;
                            end

                            chunk_remaining <= chunk_remaining - 1;
                            next_chunk_address <= chunk_address + 1;
                            write_req <= 0;
                        end else if (~write_req & ~chunk_data_ack) begin
                            write_req <= 1;
                            chunk_address <= next_chunk_address;
                        end
                    end
                end

                QUERY_GATHER_FIRST: begin
                    chunk_index <= 0;
                    read_req <= 1;
                    query_req <= 1;
                    state <= QUERY_GATHER_WAIT;
                    query_delay <= 0;
                end

                QUERY_GATHER_NEXT: begin
                    if ((chunk_index + 1) == COUNT) begin
                        state <= WRITE_FOOTER_MARKER_REQ;
                    end else begin
                        chunk_index <= chunk_index + 1;
                        read_req <= 1;
                        query_req <= 1;
                        state <= QUERY_GATHER_WAIT;
                        query_delay <= 0;
                    end
                end

                QUERY_GATHER_WAIT: begin
                    if (chunk_data_ack) begin
                        buffer<= 0;
                        chunk_remaining <= chunk_read_data[31:0];
                        chunk_width <= chunk_read_data[33:32];
                        buffer[33:0] <= chunk_read_data[33:0];
                        buffer[56+CHUNK_BITS-1:56] <= chunk_index[CHUNK_BITS-1:0];
                        next_chunk_address <= 0;
                        word_counter <= 0;
                        query_req <= 0;
                        read_req <= 0;
                        state <= WRITE_MEM_REQ;
                    end else if (&query_delay) begin
                        state <= QUERY_GATHER_NEXT;
                    end else begin
                        query_delay <= query_delay + 1;
                    end
                end

                WRITE_GATHER: begin
                    // Wait for incoming data
                    if (chunk_remaining == 0) begin
                        // Check if we have partially filled buffer to write
                        if (word_counter != 0) begin
                            state <= WRITE_MEM_REQ;
                        end
                        else begin
                            state <= QUERY_GATHER_NEXT;
                        end
                    end
                    else if (chunk_data_ack & read_req) begin
                        // Store incoming byte in buffer
                        case (chunk_width)
                            0: case (word_counter)
                                3'd0: buffer[7:0] <= chunk_read_data[7:0];
                                3'd1: buffer[15:8] <= chunk_read_data[7:0];
                                3'd2: buffer[23:16] <= chunk_read_data[7:0];
                                3'd3: buffer[31:24] <= chunk_read_data[7:0];
                                3'd4: buffer[39:32] <= chunk_read_data[7:0];
                                3'd5: buffer[47:40] <= chunk_read_data[7:0];
                                3'd6: buffer[55:48] <= chunk_read_data[7:0];
                                3'd7: buffer[63:56] <= chunk_read_data[7:0];
                                default: begin end
                            endcase
                            1: case (word_counter)
                                3'd0: buffer[15:0] <= chunk_read_data[15:0];
                                3'd1: buffer[31:16] <= chunk_read_data[15:0];
                                3'd2: buffer[47:32] <= chunk_read_data[15:0];
                                3'd3: buffer[63:48] <= chunk_read_data[15:0];
                                default: begin end
                            endcase
                            2: case (word_counter)
                                3'd0: buffer[31:0] <= chunk_read_data[31:0];
                                3'd1: buffer[63:32] <= chunk_read_data[31:0];
                                default: begin end
                            endcase
                            3: begin
                                buffer[63:0] <= chunk_read_data[63:0];
                            end
                        endcase

                        if (word_counter ==
                            word_end_for_width(chunk_width)) begin
                            // Buffer full, write to memory
                            word_counter <= 0;
                            state <= WRITE_MEM_REQ;
                        end
                        else begin
                            word_counter <= word_counter + 1;
                        end

                        next_chunk_address <= chunk_address + 1;
                        chunk_remaining <= chunk_remaining - 1;
                        read_req <= 0;
                    end else if (~read_req & ~chunk_data_ack) begin
                        chunk_address <= next_chunk_address;
                        read_req <= 1;
                    end
                end

                WRITE_MEM_REQ: begin
                    if (current_addr >= end_addr) begin
                        state <= IDLE;
                    end else if (!ddr.busy) begin
                        crc_word <= buffer;
                        crc_byte_counter <= 0;
                        state <= WRITE_PAYLOAD_CRC;
                    end
                end

                WRITE_PAYLOAD_CRC: begin
                    payload_crc <= crc64_ecma_byte(
                        payload_crc, crc_word[7:0]);
                    crc_word <= {8'd0, crc_word[63:8]};
                    if (&crc_byte_counter) begin
                        state <= WRITE_MEM_ISSUE;
                    end else begin
                        crc_byte_counter <= crc_byte_counter + 1'b1;
                    end
                end

                WRITE_MEM_ISSUE: begin
                    if (!ddr.busy) begin
                        ddr.addr <= current_addr & 32'hFFFFFFF8; // Align to 8-byte boundary
                        current_addr <= current_addr + 8;
                        ddr.wdata <= buffer;
                        ddr.write <= 1;
                        state <= WRITE_MEM_WAIT;
                    end
                end

                WRITE_FOOTER_MARKER_REQ: begin
                    if (current_addr >= end_addr) begin
                        state <= IDLE;
                    end else if (!ddr.busy) begin
                        ddr.addr <= current_addr & 32'hffff_fff8;
                        ddr.wdata <= FOOTER_MAGIC;
                        ddr.write <= 1;
                        current_addr <= current_addr + 32'd8;
                        state <= WRITE_FOOTER_MARKER_WAIT;
                    end
                end

                WRITE_FOOTER_MARKER_WAIT: begin
                    if (!ddr.busy) begin
                        ddr.write <= 0;
                        state <= WRITE_FOOTER_CRC_REQ;
                    end
                end

                WRITE_FOOTER_CRC_REQ: begin
                    if (current_addr >= end_addr) begin
                        state <= IDLE;
                    end else if (!ddr.busy) begin
                        ddr.addr <= current_addr & 32'hffff_fff8;
                        ddr.wdata <= payload_crc;
                        ddr.write <= 1;
                        current_addr <= current_addr + 32'd8;
                        state <= WRITE_FOOTER_CRC_WAIT;
                    end
                end

                WRITE_FOOTER_CRC_WAIT: begin
                    if (!ddr.busy) begin
                        ddr.write <= 0;
                        state <= WRITE_MEM_FINAL_REQ;
                    end
                end

                WRITE_MEM_FINAL_REQ: begin
                    if (current_addr >= end_addr) begin
                        state <= IDLE;
                    end else if (!ddr.busy) begin
                        ddr.addr <= current_addr & 32'hFFFFFFF8; // Align to 8-byte boundary
                        ddr.wdata <= ~64'd0;
                        ddr.write <= 1;
                        current_addr <= current_addr + 32'd8;
                        state <= WRITE_MEM_FINAL_WAIT;
                    end
                end

                WRITE_MEM_FINAL_WAIT: begin
                    if (!ddr.busy) begin
                        ddr.write <= 0;
                        state <= WRITE_HEADER_SIZE;
                    end
                end


                WRITE_MEM_WAIT: begin
                    if (!ddr.busy) begin
                        ddr.write <= 0;
                        if (chunk_remaining == 0) begin
                            word_counter <= 0;
                            state <= QUERY_GATHER_NEXT;
                        end
                        else begin
                            state <= WRITE_GATHER;
                            buffer <= 64'h0;
                        end
                    end
                end

                READ_FOOTER_CRC_REQ: begin
                    if (current_addr >= end_addr) begin
                        validation_error <= 1;
                        state <= IDLE;
                    end else if (!ddr.busy) begin
                        ddr.addr <= current_addr & 32'hffff_fff8;
                        current_addr <= current_addr + 32'd8;
                        ddr.read <= 1;
                        state <= READ_FOOTER_CRC_WAIT;
                    end
                end

                READ_FOOTER_CRC_WAIT: begin
                    if (!ddr.busy) begin
                        ddr.read <= 0;
                        if (ddr.rdata_ready) begin
                            if (ddr.rdata != payload_crc)
                                validation_failed <= 1;
                            state <= READ_FOOTER_END_REQ;
                        end
                    end
                end

                READ_FOOTER_END_REQ: begin
                    if (current_addr >= end_addr) begin
                        validation_error <= 1;
                        state <= IDLE;
                    end else if (!ddr.busy) begin
                        ddr.addr <= current_addr & 32'hffff_fff8;
                        current_addr <= current_addr + 32'd8;
                        ddr.read <= 1;
                        state <= READ_FOOTER_END_WAIT;
                    end
                end

                READ_FOOTER_END_WAIT: begin
                    if (!ddr.busy) begin
                        ddr.read <= 0;
                        if (ddr.rdata_ready) begin
                            if ((ddr.rdata != ~64'd0) ||
                                (current_addr != end_addr) ||
                                (seen_chunks != REQUIRED_CHUNKS))
                                validation_failed <= 1;
                            state <= RESTORE_DECIDE;
                        end
                    end
                end

                RESTORE_DECIDE: begin
                    if (!validation_failed && restore_allowed) begin
                        preflight <= 0;
                        current_addr <= start_addr + 32'd8;
                        chunk_remaining <= 0;
                        word_counter <= 0;
                        write_req <= 0;
                        query_req <= 0;
                        state <= READ_MEM_REQ;
                    end else begin
                        validation_error <= 1;
                        state <= IDLE;
                    end
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
