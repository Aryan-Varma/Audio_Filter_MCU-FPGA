#!/usr/bin/env python3
"""
audio_evaluator.py
Evaluates MCU filter accuracy, renders mcu_output.wav, and plots spectral/timing metrics.
Reads and writes all files directly in the current working directory.
"""

import argparse
import json
from pathlib import Path
import matplotlib.pyplot as plt
import numpy as np
from scipy.io import wavfile
from scipy.signal import welch


def load_pcm(file_path: Path, channels: int) -> np.ndarray:
    """Loads signed 16-bit little-endian PCM samples into an array shaped [frames, channels]."""
    if not file_path.is_file():
        raise FileNotFoundError(f"Missing PCM file: {file_path.name}")
    raw = np.fromfile(file_path, dtype="<i2")
    if channels > 1:
        assert raw.size % channels == 0, f"Incomplete multi-channel frame in {file_path.name}"
        return raw.reshape(-1, channels)
    return raw.reshape(-1, 1)


def evaluate_implementation_accuracy(mcu_samples: np.ndarray, ref_samples: np.ndarray) -> tuple[int, int]:
    """
    Computes sample-for-sample integer delta against the PC software oracle.
    Returns (max_abs_error, mismatch_count).
    """
    min_len = min(len(mcu_samples), len(ref_samples))
    mcu_trimmed = mcu_samples[:min_len].astype(np.int64)
    ref_trimmed = ref_samples[:min_len].astype(np.int64)

    err = mcu_trimmed - ref_trimmed
    abs_err = np.abs(err)

    max_err = int(np.max(abs_err))
    mismatch_count = int(np.count_nonzero(abs_err))
    return max_err, mismatch_count


def calculate_snr(signal: np.ndarray, noisy: np.ndarray) -> float:
    """Calculates SNR (dB) between a clean reference and a noisy signal."""
    sig_power = np.sum(signal.astype(np.float64) ** 2)
    noise_power = np.sum((noisy.astype(np.float64) - signal.astype(np.float64)) ** 2)
    if noise_power <= 1e-15:
        return float("inf")
    return float(10.0 * np.log10(sig_power / noise_power))


