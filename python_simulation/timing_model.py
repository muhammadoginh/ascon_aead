"""
timing_model.py - latency of one AEAD operation (encrypt or decrypt of one
frame) for the hardware core, its interfaces, and software baselines.

Everything is derived from sim_params.json; see the 'source' fields there.
The core cycle model is the one verified in RTL (tb_encypt / tb_decrypt):

    cycles = 14 + 9 * (N - 1) + (1 if AD) + 14,   N = AD blocks + PT blocks

Run this file to print the per-message table (Table II style).
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass

from uav_packet import AD_LEN, MSG_TYPES, blocks, frame_len

HERE = os.path.dirname(os.path.abspath(__file__))


def load_params(path: str | None = None) -> dict:
    with open(path or os.path.join(HERE, "sim_params.json")) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Core (RTL-verified)
# ---------------------------------------------------------------------------
def core_cycles(ad_len: int, pt_len: int) -> int:
    n_ad = blocks(ad_len) if ad_len > 0 else 0
    n_pt = blocks(pt_len)
    return 14 + 9 * (n_ad + n_pt - 1) + (1 if n_ad else 0) + 14


def sw_rounds(ad_len: int, pt_len: int) -> int:
    """Permutation rounds of Ascon-AEAD128 (same structure as the core)."""
    n_ad = blocks(ad_len) if ad_len > 0 else 0
    n_pt = blocks(pt_len)
    return 12 + 8 * n_ad + 8 * (n_pt - 1) + 12


# ---------------------------------------------------------------------------
# Interface: words moved per operation (ascon_aead_axi_multi register flow)
# ---------------------------------------------------------------------------
def axilite_accesses(ad_len: int, pt_len: int) -> tuple[int, int]:
    """(input accesses, output accesses) for one operation.

    input : KEY 4 + NONCE 4 + MODE 1 + start 1 + per AD block (4 + ctrl 1)
            + per PT block (4 + ctrl 1)
    output: per PT block (status poll 1 + OUT 4) + tag (poll 1 + TAG 4)
    """
    n_ad = blocks(ad_len) if ad_len > 0 else 0
    n_pt = blocks(pt_len)
    acc_in = 10 + 5 * n_ad + 5 * n_pt
    acc_out = 5 * n_pt + 5
    return acc_in, acc_out


@dataclass
class OpTiming:
    """Timing of one AEAD operation, seconds."""
    t_in: float      # input transfer (bus)
    t_core: float    # core busy
    t_out: float     # output transfer (bus)
    shared_bus: bool

    @property
    def total(self) -> float:
        return self.t_in + self.t_core + self.t_out


def hw_op(params: dict, interface: str, ad_len: int, pt_len: int) -> OpTiming:
    fclk = params["core"]["fclk_hz"]
    t_core = core_cycles(ad_len, pt_len) / fclk
    p = params["interfaces"][interface]
    if interface == "axilite":
        a_in, a_out = axilite_accesses(ad_len, pt_len)
        t = p["access_ns"] * 1e-9
        return OpTiming(a_in * t, t_core, a_out * t, p["shared_bus"])
    if interface == "stream":
        bpc = p["bytes_per_cycle"]
        n_in = 32 + ad_len + pt_len          # key + nonce + AD + PT
        n_out = pt_len + 16                  # CT/PT + tag
        t_in = (p["setup_cycles"] + -(-n_in // bpc)) / fclk
        t_out = (p["setup_cycles"] + -(-n_out // bpc)) / fclk
        return OpTiming(t_in, t_core, t_out, p["shared_bus"])
    raise ValueError(f"unknown interface {interface!r}")


def sw_op(params: dict, kind: str, ad_len: int, pt_len: int, decrypt: bool) -> float:
    """Software AEAD time per operation, seconds."""
    p = params["software"][kind]
    if kind == "a9_c":
        return (sw_rounds(ad_len, pt_len) * p["round_ns"] + p["per_message_ns"]) * 1e-9
    if kind == "esp32_tinyjambu_prior":
        return (p["decrypt_us"] if decrypt else p["encrypt_us"]) * 1e-6
    raise ValueError(f"unknown software model {kind!r}")


def airtime(params: dict, payload_len: int, aead: bool) -> float:
    link = params["link"]
    nbytes = frame_len(payload_len, aead) + link["ip_udp_overhead_bytes"]
    return nbytes * 8 / link["rate_bps"]


# ---------------------------------------------------------------------------
# Table: per-message latency without / with AEAD (no contention)
# ---------------------------------------------------------------------------
def message_table(params: dict) -> list[dict]:
    rows = []
    link = params["link"]
    base = link["base_delay_ms"] * 1e-3
    proc = (params["gateway"]["processing_us"] + params["uav"]["processing_us"]) * 1e-6
    for m in MSG_TYPES.values():
        ad, pt = AD_LEN, m.payload_len
        plain = proc + airtime(params, pt, False) + base
        aead_air = proc + airtime(params, pt, True) + base
        hw_s = hw_op(params, "stream", ad, pt)
        hw_a = hw_op(params, "axilite", ad, pt)
        sw = sw_op(params, "a9_c", ad, pt, False) + sw_op(params, "a9_c", ad, pt, True)
        rows.append(dict(
            msg=m.name, cls=m.traffic_class, payload=pt,
            frame_plain=frame_len(pt, False), frame_aead=frame_len(pt, True),
            core_cc=core_cycles(ad, pt),
            core_ns=hw_s.t_core * 1e9,
            # one encrypt (sender) + one decrypt (receiver)
            plain_us=plain * 1e6,
            hw_stream_us=(aead_air + 2 * hw_s.total) * 1e6,
            hw_axilite_us=(aead_air + 2 * hw_a.total) * 1e6,
            sw_a9_us=(aead_air + sw) * 1e6,
            crypto_hw_stream_us=2 * hw_s.total * 1e6,
            crypto_hw_axilite_us=2 * hw_a.total * 1e6,
            crypto_sw_a9_us=sw * 1e6,
        ))
    return rows


if __name__ == "__main__":
    P = load_params()
    print(f"fclk = {P['core']['fclk_hz'] / 1e6:.1f} MHz, link {P['link']['rate_bps'] / 1e6:g} Mbps\n")
    hdr = f"{'message':32s} {'B':>4s} {'cc':>4s} {'core ns':>8s} {'plain us':>9s} {'HW-str us':>10s} {'HW-AXIL us':>11s} {'SW-A9 us':>9s}"
    print(hdr)
    print("-" * len(hdr))
    for r in message_table(P):
        print(f"{r['msg']:32s} {r['payload']:4d} {r['core_cc']:4d} {r['core_ns']:8.1f} "
              f"{r['plain_us']:9.1f} {r['hw_stream_us']:10.1f} {r['hw_axilite_us']:11.1f} {r['sw_a9_us']:9.1f}")
