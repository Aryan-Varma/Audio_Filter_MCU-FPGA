`timescale 1ns / 1ps

module input_job_fifo #(
    parameter DATA_WIDTH = 16,
    parameter FIFO_DEPTH = 256,    // Holds up to 2 full blocks (128 samples each)
    parameter ADDR_WIDTH = 8
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   flush,      // Clears FIFO on stream_reset

    // Write Port (From packet_parser)
    input  wire                   wr_en,
    input  wire [DATA_WIDTH-1:0]  wr_data,
    output wire                   full,

    // Read Port (To scheduler)
    input  wire                   rd_en,
    output reg  [DATA_WIDTH-1:0]  rd_data,
    output wire                   empty,
    output reg  [ADDR_WIDTH:0]    count       // Current number of samples in FIFO
);

    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;

    assign full  = (count == FIFO_DEPTH);
    assign empty = (count == 0);

    // FIFO Pointers and Level Counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {ADDR_WIDTH{1'b0}};
            rd_ptr <= {ADDR_WIDTH{1'b0}};
            count  <= {(ADDR_WIDTH+1){1'b0}};
        end else if (flush) begin
            wr_ptr <= {ADDR_WIDTH{1'b0}};
            rd_ptr <= {ADDR_WIDTH{1'b0}};
            count  <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            case ({wr_en && !full, rd_en && !empty})
                2'b10: begin
                    wr_ptr <= wr_ptr + 1'b1;
                    count  <= count + 1'b1;
                end
                2'b01: begin
                    rd_ptr <= rd_ptr + 1'b1;
                    count  <= count - 1'b1;
                end
                2'b11: begin
                    wr_ptr <= wr_ptr + 1'b1;
                    rd_ptr <= rd_ptr + 1'b1;
                    // Count stays identical
                end
                default: ;
            endcase
        end
    end

    // Synchronous Write Port
    always @(posedge clk) begin
        if (wr_en && !full) begin
            mem[wr_ptr] <= wr_data;
        end
    end

    // Synchronous Read Port
    always @(posedge clk) begin
        if (rd_en && !empty) begin
            rd_data <= mem[rd_ptr];
        end
    end

endmodule