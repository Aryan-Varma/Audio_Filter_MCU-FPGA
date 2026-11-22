`timescale 1ns / 1ps

module coeff_ram #(
    parameter DATA_WIDTH = 16,     // 16-bit Q1.15 coefficients
    parameter MAX_TAPS   = 2048,   // Support up to 2048 taps for the scaling study
    parameter ADDR_WIDTH = 11      // 2^11 = 2048 entries per bank
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // --- Configuration Port (Used by Packet Parser to load new weights) ---
    input  wire                   write_en,        // High when writing a coefficient
    input  wire [ADDR_WIDTH-1:0]  write_addr,      // Tap index (0 to N-1)
    input  wire [DATA_WIDTH-1:0]  write_data,      // 16-bit Q1.15 coefficient value
    input  wire                   commit_swap,     // Atomic pulse to switch active bank

    // --- Core Read Port (Used by Scheduler / MAC lane during filtering) ---
    input  wire [ADDR_WIDTH-1:0]  read_addr,       // Tap index being multiplied
    output reg  [DATA_WIDTH-1:0]  read_data,       // Coefficient output to multiplier

    // --- Status / Diagnostics ---
    output wire                   active_bank_id   // Indicates which bank is currently active
);

    // Bank 0 and Bank 1 memories (Synthesizes to Block RAM on ZedBoard)
    reg [DATA_WIDTH-1:0] bank0 [0:MAX_TAPS-1];
    reg [DATA_WIDTH-1:0] bank1 [0:MAX_TAPS-1];

    // Bank tracking: 0 means Bank 0 is active, 1 means Bank 1 is active
    reg active_bank;
    assign active_bank_id = active_bank;

    // -------------------------------------------------------------
    // Bank Selection and Atomic Commit Logic
    // -------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_bank <= 1'b0; // Default to Bank 0 active on reset
        end else if (commit_swap) begin
            active_bank <= ~active_bank; // Flip active bank cleanly at block boundary
        end
    end

    // -------------------------------------------------------------
    // Write Port: Always writes to the INACTIVE bank
    // -------------------------------------------------------------
    always @(posedge clk) begin
        if (write_en) begin
            if (active_bank == 1'b0) begin
                // Bank 0 is active, so write into inactive Bank 1
                bank1[write_addr] <= write_data;
            end else begin
                // Bank 1 is active, so write into inactive Bank 0
                bank0[write_addr] <= write_data;
            end
        end
    end

    // -------------------------------------------------------------
    // Read Port: Always reads from the ACTIVE bank (synchronous read)
    // -------------------------------------------------------------
    always @(posedge clk) begin
        if (active_bank == 1'b0) begin
            read_data <= bank0[read_addr];
        end else begin
            read_data <= bank1[read_addr];
        end
    end

endmodule