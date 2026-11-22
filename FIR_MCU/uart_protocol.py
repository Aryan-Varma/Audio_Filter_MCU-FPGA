#!/usr/bin/env python3
"""
uart_protocol.py
Binary packet serialization, deserialization, and CRC-16 verification
for host-to-MCU chunked audio transfer.
"""

import struct
from typing import Optional, Tuple

# Protocol Constants
MAGIC_BYTES = b"\x5A\xA5"
PROTOCOL_VERSION = 0x01

# Message Types
MSG_TYPE_DATA = 0x01       # Audio PCM chunk
MSG_TYPE_RESET = 0x02      # Reset stream history / delay line
MSG_TYPE_ACK = 0x03        # Successful response containing filtered PCM
MSG_TYPE_ERROR = 0xFF      # MCU reported error / bad packet

# Header: Magic(2B) + Ver(1B) + Type(1B) + StreamID(1B) + Seq(2B) + Frames(2B) + Length(2B) = 11 Bytes
HEADER_FORMAT = "<2sBBBH H H"
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)
CRC_SIZE = 2


def compute_crc16(data: bytes, initial_crc: int = 0xFFFF) -> int:
    """
    Computes CRC-16-CCITT (Poly: 0x1021, Init: 0xFFFF).
    Directly portable to MCU C implementation.
    """
    crc = initial_crc
    for byte in data:
        crc ^= (byte << 8)
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def build_packet(
    msg_type: int,
    stream_id: int,
    seq_num: int,
    frame_count: int,
    payload: bytes = b""
) -> bytes:
    """
    Packs a message into a framed packet with CRC-16.
    """
    payload_len = len(payload)
    header = struct.pack(
        HEADER_FORMAT,
        MAGIC_BYTES,
        PROTOCOL_VERSION,
        msg_type,
        stream_id & 0xFF,
        seq_num & 0xFFFF,
        frame_count & 0xFFFF,
        payload_len & 0xFFFF
    )
    
    # Checksum covers header + payload
    crc = compute_crc16(header + payload)
    crc_bytes = struct.pack("<H", crc)
    
    return header + payload + crc_bytes


def build_reset_packet(stream_id: int = 0) -> bytes:
    """Creates a reset command packet to re-initialize MCU filter state."""
    return build_packet(
        msg_type=MSG_TYPE_RESET,
        stream_id=stream_id,
        seq_num=0,
        frame_count=0,
        payload=b""
    )


def build_data_packet(
    stream_id: int,
    seq_num: int,
    frame_count: int,
    pcm_payload: bytes
) -> bytes:
    """Creates an audio data chunk packet carrying PCM16 samples."""
    return build_packet(
        msg_type=MSG_TYPE_DATA,
        stream_id=stream_id,
        seq_num=seq_num,
        frame_count=frame_count,
        payload=pcm_payload
    )


class PacketParser:
    """
    Stateful byte stream parser for UART frames.
    Handles data arriving fragmented across multiple serial reads.
    """
    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data: bytes):
        """Append incoming serial bytes to parser buffer."""
        self.buffer.extend(data)

    def parse_one(self) -> Optional[Tuple[int, int, int, int, bytes]]:
        """
        Attempts to extract one valid packet from the buffer.
        Returns None if incomplete.
        Returns (msg_type, stream_id, seq_num, frame_count, payload) on success.
        Discards corrupted bytes automatically.
        """
        while len(self.buffer) >= (HEADER_SIZE + CRC_SIZE):
            # 1. Search for magic synchronization word
            magic_idx = self.buffer.find(MAGIC_BYTES)
            if magic_idx == -1:
                # No magic bytes found; keep last byte in case it's the start of magic
                self.buffer = self.buffer[-1:] if len(self.buffer) > 0 else bytearray()
                return None

            if magic_idx > 0:
                # Discard leading junk bytes before magic
                del self.buffer[:magic_idx]

            if len(self.buffer) < HEADER_SIZE:
                return None

            # 2. Unpack header
            magic, version, msg_type, stream_id, seq_num, frame_count, payload_len = struct.unpack_from(
                HEADER_FORMAT, self.buffer, 0
            )

            if version != PROTOCOL_VERSION:
                # Corrupted header; advance past this false magic
                del self.buffer[:2]
                continue

            total_packet_len = HEADER_SIZE + payload_len + CRC_SIZE
            if len(self.buffer) < total_packet_len:
                # Packet payload not fully received yet
                return None

            # 3. Check CRC-16
            packet_data = bytes(self.buffer[: HEADER_SIZE + payload_len])
            received_crc = struct.unpack_from("<H", self.buffer, HEADER_SIZE + payload_len)[0]
            computed_crc = compute_crc16(packet_data)

            if received_crc != computed_crc:
                # CRC error: discard this magic and resynchronize
                del self.buffer[:2]
                continue

            # 4. Valid packet extracted
            payload = bytes(self.buffer[HEADER_SIZE : HEADER_SIZE + payload_len])
            del self.buffer[:total_packet_len]

            return msg_type, stream_id, seq_num, frame_count, payload

        return None