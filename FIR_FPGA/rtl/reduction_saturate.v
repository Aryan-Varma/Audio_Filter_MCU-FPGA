`timescale 1ns / 1ps

module reduction_saturate #(
    parameter DATA_WIDTH  = 16,    // 16-bit output sample
    parameter ACCUM_WIDTH = 40     // 40-bit accumulator from MAC lane
)(
    input  wire                           clk,
    input  wire                           rst_n,

    // --- Control Handshake ---
    input  wire                           sample_done,  // High when all taps for a sample finish
    output reg                            out_valid,    // High when final 16-bit sample is ready

    // --- Accumulator Input ---
    // (If using multiple lanes later, sum their wide outputs into this port)
    input  wire signed [ACCUM_WIDTH-1:0]  accum_in,

    // --- Final 16-bit PCM Audio Sample ---
    output reg  signed [DATA_WIDTH-1:0]   sample_out
);

    // Constant rounding bias: 2^14 = 16384
    localparam signed [ACCUM_WIDTH-1:0] BIAS = 40'sd16384;

    // -------------------------------------------------------------
    // Stage 1: Rounding (Ties away from zero) & Arithmetic Shift
    // -------------------------------------------------------------
    reg signed [ACCUM_WIDTH-1:0] biased_sum;
    reg                          done_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            biased_sum <= {ACCUM_WIDTH{1'b0}};
            done_d1    <= 1'b0;
        end else begin
            done_d1 <= sample_done;
            if (sample_done) begin
                if (accum_in >= 0) begin
                    biased_sum <= accum_in + BIAS;
                end else begin
                    biased_sum <= accum_in - BIAS;
                end
            end
        end
    end

    // Arithmetic right shift by 15 (retains sign bit)
    wire signed [ACCUM_WIDTH-1:0] shifted_val = biased_sum >>> 15;

    // -------------------------------------------------------------
    // Stage 2: Saturation / Clamping to [-32768, 32767]
    // -------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_out <= {DATA_WIDTH{1'b0}};
            out_valid  <= 1'b0;
        end else begin
            out_valid <= done_d1;
            if (done_d1) begin
                if (shifted_val > 40'sd32767) begin
                    sample_out <= 16'sd32767;
                end else if (shifted_val < -40'sd32768) begin
                    sample_out <= -16'sd32768;
                end else begin
                    sample_out <= shifted_val[DATA_WIDTH-1:0];
                end
            end
        end
    end

endmodule