def plot_comparison(
    noisy: np.ndarray,
    mcu: np.ndarray,
    fs: int,
    output_png: Path,
    channel_idx: int = 0
) -> None:
    """
    Plots time-domain waveforms and Welch PSD estimates for input vs MCU output.
    """
    # Normalize channel samples to [-1.0, 1.0] for plotting
    x_float = noisy[:, channel_idx].astype(float) / 32768.0
    y_float = mcu[:, channel_idx].astype(float) / 32768.0

    # Display initial 30 ms transient/steady segment
    count = min(len(x_float), len(y_float), int(0.03 * fs))
    t = np.arange(count) / fs

    fig, ax = plt.subplots(2, 1, figsize=(9, 7))

    # 1. Time-Domain Waveforms
    ax[0].plot(t * 1000.0, x_float[:count], label="Noisy Input", color="gray", alpha=0.8)
    ax[0].plot(t * 1000.0, y_float[:count], label="MCU Output (unaligned)", color="navy", lw=1.2)
    ax[0].set_xlabel("Time (ms)")
    ax[0].set_ylabel("Amplitude / Full Scale")
    ax[0].set_title("Time-Domain Waveform Comparison (Channel 0)")
    ax[0].grid(True, linestyle="--", alpha=0.6)
    ax[0].legend(loc="upper right")

    # 2. Welch Power Spectral Density (PSD)
    # Discard filter startup transients (e.g., first 512 samples)
    steady_start = min(512, len(x_float) // 4)
    x_steady = x_float[steady_start:]
    y_steady = y_float[steady_start:]

    nperseg = min(2048, len(y_steady))
    if nperseg < 256:
        nperseg = len(y_steady)

    for label, z, color in [("Input", x_steady, "gray"), ("MCU Output", y_steady, "navy")]:
        f, p = welch(
            z,
            fs=fs,
            window="hann",
            nperseg=nperseg,
            noverlap=nperseg // 2,
            detrend=False,
            scaling="density"
        )
        psd_db = 10.0 * np.log10(np.maximum(p, 1e-20))
        ax[1].plot(f, psd_db, label=label, color=color, lw=1.3)

    ax[1].set_xlabel("Frequency (Hz)")
    ax[1].set_ylabel("PSD (dB / Hz)")
    ax[1].set_title("Frequency Spectrum (Welch PSD Estimate)")
    ax[1].set_xlim(0, fs / 2)
    ax[1].grid(True, linestyle="--", alpha=0.6)
    ax[1].legend(loc="upper right")

    fig.tight_layout()
    fig.savefig(output_png, dpi=180)
    plt.close(fig)
    print(f"[+] Saved comparison plot: {output_png.name}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate MCU FIR output accuracy and audio quality")
    parser.add_argument("--mcu-pcm", type=Path, default=Path("mcu_output.pcm"), help="MCU output PCM file")
    parser.add_argument("--ref-pcm", type=Path, default=Path("reference_output.pcm"), help="PC reference PCM file")
    parser.add_argument("--noisy-pcm", type=Path, default=Path("noisy_input.pcm"), help="Noisy input PCM file")
    parser.add_argument("--clean-pcm", type=Path, default=Path("clean_target.pcm"), help="Clean target PCM file (optional)")
    parser.add_argument("--meta", type=Path, default=Path("noisy_input_meta.json"), help="Metadata JSON")
    parser.add_argument("--ref-meta", type=Path, default=Path("reference_output_meta.json"), help="Reference metadata JSON")
    parser.add_argument("--rate", type=int, default=48000, help="Fallback sampling rate (Hz)")
    parser.add_argument("--channels", type=int, choices=[1, 2], default=2, help="Fallback channels")

    args = parser.parse_args()

    # Load metadata if present
    sample_rate = args.rate
    channels = args.channels
    if args.meta.is_file():
        try:
            m = json.loads(args.meta.read_text())
            sample_rate = m.get("sample_rate", sample_rate)
            channels = m.get("channels", channels)
        except Exception:
            pass

    group_delay_samples = 64  # Default for 129 taps
    if args.ref_meta.is_file():
        try:
            rm = json.loads(args.ref_meta.read_text())
            group_delay_samples = rm.get("group_delay_samples", group_delay_samples)
        except Exception:
            pass

    # 1. Load PCM arrays
    mcu_samples = load_pcm(args.mcu_pcm, channels)
    noisy_samples = load_pcm(args.noisy_pcm, channels)

    # 2. Write playable MCU output WAV
    mcu_wav_path = Path("mcu_output.wav")
    wavfile.write(mcu_wav_path, sample_rate, mcu_samples.squeeze() if channels == 1 else mcu_samples)
    print(f"[+] Reconstructed WAV:     {mcu_wav_path.name}")

    # 3. Verify Implementation Accuracy against PC Oracle
    if args.ref_pcm.is_file():
        ref_samples = load_pcm(args.ref_pcm, channels)
        max_err, mismatches = evaluate_implementation_accuracy(mcu_samples, ref_samples)
        print("--------------------------------------------------")
        print(f"[*] Max Integer Error:     {max_err}")
        print(f"[*] Mismatched Samples:    {mismatches} / {min(len(mcu_samples), len(ref_samples)) * channels}")
        if max_err == 0:
            print("[+] PASS: MCU output matches PC software oracle bit-for-bit!")
        else:
            print(f"[!] Warning: Discrepancy observed. Max delta = {max_err}")
        print("--------------------------------------------------")

    # 4. Compute Audio Quality / SNR if clean target exists
    if args.clean_pcm.is_file():
        clean_samples = load_pcm(args.clean_pcm, channels)
        
        # Align by filter group delay: output y[n + D] corresponds to target s[n]
        d = group_delay_samples
        valid_len = min(len(clean_samples) - d, len(mcu_samples) - d, len(noisy_samples) - d)

        if valid_len > 0:
            s = clean_samples[:valid_len, 0]
            x = noisy_samples[:valid_len, 0]
            y = mcu_samples[d : d + valid_len, 0]

            snr_in = calculate_snr(s, x)
            snr_out = calculate_snr(s, y)
            delta_snr = snr_out - snr_in

            print(f"[*] Input SNR:             {snr_in:.2f} dB")
            print(f"[*] Filtered Output SNR:   {snr_out:.2f} dB")
            print(f"[*] SNR Improvement:       {delta_snr:+.2f} dB")
            print("--------------------------------------------------")

    # 5. Generate and save waveform & spectral plots
    plot_comparison(
        noisy=noisy_samples,
        mcu=mcu_samples,
        fs=sample_rate,
        output_png=Path("actual_mcu_waveform_and_spectrum.png"),
        channel_idx=0
    )


if __name__ == "__main__":
    main()