"""
uav_packet.py - MAVLink v2-style UAV frame protected with Ascon-AEAD128.

Frame (AD of 15 bytes = exactly one permutation in the core; a full 16-byte
AD block would need an extra padding block, i.e. one more p8):

    | header 10 B | counter ext 5 B | ciphertext (len B) | tag 16 B |
    \\________ AD (15 B) __________/

    header = STX(0xFD) LEN INCOMPAT COMPAT SEQ SYSID COMPID MSGID(3 B, little endian)
    SEQ          = counter bits [7:0]
    counter ext  = counter bits [47:8], big endian
    INCOMPAT     = 0x80 marks an AEAD-protected frame
    LEN          = payload length (bulk frames > 255 B carry LEN = 0xFF; the
                   real length is the datagram length)

Nonce (128 bit, never transmitted):

    salt (6 B) || SYSID || COMPID || direction (1 B) || counter (7 B, big endian)

Each sender keeps its own 48-bit counter per direction, so (key, nonce) never
repeats inside a session. The receiver accepts a frame only if the tag
matches and the counter passes a sliding replay window.

Run this file to execute the self-test (round trip, tamper / replay / wrong
key rejection).
"""

from __future__ import annotations

import os
import struct
from dataclasses import dataclass, field
from typing import Optional, Tuple

from ascon import ascon_decrypt, ascon_encrypt

STX = 0xFD
INCOMPAT_AEAD = 0x80
HEADER_LEN = 10
CTR_EXT_LEN = 5
AD_LEN = HEADER_LEN + CTR_EXT_LEN     # 15 B = one AD permutation
TAG_LEN = 16
AEAD_OVERHEAD = CTR_EXT_LEN + TAG_LEN  # bytes added to a plain MAVLink frame
                                       # (plain frame: header 10 B + payload + CRC 2 B;
                                       #  AEAD frame drops the CRC -> net +19 B)
PLAIN_TRAILER = 2                      # MAVLink CRC-16 of a plain frame

DIR_GCS_TO_UAV = 0  # uplink: C2
DIR_UAV_TO_GCS = 1  # downlink: telemetry

COUNTER_BITS = 48
REPLAY_WINDOW = 64


# ---------------------------------------------------------------------------
# Message catalogue (MAVLink common payload sizes, without extensions)
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class MsgType:
    name: str
    msgid: int
    payload_len: int
    direction: int      # DIR_GCS_TO_UAV (C2) or DIR_UAV_TO_GCS (telemetry)
    rate_hz: float      # default rate per link
    traffic_class: str  # "c2", "telemetry" or "bulk"


MSG_TYPES = {
    "HEARTBEAT":            MsgType("HEARTBEAT",            0,  9,  DIR_UAV_TO_GCS, 1.0,  "telemetry"),
    "ATTITUDE":             MsgType("ATTITUDE",             30, 28, DIR_UAV_TO_GCS, 50.0, "telemetry"),
    "GLOBAL_POSITION_INT":  MsgType("GLOBAL_POSITION_INT",  33, 28, DIR_UAV_TO_GCS, 10.0, "telemetry"),
    "COMMAND_LONG":         MsgType("COMMAND_LONG",         76, 33, DIR_GCS_TO_UAV, 10.0, "c2"),
    "SET_POSITION_TARGET_LOCAL_NED":
                            MsgType("SET_POSITION_TARGET_LOCAL_NED", 84, 53, DIR_GCS_TO_UAV, 50.0, "c2"),
    # Not MAVLink: payload / video chunk used to create contention.
    "BULK_CHUNK":           MsgType("BULK_CHUNK",      0xFFFF00, 1400, DIR_UAV_TO_GCS, 0.0, "bulk"),
}


def blocks(nbytes: int) -> int:
    """Number of 128-bit blocks the core processes for nbytes of PT/CT
    (a final partial or empty block is always processed)."""
    return nbytes // 16 + 1


# ---------------------------------------------------------------------------
# Header / nonce
# ---------------------------------------------------------------------------
def build_ad(payload_len: int, counter: int, sysid: int, compid: int, msgid: int) -> bytes:
    if not 0 <= counter < (1 << COUNTER_BITS):
        raise ValueError("counter out of range")
    hdr = struct.pack(
        "<BBBBBBB",
        STX,
        min(payload_len, 0xFF),
        INCOMPAT_AEAD,
        0,
        counter & 0xFF,
        sysid & 0xFF,
        compid & 0xFF,
    ) + (msgid & 0xFFFFFF).to_bytes(3, "little")
    ext = (counter >> 8).to_bytes(CTR_EXT_LEN, "big")
    return hdr + ext


def parse_ad(ad: bytes) -> dict:
    stx, ln, incompat, compat, seq, sysid, compid = struct.unpack("<BBBBBBB", ad[:7])
    msgid = int.from_bytes(ad[7:10], "little")
    counter = (int.from_bytes(ad[10:AD_LEN], "big") << 8) | seq
    return dict(stx=stx, len=ln, incompat=incompat, compat=compat, seq=seq,
                sysid=sysid, compid=compid, msgid=msgid, counter=counter)


def make_nonce(salt: bytes, sysid: int, compid: int, direction: int, counter: int) -> bytes:
    if len(salt) != 6:
        raise ValueError("salt must be 6 bytes")
    return salt + bytes([sysid & 0xFF, compid & 0xFF, direction & 0xFF]) + counter.to_bytes(7, "big")


