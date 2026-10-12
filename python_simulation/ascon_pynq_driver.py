from time import perf_counter
from typing import Dict, Optional

import numpy as np
from pynq import Overlay, allocate


CONTROL = 0x000
MODE = 0x004
STATUS = 0x008

KEY_127_96 = 0x010
KEY_95_64 = 0x014
KEY_63_32 = 0x018
KEY_31_0 = 0x01C

NONCE_127_96 = 0x020
NONCE_95_64 = 0x024
NONCE_63_32 = 0x028
NONCE_31_0 = 0x02C

TAG_CTRL = 0x040
TAG_127_96 = 0x044
TAG_95_64 = 0x048
TAG_63_32 = 0x04C
TAG_31_0 = 0x050

HASH_CTRL = 0x060
CYCLE_LO = 0x064
CYCLE_HI = 0x068

ST_ENC_READY = 1 << 0
ST_ENC_OUT_VALID = 1 << 1
ST_DEC_READY = 1 << 2
ST_DEC_OUT_VALID = 1 << 3
ST_HASH_READY = 1 << 4
ST_HASH_VALID = 1 << 5
ST_HASH_LAST = 1 << 6
ST_BUSY = 1 << 7

START_RESET = 1 << 0
START_ENCRYPT = 1 << 1
START_DECRYPT = 1 << 2
START_HASH = 1 << 3


