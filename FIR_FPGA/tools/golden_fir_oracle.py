import numpy as np

def round_and_saturate_q15(acc):
    """
    Implements the exact rounding and saturation contract:
    - Q1.15 scaling (divide by 2^15 / 32768)
    - Round to nearest, ties away from zero
    - Clamps to 16-bit signed range [-32768, 32767]
    """
    # Round to nearest with ties away from zero:
    # Add bias: +16384 (2^14) for positive, -16384 for negative
    bias = 1 << 14
    if acc >= 0:
        rounded = (acc + bias) >> 15
    else:
        rounded = (acc - bias) >> 15

    # Clamp strictly to signed 16-bit limits
    if rounded > 32767:
        return 32767
    elif rounded < -32768:
        return -32768
    return int(rounded)

class BitExactFIROracle:
    def __init__(self, coeff_path):
        # Load the 129 quantized Q1.15 coefficients
        self.coeffs = np.loadtxt(coeff_path, dtype=np.int64)
        self.num_taps = len(self.coeffs)
        
        # Maintain independent history buffers for Left and Right channels
        # Initialize with zeros
        self.history_l = np.zeros(self.num_taps, dtype=np.int64)
        self.history_r = np.zeros(self.num_taps, dtype=np.int64)

    def reset_state(self):
        """Clears channel histories (equivalent to RESET_STREAM command)."""
        self.history_l.fill(0)
        self.history_r.fill(0)

    def process_channel_sample(self, sample, history):
        """
        Processes one sample for one channel:
        - Updates history (newest at index 0, oldest at index N-1)
        - Computes dot product: sum(h[k] * x[n-k])
        - Rounds and saturates
        """
        # Shift history to make room for new sample at index 0
        history[1:] = history[:-1]
        history[0] = int(sample)

        # 64-bit wide accumulation across all taps
        acc = int(np.dot(self.coeffs, history))

        return round_and_saturate_q15(acc)

    def process_block(self, interleaved_pcm):
        """
        Processes an interleaved stereo block: [L0, R0, L1, R1, ...]
        Returns the filtered interleaved stereo block.
        """
        num_samples = len(interleaved_pcm)
        assert num_samples % 2 == 0, "Stereo frame count must be even!"
        
        output = np.zeros(num_samples, dtype=np.int16)
        
        for i in range(0, num_samples, 2):
            left_in = interleaved_pcm[i]
            right_in = interleaved_pcm[i + 1]

            left_out = self.process_channel_sample(left_in, self.history_l)
            right_out = self.process_channel_sample(right_in, self.history_r)

            output[i] = left_out
            output[i + 1] = right_out

        return output

    def filter_file(self, input_pcm_path, output_pcm_path):
        """Reads a raw binary PCM file, filters it, and writes the golden output."""
        raw_in = np.fromfile(input_pcm_path, dtype='<i2') # Little-endian 16-bit
        filtered_out = self.process_block(raw_in)
        filtered_out.tofile(output_pcm_path)
        print(f"Processed {len(raw_in)//2} stereo frames. Saved to {output_pcm_path}")

if __name__ == '__main__':
    import os
    coeff_file = 'tools/coefficients_q15.txt'
    if not os.path.exists(coeff_file):
        coeff_file = 'coefficients_q15.txt'

    oracle = BitExactFIROracle(coeff_file)
    print(f"Initialized BitExactFIROracle with {oracle.num_taps} taps.")