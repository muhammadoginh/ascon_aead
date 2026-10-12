"""
gen_packet_vectors.py - RTL test vectors from real UAV frames.

Builds MAVLink-style frames with uav_packet.py (AD = 15-byte header +
counter, payload = MAVLink message) and writes them in the same format as
gen_test_vectors.py, so tb_encypt, tb_decrypt, tb_ascon_aead_axi and
tb_ascon_aead_axi_multi run them unchanged.

    python3 gen_packet_vectors.py                 # packet_encrypt_tv.txt / packet_decrypt_tv.txt
    python3 gen_packet_vectors.py --replace       # overwrite encrypt_tv.txt / decrypt_tv.txt
                                                  # (originals kept as *.orig)

The testbenches read 100 vectors and hold at most 11 blocks per message
(payload <= 175 B), which covers every MAVLink message type used here.
"""

from __future__ import annotations

import argparse
import os
import random
import shutil

import uav_packet as up
from ascon import ascon_encrypt

HERE = os.path.dirname(os.path.abspath(__file__))
N_VECTORS = 100


def blocks_hex(data: bytes, n_blocks: int) -> list[str]:
    out = []
    for j in range(n_blocks):
        chunk = data[16 * j:16 * (j + 1)]
        chunk = chunk + b"\x00" * (16 - len(chunk))
        out.append(f"{int.from_bytes(chunk, 'big'):032x}")
    return out


def make_frames(seed: int) -> list[dict]:
    rng = random.Random(seed)
    msgs = [m for m in up.MSG_TYPES.values() if m.traffic_class != "bulk"]
    frames = []
    for i in range(N_VECTORS):
        m = msgs[i % len(msgs)]
        keys = up.LinkKeys(key=rng.randbytes(16), salt=rng.randbytes(6), sysid=1 + rng.randrange(250))
        ctr = rng.randrange(1 << up.COUNTER_BITS)
        ad = up.build_ad(m.payload_len, ctr, keys.sysid, keys.compid, m.msgid)
        nonce = up.make_nonce(keys.salt, keys.sysid, keys.compid, m.direction, ctr)
        pt = rng.randbytes(m.payload_len)
        res = ascon_encrypt(keys.key, nonce, ad, pt)
        frames.append(dict(key=keys.key, nonce=nonce, ad=ad, pt=pt, ct=res[:len(pt)], tag=res[len(pt):]))
    return frames


def write(path: str, frames: list[dict], encrypt: bool):
    with open(path, "w") as f:
        for fr in frames:
            ad, pt, ct = fr["ad"], fr["pt"], fr["ct"]
            f.write(f"{fr['key'].hex()}\n{fr['nonce'].hex()}\n{len(ad)}\n")
            for line in blocks_hex(ad, len(ad) // 16 + 1):
                f.write(line + "\n")
            f.write(f"{len(pt)}\n")
            n = len(pt) // 16 + 1
            if encrypt:
                for line in blocks_hex(pt, n) + blocks_hex(ct, n):
                    f.write(line + "\n")
                f.write(fr["tag"].hex() + "\n")
            else:
                for line in blocks_hex(ct, n):
                    f.write(line + "\n")
                f.write(fr["tag"].hex() + "\n")
                for line in blocks_hex(pt, n):
                    f.write(line + "\n")
                f.write(fr["tag"].hex() + "\n")
    print(f"wrote {os.path.relpath(path, HERE)} ({len(frames)} frames)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--replace", action="store_true",
                    help="write encrypt_tv.txt / decrypt_tv.txt (originals kept as *.orig)")
    a = ap.parse_args()

    frames = make_frames(a.seed)
    names = ("encrypt_tv.txt", "decrypt_tv.txt") if a.replace else ("packet_encrypt_tv.txt", "packet_decrypt_tv.txt")
    for name, enc in zip(names, (True, False)):
        path = os.path.join(HERE, name)
        if a.replace and os.path.exists(path) and not os.path.exists(path + ".orig"):
            shutil.copy(path, path + ".orig")
        write(path, frames, enc)


if __name__ == "__main__":
    main()
