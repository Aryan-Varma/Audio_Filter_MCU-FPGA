`timescale 1ns / 1ps

module mac_lane #(
    parameter DATA_WIDTH  = 16,     // 16-bit signed sample & coefficient
    parameter ACCUM_WIDTH = 40      // 40-bit accumulator (guard bits prevent overflow)
)(
    input  wire                           clk,
    input  wire                           rst_n,

    // --- Control Inputs ---
    input  wire                           clr_acc,    // Resets accumulator for a new sample
    input  wire                           valid_in,   // High when sample & coeff are valid

    // --- Operands ---
    input  wire signed [DATA_WIDTH-1:0]   sample_in,  // x[n-k] from history RAM
    input  wire signed [DATA_WIDTH-1:0]   coeff_in,   // h[k] from coefficient RAM

    // --- Output ---
    output reg  signed [ACCUM_WIDTH-1:0]  accum_out   // Wide partial sum to reduction unit
);

    // Pipeline registers for DSP slice inference (ensures high Fmax on ZedBoard)
    reg signed [DATA_WIDTH-1:0]        sample_reg;
    reg signed [DATA_WIDTH-1:0]        coeff_reg;
    reg signed [(2*DATA_WIDTH)-1:0]    product_reg;
    reg                                valid_d1;
    reg                                clr_d1;

    // -------------------------------------------------------------
    // Stage 1: Register Operands (Input Registering)
    // -------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_reg <= {DATA_WIDTH{1'b0}};
            coeff_reg  <= {DATA_WIDTH{1'b0}};
            valid_d1   <= 1'b0;
            clr_d1     <= 1'b0;
        end else begin
            sample_reg <= sample_in;
            coeff_reg  <= coeff_in;
            valid_d1   <= valid_in;
            clr_d1     <= clr_acc;
        end
    end

    // -------------------------------------------------------------
    // Stage 2: Signed Multiplication (16 x 16 -> 32 bits)
    // -------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product_reg <= {(2*DATA_WIDTH){1'b0}};
        end else if (valid_d1) begin
            product_reg <= sample_reg * coeff_reg;
        end else begin
            product_reg <= {(2*DATA_WIDTH){1'b0}};
        end
    end

    // -------------------------------------------------------------
    // Stage 3: Wide Accumulation (Sign-extend product to 40 bits)
    // -------------------------------------------------------------
    // Sign-extended product
    wire signed [ACCUM_WIDTH-1:0] product_ext = {{ (ACCUM_WIDTH - 2*DATA_WIDTH){product_reg[(2*DATA_WIDTH)-1]} }, product_reg};

    // Need a 2-cycle delayed clear signal matching product_reg latency
    reg clr_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clr_d2 <= 1'b0;
        end else begin
            clr_d2 <= clr_d1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum_out <= {ACCUM_WIDTH{1'b0}};
        end else begin
            if (clr_d2) begin
                // Start a new sample: initialize accumulator with the first product
                accum_out <= product_ext;
            end else begin
                // Accumulate subsequent tap products
                accum_out <= accum_out + product_ext;
            end
        end
    end

endmodule