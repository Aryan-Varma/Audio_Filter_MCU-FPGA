import os
import numpy as np
from golden_fir_oracle import BitExactFIROracle

SAMPLE_RATE = 48000
BLOCK_FRAMES = 64  # Standard block size: 64 stereo frames (128 samples, 256 bytes)

def ensure_dirs():
    os.makedirs('data/vectors', exist_ok=True)

def write_files(name, interleaved_pcm, oracle):
    """
    Saves:
    1. Binary input (.bin) and golden output (.bin) for MCU/system checks
    2. Hex input (.hex) and golden output (.hex) for Verilog $readmemh simulation
    """
    # 1. Process with the Bit-Exact Oracle to get the expected answer
    oracle.reset_state()
    expected_out = oracle.process_block(interleaved_pcm)

    # 2. Binary files (int16 little-endian)
    in_bin_path = f"data/vectors/{name}_in.bin"
    out_bin_path = f"data/vectors/{name}_expected.bin"
    interleaved_pcm.astype('<i2').tofile(in_bin_path)
    expected_out.astype('<i2').tofile(out_bin_path)

    # 3. Hex files for Verilog simulation
    in_hex_path = f"data/vectors/{name}_in.hex"
    out_hex_path = f"data/vectors/{name}_expected.hex"
    
    with open(in_hex_path, 'w') as f_in, open(out_hex_path, 'w') as f_out:
        for val in interleaved_pcm:
            f_in.write(f"{int(val) & 0xFFFF:04x}\n")
        for val in expected_out:
            f_out.write(f"{int(val) & 0xFFFF:04x}\n")

    print(f"Generated test '{name}': {len(interleaved_pcm)//2} frames -> Saved to data/vectors/")

def generate_all_vectors():
    ensure_dirs()
    
    coeff_file = 'tools/coefficients_q15.txt'
    if not os.path.exists(coeff_file):
        coeff_file = 'coefficients_q15.txt'
    oracle = BitExactFIROracle(coeff_file)

    # -------------------------------------------------------------
    # Test 1: Impulse Response (512 stereo frames = 8 blocks)
    # -------------------------------------------------------------
    num_frames = 512
    impulse = np.zeros(num_frames * 2, dtype=np.int16)
    # Put impulse on Left at frame 0, Right at frame 1
    impulse[0] = 32767   # L0
    impulse[3] = 32767   # R1
    write_files("test_impulse", impulse, oracle)

    # -------------------------------------------------------------
    # Test 2: Channel Isolation (Left has tones, Right is strictly 0)
    # -------------------------------------------------------------
    t = np.arange(num_frames) / SAMPLE_RATE
    sig_left = (0.5 * 32767.0 * np.sin(2 * np.pi * 1000 * t)).astype(np.int16)
    sig_right = np.zeros(num_frames, dtype=np.int16)
    
    isolation = np.zeros(num_frames * 2, dtype=np.int16)
    isolation[0::2] = sig_left
    isolation[1::2] = sig_right
    write_files("test_isolation", isolation, oracle)

    # -------------------------------------------------------------
    # Test 3: Signed Extrema & Saturation (Full-scale square wave)
    # -------------------------------------------------------------
    extrema = np.zeros(num_frames * 2, dtype=np.int16)
    # Alternate full-scale positive and negative blocks
    for i in range(num_frames):
        val = 32767 if (i // 16) % 2 == 0 else -32768
        extrema[2 * i] = val
        extrema[2 * i + 1] = -val
    write_files("test_saturation", extrema, oracle)

    # -------------------------------------------------------------
    # Test 4: Two-Tone Engineering Test (1 kHz wanted + 8 kHz noise)
    # -------------------------------------------------------------
    # Run for 2048 frames (32 blocks ~ 42.6 ms) to observe steady-state
    num_frames_audio = 2048
    t_audio = np.arange(num_frames_audio) / SAMPLE_RATE
    
    # 1 kHz wanted (amplitude 0.25) + 8 kHz interference (amplitude 0.10)
    s1k = 0.25 * 32767.0 * np.sin(2 * np.pi * 1000 * t_audio)
    n8k = 0.10 * 32767.0 * np.sin(2 * np.pi * 8000 * t_audio)
    two_tone_mono = (s1k + n8k).astype(np.int16)

    two_tone_stereo = np.zeros(num_frames_audio * 2, dtype=np.int16)
    two_tone_stereo[0::2] = two_tone_mono  # Left
    two_tone_stereo[1::2] = two_tone_mono  # Right
    write_files("test_twotone", two_tone_stereo, oracle)

if __name__ == '__main__':
    generate_all_vectors()