import sys
import wave
import numpy as np
from golden_fir_oracle import GoldenFirOracle

def verify_wav_files(raw_in_path, hardware_out_path, coeff_path="coefficients_q15.hex"):
    # 1. Load Filter Coefficients
    print(f"[INFO] Loading coefficients from: {coeff_path}")
    with open(coeff_path, "r") as f:
        coeffs = [int(line.strip(), 16) for line in f if line.strip()]
        # Convert unsigned hex to signed 16-bit
        coeffs = [c if c < 0x8000 else c - 0x10000 for c in coeffs]

    oracle = GoldenFirOracle(coeffs)

    # 2. Read Raw Input WAV
    print(f"[INFO] Reading input audio: {raw_in_path}")
    with wave.open(raw_in_path, 'rb') as wf:
        raw_pcm = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16)
        n_channels = wf.getnchannels()

    assert n_channels == 2, "Audio must be stereo (2 channels)"

    # 3. Compute Golden Expected Audio
    print("[INFO] Computing bit-exact golden reference...")
    expected_pcm = oracle.process_stream(raw_pcm)

    # 4. Read Hardware Output WAV
    print(f"[INFO] Reading hardware output: {hardware_out_path}")
    with wave.open(hardware_out_path, 'rb') as wf:
        hw_pcm = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16)

    # Align comparison lengths to full blocks
    compare_len = min(len(expected_pcm), len(hw_pcm))
    expected_compare = expected_pcm[:compare_len]
    hw_compare = hw_pcm[:compare_len]

    # 5. Statistical and Exact Comparison
    diff = hw_compare.astype(np.int32) - expected_compare.astype(np.int32)
    mismatches = np.count_nonzero(diff)
    max_error = np.max(np.abs(diff)) if compare_len > 0 else 0

    print("\n" + "="*50)
    print("           AUDIO COMPARISON REPORT                ")
    print("="*50)
    print(f"Total Samples Compared: {compare_len}")
    print(f"Exact Matches:         {compare_len - mismatches} ({(compare_len - mismatches)/compare_len*100:.2f}%)")
    print(f"Mismatched Samples:    {mismatches}")
    print(f"Maximum Sample Error:  {max_error}")

    if mismatches == 0:
        print("\n[RESULT] PASS: Hardware output is 100% BIT-EXACT to the Golden Model!")
    else:
        print("\n[RESULT] FAIL: Mismatches detected! First 5 mismatches:")
        err_indices = np.where(diff != 0)[0][:5]
        for idx in err_indices:
            print(f"  Sample {idx}: HW = {hw_compare[idx]}, Expected = {expected_compare[idx]} (Diff = {diff[idx]})")
    print("="*50)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python verify_audio.py <INPUT_WAV> <HARDWARE_OUTPUT_WAV>")
        print("Example: python verify_audio.py input_song.wav output_filtered.wav")
        sys.exit(1)

    verify_wav_files(sys.argv[1], sys.argv[2])