class PYNQASCON:
    def __init__(
        self,
        bitfile: str,
        control_ip: Optional[str] = None,
        dma_names: Optional[Dict[str, str]] = None,
        pl_clock_hz: float = 100_000_000,
    ):
        self.overlay = Overlay(bitfile)
        self.pl_clock_hz = pl_clock_hz
        self.ip_name = self._pick_ip(control_ip, "ascon")
        self.mmio = getattr(self.overlay, self.ip_name).mmio

        if dma_names is None:
            dma_names = {
                "enc": "axi_dma_enc",
                "dec": "axi_dma_dec",
                "hash": "axi_dma_hash",
                "ad": "axi_dma_ad",
            }

        self.dmas = {}
        for role, name in dma_names.items():
            if hasattr(self.overlay, name):
                self.dmas[role] = getattr(self.overlay, name)

        self.reset_core()

    def _pick_ip(self, name: Optional[str], keyword: str) -> str:
        if name is not None:
            if hasattr(self.overlay, name):
                return name
            raise ValueError(f"Control IP '{name}' not found in overlay")

        candidates = [n for n in self.overlay.ip_dict.keys() if keyword in n.lower()]
        if not candidates:
            raise RuntimeError(f"No IP containing '{keyword}' found in overlay: {list(self.overlay.ip_dict)}")
        return candidates[0]

    def _write_u32(self, offset: int, value: int) -> None:
        self.mmio.write(offset, value & 0xFFFFFFFF)

    def _read_u32(self, offset: int) -> int:
        return self.mmio.read(offset) & 0xFFFFFFFF

    def _write_u64(self, offset: int, value: int) -> None:
        self._write_u32(offset + 0x0, (value >> 32) & 0xFFFFFFFF)
        self._write_u32(offset + 0x4, value & 0xFFFFFFFF)

    def _write_u128(self, offset: int, value: int) -> None:
        self._write_u32(offset + 0x0, (value >> 96) & 0xFFFFFFFF)
        self._write_u32(offset + 0x4, (value >> 64) & 0xFFFFFFFF)
        self._write_u32(offset + 0x8, (value >> 32) & 0xFFFFFFFF)
        self._write_u32(offset + 0xC, value & 0xFFFFFFFF)

    def _wait_status(self, mask: int, timeout_s: float = 2.0) -> int:
        t0 = perf_counter()
        while True:
            status = self._read_u32(STATUS)
            if status & mask:
                return status
            if perf_counter() - t0 > timeout_s:
                raise TimeoutError(f"Timeout waiting for status 0x{mask:08x}, got 0x{status:08x}")

    def reset_core(self) -> None:
        self._write_u32(CONTROL, START_RESET)

    def set_key_nonce(self, key: bytes, nonce: bytes) -> None:
        if len(key) != 16:
            raise ValueError("Key must be 16 bytes")
        if len(nonce) != 16:
            raise ValueError("Nonce must be 16 bytes")
        self._write_u128(KEY_127_96, int.from_bytes(key, "big"))
        self._write_u128(NONCE_127_96, int.from_bytes(nonce, "big"))

    def set_mode(self, decrypt: bool = False, has_ad: bool = False) -> None:
        mode = (1 if decrypt else 0) | ((1 if has_ad else 0) << 1)
        self._write_u32(MODE, mode)

    def _alloc_buffer(self, data: bytes) -> np.ndarray:
        buf = allocate(np.zeros(len(data), dtype=np.uint8))
        if len(data) > 0:
            buf[:] = np.frombuffer(data, dtype=np.uint8)
        return buf

    def _alloc_output(self, length: int) -> np.ndarray:
        return allocate(np.zeros(length, dtype=np.uint8))

    def _dma_transfer(self, role: str, data: bytes, out_length: int) -> bytes:
        if role not in self.dmas:
            raise RuntimeError(f"DMA for '{role}' not available in overlay")
        dma = self.dmas[role]
        in_buf = self._alloc_buffer(data)
        out_buf = self._alloc_output(out_length)

        dma.recvchannel.transfer(out_buf)
        dma.sendchannel.transfer(in_buf)
        dma.sendchannel.wait()
        dma.recvchannel.wait()

        return bytes(out_buf[:out_length])

    def aead(self, key: bytes, nonce: bytes, data: bytes, ad: bytes = b"", decrypt: bool = False) -> Dict[str, object]:
        if len(key) != 16 or len(nonce) != 16:
            raise ValueError("Key and nonce must be 16 bytes")

        self.reset_core()
        self.set_key_nonce(key, nonce)
        self.set_mode(decrypt=decrypt, has_ad=len(ad) > 0)

        control = START_DECRYPT if decrypt else START_ENCRYPT
        if len(ad) > 0 and "ad" in self.dmas:
            self._dma_transfer("ad", ad, len(ad))

        c0 = self._read_u32(CYCLE_LO) | (self._read_u32(CYCLE_HI) << 32)
        t0 = perf_counter()

        self._write_u32(CONTROL, control)
        out_data = self._dma_transfer("dec" if decrypt else "enc", data, len(data))

        status = self._wait_status(ST_DEC_OUT_VALID if decrypt else ST_ENC_OUT_VALID)
        c1 = self._read_u32(CYCLE_LO) | (self._read_u32(CYCLE_HI) << 32)
        t1 = perf_counter()

        return {
            "operation": "decrypt" if decrypt else "encrypt",
            "key": key,
            "nonce": nonce,
            "associated_data": ad,
            "input": data,
            "output": out_data,
            "status": status,
            "wall_seconds": t1 - t0,
            "pl_cycles": (c1 - c0) & 0xFFFFFFFFFFFFFFFF,
        }

    def hash256(self, message: bytes) -> Dict[str, object]:
        self.reset_core()
        self._write_u32(MODE, 0)

        c0 = self._read_u32(CYCLE_LO) | (self._read_u32(CYCLE_HI) << 32)
        t0 = perf_counter()

        digest = self._dma_transfer("hash", message, 32)
        status = self._wait_status(ST_HASH_VALID)

        c1 = self._read_u32(CYCLE_LO) | (self._read_u32(CYCLE_HI) << 32)
        t1 = perf_counter()

        return {
            "operation": "hash256",
            "input": message,
            "hash": digest,
            "status": status,
            "wall_seconds": t1 - t0,
            "pl_cycles": (c1 - c0) & 0xFFFFFFFFFFFFFFFF,
        }


if __name__ == "__main__":
    bitfile = "design_1.bit"
    driver = PYNQASCON(bitfile)

    key = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
    nonce = bytes.fromhex("101112131415161718191a1b1c1d1e1f")
    plaintext = b"Hello ASCON on Kria KV260!"

    result = driver.aead(key=key, nonce=nonce, data=plaintext, ad=b"", decrypt=False)
    print("Encrypt status:", hex(result["status"]))
    print("Ciphertext:", result["output"].hex())
    print("Wall time:", result["wall_seconds"])
    print("PL cycles:", result["pl_cycles"])

    hash_result = driver.hash256(b"abc")
    print("Hash status:", hex(hash_result["status"]))
    print("Hash:", hash_result["hash"].hex())
    print("Wall time:", hash_result["wall_seconds"])
    print("PL cycles:", hash_result["pl_cycles"])
