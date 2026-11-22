import sys
import time
import wave
import serial
import struct
import numpy as np

# Framing Constants (Matching FPGA SPI block dimensions)
BLOCK_FRAMES = 64
CHANNELS = 2
SAMPLES_PER_BLOCK = BLOCK_FRAMES * CHANNELS       # 128 samples
BYTES_PER_BLOCK = SAMPLES_PER_BLOCK * 2            # 256 bytes

START_DELIMITER = b'\x5A\xA5'                      # Packet Sync Header

def stream_audio(com_port, in_wav_path, out_wav_path, baudrate=921600):
    print(f"[INFO] Opening WAV file: {in_wav_path}")
    with wave.open(in_wav_path, 'rb') as wf:
        n_channels = wf.getnchannels()
        sampwidth  = wf.getsampwidth()
        framerate  = wf.getframerate()
        n_frames   = wf.getnframes()
        raw_bytes  = wf.readframes(n_frames)

    assert n_channels == 2, f"Expected 2 channels (stereo), found {n_channels}"
    assert sampwidth == 2, f"Expected 16-bit PCM, found {sampwidth*8}-bit"
    assert framerate == 48000, f"Expected 48 kHz sample rate, found {framerate} Hz"

    # Convert to 16-bit signed numpy array
    pcm_data = np.frombuffer(raw_bytes, dtype=np.int16)
    total_samples = len(pcm_data)
    total_blocks = total_samples // SAMPLES_PER_BLOCK

    print(f"[INFO] Audio loaded: {n_frames} frames ({total_blocks} complete blocks)")
    print(f"[INFO] Connecting to MCU on {com_port} @ {baudrate} baud...")

    ser = serial.Serial(com_port, baudrate, timeout=2.0)
    time.sleep(1.0) # Allow board reboot/handshake settling

    output_pcm = bytearray()
    start_time = time.time()

    for block_idx in range(total_blocks):
        # Slice 128 samples (256 bytes)
        start_samp = block_idx * SAMPLES_PER_BLOCK
        end_samp   = start_samp + SAMPLES_PER_BLOCK
        block_bytes = pcm_data[start_samp:end_samp].tobytes()

        # Send: Sync Header (2B) + Block Index (2B) + Audio Payload (256B)
        header = START_DELIMITER + struct.pack('<H', block_idx)
        ser.write(header + block_bytes)

        # Wait for MCU to return the 256-byte processed block from FPGA
        rx_block = ser.read(BYTES_PER_BLOCK)
        if len(rx_block) != BYTES_PER_BLOCK:
            print(f"[ERROR] Timeout on Block {block_idx}! Expected {BYTES_PER_BLOCK} bytes, got {len(rx_block)}")
            break

        output_pcm.extend(rx_block)

        if (block_idx + 1) % 50 == 0 or (block_idx + 1) == total_blocks:
            sys.stdout.write(f"\r[INFO] Processed Block {block_idx+1}/{total_blocks} ({(block_idx+1)/total_blocks*100:.1f}%)")
            sys.stdout.flush()

    elapsed = time.time() - start_time
    ser.close()
    print(f"\n[INFO] Transmission complete in {elapsed:.2f} seconds.")

    # Write output WAV file
    print(f"[INFO] Writing output audio to: {out_wav_path}")
    with wave.open(out_wav_path, 'wb') as out_wf:
        out_wf.setnchannels(2)
        out_wf.setsampwidth(2)
        out_wf.setframerate(48000)
        out_wf.writeframes(bytes(output_pcm))

    print("[SUCCESS] Audio filtering pipeline verified successfully.")

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python pc_mcu_streamer.py <COM_PORT> <INPUT_WAV> <OUTPUT_WAV>")
        print("Example: python pc_mcu_streamer.py COM5 input.wav filtered_output.wav")
        sys.exit(1)

    stream_audio(sys.argv[1], sys.argv[2], sys.argv[3])