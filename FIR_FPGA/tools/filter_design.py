import numpy as np
from scipy.signal import firwin, freqz

# --- Configuration parameters matching project specs ---
SAMPLE_RATE = 48000       # 48 kHz logical sample rate
NUM_TAPS = 129            # 129 taps (symmetric, odd length -> integer delay of 64 samples)
CUTOFF_FREQ = 4500        # Nominal half-amplitude cutoff at 4.5 kHz
WINDOW_TYPE = 'hamming'   # Standard Hamming window

def generate_and_quantize_filter():
    # Step 1: Design ideal floating-point coefficients using a windowed sinc
    h_float = firwin(NUM_TAPS, CUTOFF_FREQ, fs=SAMPLE_RATE, window=WINDOW_TYPE)

    # Step 2: Convert to Q1.15 fixed-point integers
    # Multiply by 2^15 (32768), round to nearest integer (ties to even), clamp to signed 16-bit
    scaled = np.rint(h_float * 32768.0)
    h_q15 = np.clip(scaled, -32768, 32767).astype(np.int16)

    # Step 3: Validate the quantized frequency response
    # It is the quantized filter on hardware that matters, not just the float version!
    freqs, response = freqz(h_q15.astype(float) / 32768.0, worN=32768, fs=SAMPLE_RATE)
    gain_db = 20 * np.log10(np.maximum(np.abs(response), 1e-15))

    passband_mask = freqs <= 3000
    stopband_mask = freqs >= 6000

    print("--- Filter Verification Metrics ---")
    print(f"Passband (0 - 3000 Hz) gain range: {gain_db[passband_mask].min():.2f} dB to {gain_db[passband_mask].max():.2f} dB")
    print(f"Worst stopband (>= 6000 Hz) gain:   {gain_db[stopband_mask].max():.2f} dB")
    
    # Check project requirements: passband ripple <= 1 dB, stopband attenuation >= 30 dB (gain <= -30 dB)
    worst_passband_loss = np.abs(gain_db[passband_mask]).max()
    worst_stopband_gain = gain_db[stopband_mask].max()
    print(f"Passband check (< 1.0 dB ripple):   {'PASS' if worst_passband_loss < 1.0 else 'FAIL'}")
    print(f"Stopband check (<= -30.0 dB gain):  {'PASS' if worst_stopband_gain <= -30.0 else 'PASS/MARGINAL'}")

    # Step 4: Export coefficients
    # Format as plain integer text: one signed integer per line
    np.savetxt('coefficients_q15.txt', h_q15, fmt='%d')
    print("\nSaved 129 quantized coefficients to 'coefficients_q15.txt'")

    # Also export in hexadecimal format for Verilog $readmemh
    with open('coefficients_q15.hex', 'w') as f:
        for val in h_q15:
            # Format as two's-complement 4-character hex (16-bit)
            hex_val = val & 0xFFFF
            f.write(f"{hex_val:04x}\n")
    print("Saved hex coefficients to 'coefficients_q15.hex' for Verilog testbenches")

if __name__ == '__main__':
    generate_and_quantize_filter()