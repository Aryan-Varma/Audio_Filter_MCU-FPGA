`timescale 1ns / 1ps

module result_fifo #(
    parameter DATA_WIDTH = 16,
    parameter FIFO_DEPTH = 512,    // 512 bytes = 256 samples = two 64-frame blocks
    parameter ADDR_WIDTH = 9
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   flush,

    // Write Port: 16-bit word from reduction_saturate
    input  wire                   sample_valid,
    input  wire [DATA_WIDTH-1:0]  sample_data,

    // Read Port: 8-bit byte to packet_parser / SPI transmitter
    input  wire                   byte_rd_en,
    output wire [7:0]             byte_rd_data,
    output wire                   has_full_block, // High if >= 256 bytes (64 frames) ready
    output reg  [ADDR_WIDTH:0]    byte_count
);

    reg [7:0]            byte_mem [0:FIFO_DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_byte_ptr;
    reg [ADDR_WIDTH-1:0] rd_byte_ptr;

    assign byte_rd_data   = byte_mem[rd_byte_ptr];
    assign has_full_block = (byte_count >= 9'd256); // 64 frames * 4 bytes = 256 bytes

    // Synchronous Write: unpacks 16-bit sample into 2 consecutive bytes (Little-Endian)
    always @(posedge clk) begin
        if (sample_valid && (byte_count < FIFO_DEPTH - 1)) begin
            byte_mem[wr_byte_ptr]        <= sample_data[7:0];  // Low byte
            byte_mem[wr_byte_ptr + 1'b1] <= sample_data[15:8]; // High byte
        end
    end

    // Pointers and Count Maintenance
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_byte_ptr <= {ADDR_WIDTH{1'b0}};
            rd_byte_ptr <= {ADDR_WIDTH{1'b0}};
            byte_count  <= {(ADDR_WIDTH+1){1'b0}};
        end else if (flush) begin
            wr_byte_ptr <= {ADDR_WIDTH{1'b0}};
            rd_byte_ptr <= {ADDR_WIDTH{1'b0}};
            byte_count  <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            case ({sample_valid && (byte_count < FIFO_DEPTH - 1), byte_rd_en && (byte_count > 0)})
                2'b10: begin // Wrote 2 bytes (1 sample)
                    wr_byte_ptr <= wr_byte_ptr + 2'd2;
                    byte_count  <= byte_count + 2'd2;
                end
                2'b01: begin // Read 1 byte
                    rd_byte_ptr <= rd_byte_ptr + 1'b1;
                    byte_count  <= byte_count - 1'b1;
                end
                2'b11: begin // Wrote 2 bytes, read 1 byte -> net +1 byte
                    wr_byte_ptr <= wr_byte_ptr + 2'd2;
                    rd_byte_ptr <= rd_byte_ptr + 1'b1;
                    byte_count  <= byte_count + 1'b1;
                end
                default: ;
            endcase
        end
    end

endmodule