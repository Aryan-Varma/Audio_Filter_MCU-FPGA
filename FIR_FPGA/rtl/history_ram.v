`timescale 1ns / 1ps

module history_ram #(
    parameter DATA_WIDTH = 16,     // 16-bit PCM signed audio sample
    parameter MAX_TAPS   = 2048,   // Maximum history length supported
    parameter ADDR_WIDTH = 11      // 2^11 = 2048 entries
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // --- Stream Control ---
    input  wire                   stream_reset,   // Synchronous flush on RESET_STREAM
    output reg                    busy,           // High while memory is zeroing

    // --- Write Interface (Stores newly arrived samples) ---
    input  wire                   wr_en,          // Write enable
    input  wire                   wr_channel,     // 0 = Left Channel, 1 = Right Channel
    input  wire [ADDR_WIDTH-1:0]  wr_addr,        // Current circular head address
    input  wire [DATA_WIDTH-1:0]  wr_data,        // New incoming PCM sample

    // --- Read Interface (Supplies past samples to MAC lane) ---
    input  wire                   rd_channel,     // 0 = Left Channel, 1 = Right Channel
    input  wire [ADDR_WIDTH-1:0]  rd_addr,        // Tap address (circularly computed)
    output reg  [DATA_WIDTH-1:0]  rd_data         // Read sample to multiplier
);

    // BRAM inference hint for Vivado / Quartus
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] ram_left  [0:MAX_TAPS-1];
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] ram_right [0:MAX_TAPS-1];

    // FSM & counter for synchronous clearing
    reg [ADDR_WIDTH-1:0] clear_addr;
    reg                  clearing;

    // -------------------------------------------------------------
    // Stream Reset FSM & Clear Engine
    // -------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clearing   <= 1'b0;
            clear_addr <= {ADDR_WIDTH{1'b0}};
            busy       <= 1'b0;
        end else begin
            if (stream_reset) begin
                // Any pulse on stream_reset restarts clearing from address 0
                clearing   <= 1'b1;
                clear_addr <= {ADDR_WIDTH{1'b0}};
                busy       <= 1'b1;
            end else if (clearing) begin
                if (clear_addr == MAX_TAPS - 1) begin
                    clearing   <= 1'b0;
                    busy       <= 1'b0;
                end else begin
                    clear_addr <= clear_addr + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------
    // Synchronous Write Port (Multiplexed with Clear Engine)
    // -------------------------------------------------------------
    always @(posedge clk) begin
        if (clearing) begin
            // Simultaneously clear both channels row-by-row (1 write port each)
            ram_left[clear_addr]  <= {DATA_WIDTH{1'b0}};
            ram_right[clear_addr] <= {DATA_WIDTH{1'b0}};
        end else if (wr_en) begin
            if (wr_channel == 1'b0) begin
                ram_left[wr_addr]  <= wr_data;
            end else begin
                ram_right[wr_addr] <= wr_data;
            end
        end
    end

    // -------------------------------------------------------------
    // Synchronous Read Port (1-Cycle Latency Standard BRAM Output)
    // -------------------------------------------------------------
    always @(posedge clk) begin
        if (rd_channel == 1'b0) begin
            rd_data <= ram_left[rd_addr];
        end else begin
            rd_data <= ram_right[rd_addr];
        end
    end

endmodule