# ---------------------------------------------------------------------------
# Replay window
# ---------------------------------------------------------------------------
@dataclass
class ReplayWindow:
    size: int = REPLAY_WINDOW
    highest: int = -1
    bitmap: int = 0  # bit i set = counter (highest - i) already accepted

    def check(self, counter: int) -> bool:
        """True if the counter is new (not a replay, not too old)."""
        if counter > self.highest:
            return True
        offset = self.highest - counter
        if offset >= self.size:
            return False
        return not (self.bitmap >> offset) & 1

    def update(self, counter: int) -> None:
        if counter > self.highest:
            shift = counter - self.highest
            self.bitmap = ((self.bitmap << shift) | 1) & ((1 << self.size) - 1) if shift < self.size else 1
            self.highest = counter
        else:
            self.bitmap |= 1 << (self.highest - counter)


# ---------------------------------------------------------------------------
# Endpoint (one side of one link)
# ---------------------------------------------------------------------------
@dataclass
class LinkKeys:
    key: bytes
    salt: bytes
    sysid: int
    compid: int = 1

    @staticmethod
    def random(sysid: int, rng: Optional[os.urandom] = None) -> "LinkKeys":
        return LinkKeys(key=os.urandom(16), salt=os.urandom(6), sysid=sysid)


@dataclass
class Endpoint:
    keys: LinkKeys
    tx_direction: int
    tx_counter: int = 0
    rx_window: ReplayWindow = field(default_factory=ReplayWindow)

    def seal(self, msg: MsgType, payload: bytes) -> bytes:
        """Encrypt one message into a frame."""
        if len(payload) != msg.payload_len:
            raise ValueError(f"{msg.name}: payload must be {msg.payload_len} B")
        ctr = self.tx_counter
        self.tx_counter += 1
        ad = build_ad(len(payload), ctr, self.keys.sysid, self.keys.compid, msg.msgid)
        nonce = make_nonce(self.keys.salt, self.keys.sysid, self.keys.compid, self.tx_direction, ctr)
        return ad + ascon_encrypt(self.keys.key, nonce, ad, payload)

    def open(self, frame: bytes) -> Tuple[bool, str, Optional[bytes]]:
        """Verify and decrypt one frame. Returns (ok, reason, payload)."""
        if len(frame) < AD_LEN + TAG_LEN:
            return False, "short", None
        ad, body = frame[:AD_LEN], frame[AD_LEN:]
        h = parse_ad(ad)
        if h["stx"] != STX or not h["incompat"] & INCOMPAT_AEAD:
            return False, "format", None
        if h["sysid"] != self.keys.sysid:
            return False, "sysid", None
        if not self.rx_window.check(h["counter"]):
            return False, "replay", None
        rx_direction = 1 - self.tx_direction
        nonce = make_nonce(self.keys.salt, h["sysid"], h["compid"], rx_direction, h["counter"])
        pt = ascon_decrypt(self.keys.key, nonce, ad, body)
        if pt is None:
            return False, "tag", None
        # Window is updated only after the tag verified (no state change on forgeries)
        self.rx_window.update(h["counter"])
        return True, "ok", pt


def link_pair(sysid: int) -> Tuple[Endpoint, Endpoint]:
    """(GCS endpoint, UAV endpoint) sharing one key for link `sysid`."""
    keys = LinkKeys.random(sysid)
    return Endpoint(keys, DIR_GCS_TO_UAV), Endpoint(keys, DIR_UAV_TO_GCS)


def frame_len(payload_len: int, aead: bool = True) -> int:
    """On-air frame length in bytes (without IP/UDP headers)."""
    if aead:
        return AD_LEN + payload_len + TAG_LEN
    return HEADER_LEN + payload_len + PLAIN_TRAILER


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
def _self_test() -> None:
    gcs, uav = link_pair(sysid=7)
    results = {}

    # Round trip for every MAVLink message type, both directions
    for msg in MSG_TYPES.values():
        if msg.traffic_class == "bulk":
            continue
        tx, rx = (gcs, uav) if msg.direction == DIR_GCS_TO_UAV else (uav, gcs)
        payload = os.urandom(msg.payload_len)
        frame = tx.seal(msg, payload)
        assert len(frame) == frame_len(msg.payload_len)
        ok, why, pt = rx.open(frame)
        assert ok and pt == payload, (msg.name, why)
    results["round trip"] = "ok"

    msg = MSG_TYPES["COMMAND_LONG"]
    payload = os.urandom(msg.payload_len)
    frame = gcs.seal(msg, payload)

    # Tampered header (AD), payload, tag
    for name, pos in (("tampered header", 4), ("tampered payload", AD_LEN + 3), ("tampered tag", len(frame) - 1)):
        bad = bytearray(frame)
        bad[pos] ^= 0x01
        ok, why, _ = uav.open(bytes(bad))
        assert not ok, name
        results[name] = f"rejected ({why})"

    # Valid frame accepted once, replay rejected
    ok, why, _ = uav.open(frame)
    assert ok, why
    ok, why, _ = uav.open(frame)
    assert not ok and why == "replay"
    results["replay"] = f"rejected ({why})"

    # Wrong key
    eve_gcs, _ = link_pair(sysid=7)
    eve_gcs.tx_counter = 1_000_000          # fresh counter: must fail on the tag
    ok, why, _ = uav.open(eve_gcs.seal(msg, payload))
    assert not ok and why == "tag"
    results["wrong key"] = f"rejected ({why})"

    # Reordering inside the window is accepted, outside rejected
    frames = [gcs.seal(msg, payload) for _ in range(REPLAY_WINDOW + 2)]
    assert uav.open(frames[-1])[0]
    assert uav.open(frames[5])[0]                       # inside window
    assert uav.open(frames[0])[1] == "replay"           # too old
    results["reorder window"] = "ok"

    for k, v in results.items():
        print(f"  {k:18s} {v}")
    print("uav_packet self-test PASSED")


if __name__ == "__main__":
    _self_test()
