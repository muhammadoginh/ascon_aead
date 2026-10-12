"""
plot_results.py - figures and tables for the letter from the simulation
(results/*.csv, written by multilink_sim.py --sweep paper) and the Vivado
Fmax search (build/fmax_ooc/<part>/ascon_aead_array_K*/summary.txt).

Outputs (figures/): PDF for LaTeX + PNG preview
    fig_multilink_delay     C2 gateway crypto delay (p99) vs links, K = 1/2/4/8,
                            panels: streaming interface | AXI-Lite interface
    fig_multilink_delivery  bulk delivered share vs links (saturation)
    fig_crypto_overhead     AEAD time (encrypt + decrypt) per message type
    fig_scheduler           C2 delay, priority vs FIFO scheduling (K = 1)
    fig_scaling             ascon_aead_array #(K) after place and route: LUT / FF and
                            closed-timing Fmax vs K (build/fmax_ooc/.../summary.txt)
    table_latency.tex       Table II: latency without / with AEAD per message

Sizes follow IEEE: single column 3.5 in, double column 7.16 in, 8 pt text.

    python3 plot_results.py [--scenario highrate]
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.ticker import FuncFormatter  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")
FIGURES = os.path.join(HERE, "figures")

# ---------------------------------------------------------------------------
# Style: reference categorical palette, fixed slot order (blue, orange, aqua,
# yellow). Every series also has its own marker / line style / hatch so the
# figures survive greyscale printing.
# ---------------------------------------------------------------------------
SLOT = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]
MARKERS = ["o", "s", "^", "D"]
LINESTYLES = ["-", "--", "-.", ":"]
HATCHES = ["", "////", "\\\\\\\\", "xx"]
INK = "#0b0b0b"
INK2 = "#52514e"
GRID = "#d9d8d4"

SINGLE = 3.5
DOUBLE = 7.16

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Times", "Nimbus Roman", "DejaVu Serif"],
    "mathtext.fontset": "stix",
    "font.size": 8,
    "axes.titlesize": 8,
    "axes.labelsize": 8,
    "legend.fontsize": 7,
    "xtick.labelsize": 7,
    "ytick.labelsize": 7,
    "axes.edgecolor": INK2,
    "axes.labelcolor": INK,
    "xtick.color": INK2,
    "ytick.color": INK2,
    "text.color": INK,
    "axes.linewidth": 0.6,
    "grid.color": GRID,
    "grid.linewidth": 0.5,
    "lines.linewidth": 1.4,
    "lines.markersize": 4,
    "legend.frameon": False,
    "savefig.bbox": "tight",
    "savefig.pad_inches": 0.02,
    "pdf.fonttype": 42,
})


def read_csv(path):
    if not os.path.exists(path):
        print(f"skip: {path} not found")
        return None
    with open(path) as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k, v in r.items():
            try:
                r[k] = float(v)
            except (TypeError, ValueError):
                pass
    return rows


def save(fig, name):
    os.makedirs(FIGURES, exist_ok=True)
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(FIGURES, f"{name}.{ext}"), dpi=300)
    plt.close(fig)
    print(f"wrote figures/{name}.pdf/.png")


def style_axes(ax):
    ax.grid(True, which="major", axis="y")
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)


def series(rows, **match):
    return [r for r in rows if all(r.get(k) == v for k, v in match.items())]


def num_fmt(x, _pos=None):
    if x >= 1:
        return f"{x:g}"
    return f"{x:.2g}"


# ---------------------------------------------------------------------------
# Multi-link figures
# ---------------------------------------------------------------------------
IFACE_TITLE = {"hw_stream": "(a) Streaming interface (per-core data path)",
               "hw_axilite": "(b) AXI4-Lite interface (one shared bus)"}


def fig_multilink_delay(rows, scenario):
    fig, axes = plt.subplots(1, 2, figsize=(DOUBLE, 2.2), sharey=True)
    for ax, iface in zip(axes, ("hw_stream", "hw_axilite")):
        for i, k in enumerate((1, 2, 4, 8)):
            s = sorted(series(rows, scenario=scenario, config=iface, cores=float(k), policy="priority"),
                       key=lambda r: r["links"])
            if not s:
                continue
            ax.plot([r["links"] for r in s], [r["c2_gw_p99_us"] for r in s],
                    color=SLOT[i], marker=MARKERS[i], linestyle=LINESTYLES[i], label=f"K = {k}")
        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.xaxis.set_major_formatter(FuncFormatter(num_fmt))
        ax.yaxis.set_major_formatter(FuncFormatter(num_fmt))
        ax.set_xlabel("Concurrent UAV links N")
        ax.set_title(IFACE_TITLE[iface], loc="left")
        style_axes(ax)
    axes[0].set_ylabel("C2 crypto delay at GCS, p99 (µs)")
    axes[0].legend(loc="upper left", ncol=2)
    save(fig, "fig_multilink_delay")


def fig_multilink_delivery(rows, scenario):
    fig, axes = plt.subplots(1, 2, figsize=(DOUBLE, 2.0), sharey=True)
    for ax, iface in zip(axes, ("hw_stream", "hw_axilite")):
        for i, k in enumerate((1, 2, 4, 8)):
            s = sorted(series(rows, scenario=scenario, config=iface, cores=float(k), policy="priority"),
                       key=lambda r: r["links"])
            if not s:
                continue
            ax.plot([r["links"] for r in s], [100 * r["bulk_delivered_ratio"] for r in s],
                    color=SLOT[i], marker=MARKERS[i], linestyle=LINESTYLES[i], label=f"K = {k}")
        ax.set_xscale("log")
        ax.xaxis.set_major_formatter(FuncFormatter(num_fmt))
        ax.set_ylim(0, 105)
        ax.set_xlabel("Concurrent UAV links N")
        ax.set_title(IFACE_TITLE[iface], loc="left")
        style_axes(ax)
    axes[0].set_ylabel("Bulk data delivered (%)")
    axes[0].legend(loc="lower left", ncol=2)
    save(fig, "fig_multilink_delivery")


def fig_scheduler(rows, scenario):
    fig, ax = plt.subplots(figsize=(SINGLE, 2.1))
    for i, (pol, label) in enumerate((("priority", "C2-first scheduling"), ("fifo", "FIFO scheduling"))):
        s = sorted(series(rows, scenario=scenario, config="hw_stream", cores=1.0, policy=pol),
                   key=lambda r: r["links"])
        if not s:
            continue
        ax.plot([r["links"] for r in s], [r["c2_gw_p99_us"] for r in s],
                color=SLOT[i], marker=MARKERS[i], linestyle=LINESTYLES[i], label=label)
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.xaxis.set_major_formatter(FuncFormatter(num_fmt))
    ax.yaxis.set_major_formatter(FuncFormatter(num_fmt))
    ax.set_xlabel("Concurrent UAV links N (K = 1, streaming)")
    ax.set_ylabel("C2 crypto delay, p99 (µs)")
    ax.legend(loc="upper left")
    style_axes(ax)
    save(fig, "fig_scheduler")


# ---------------------------------------------------------------------------
# Per-message figure / table
# ---------------------------------------------------------------------------
SHORT = {"HEARTBEAT": "HB", "ATTITUDE": "ATT", "GLOBAL_POSITION_INT": "GPOS",
         "COMMAND_LONG": "CMD", "SET_POSITION_TARGET_LOCAL_NED": "SPT", "BULK_CHUNK": "BULK"}
LONG = {"HEARTBEAT": "HEARTBEAT", "ATTITUDE": "ATTITUDE", "GLOBAL_POSITION_INT": "GLOBAL\\_POS\\_INT",
        "COMMAND_LONG": "COMMAND\\_LONG", "SET_POSITION_TARGET_LOCAL_NED": "SET\\_POS\\_TARGET",
        "BULK_CHUNK": "Bulk chunk"}


def fig_crypto_overhead(rows):
    cols = [("crypto_hw_stream_us", "HW, streaming"),
            ("crypto_hw_axilite_us", "HW, AXI4-Lite"),
            ("crypto_sw_a9_us", "SW, Cortex-A9")]
    fig, ax = plt.subplots(figsize=(SINGLE, 2.3))
    n = len(rows)
    w = 0.26
    for i, (key, label) in enumerate(cols):
        xs = [j + (i - 1) * w for j in range(n)]
        ax.bar(xs, [r[key] for r in rows], width=w - 0.03, color=SLOT[i], hatch=HATCHES[i],
               edgecolor="white", linewidth=0.4, label=label)
    ax.set_yscale("log")
    ax.yaxis.set_major_formatter(FuncFormatter(num_fmt))
    ax.set_xticks(range(n))
    ax.set_xticklabels([f"{SHORT.get(r['msg'], r['msg'])}\n{int(r['payload'])} B" for r in rows],
                       rotation=0, fontsize=7)
    ax.set_ylabel("Encrypt + decrypt time (µs)")
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.0), ncol=3, handlelength=1.2, columnspacing=0.8)
    style_axes(ax)
    save(fig, "fig_crypto_overhead")


def table_latency(rows, params):
    fclk = params["core"]["fclk_hz"] / 1e6
    rate = params["link"]["rate_bps"] / 1e6
    lines = [
        r"% Generated by python_simulation/plot_results.py - do not edit by hand",
        r"\begin{table}[t]",
        r"\caption{Per-message latency without and with Ascon-AEAD128 (encrypt at the sender,",
        rf"decrypt and verify at the receiver), {rate:g}~Mbps link, core at {fclk:.1f}~MHz}}",
        r"\label{tab:latency}",
        r"\centering",
        r"\footnotesize",
        r"\setlength{\tabcolsep}{3pt}",
        r"\begin{tabular}{lrrrrrrr}",
        r"\hline",
        r"Message & Payload & Core & Core & Plain & HW AXIS & HW AXI-L & SW A9$^\dagger$ \\",
        r" & (B) & (cc) & (ns) & ($\mu$s) & ($\mu$s) & ($\mu$s) & ($\mu$s) \\",
        r"\hline",
    ]
    for r in rows:
        name = LONG.get(r["msg"], r["msg"])
        lines.append(f"{name} & {int(r['payload'])} & {int(r['core_cc'])} & {r['core_ns']:.0f} & "
                     f"{r['plain_us']:.0f} & {r['hw_stream_us']:.0f} & {r['hw_axilite_us']:.0f} & "
                     f"{r['sw_a9_us']:.0f} \\\\")
    lines += [
        r"\hline",
        r"\multicolumn{8}{l}{\scriptsize End-to-end: processing + crypto + air time (IP/UDP incl.) + 1~ms link delay.}\\",
        r"\multicolumn{8}{l}{\scriptsize $^\dagger$Software timing to be replaced by the PYNQ-Z1 measurement.}\\",
        r"\end{tabular}",
        r"\end{table}",
    ]
    os.makedirs(FIGURES, exist_ok=True)
    path = os.path.join(FIGURES, "table_latency.tex")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote figures/table_latency.tex")


# ---------------------------------------------------------------------------
# Resource scaling (Vivado)
# ---------------------------------------------------------------------------
def read_arch_scaling():
    """Closed-timing post-route results of ascon_aead_array #(K) (find_fmax_ooc.tcl)."""
    rows = []
    base = os.path.join(HERE, "..", "build", "fmax_ooc", "xc7z020clg400-1")
    for k in (1, 2, 4, 8):
        path = os.path.join(base, f"ascon_aead_array_K{k}", "summary.txt")
        r = read_csv(path)
        if r:
            r = r[0]
            r["K"] = k
            rows.append(r)
    return rows


def fig_scaling(rows):
    """(a) LUT / FF vs K, (b) closed-timing Fmax vs K - one axis per panel."""
    rows = sorted(rows, key=lambda r: r["K"])
    ks = [int(r["K"]) for r in rows]
    xs = list(range(len(ks)))
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(SINGLE, 1.9), gridspec_kw={"width_ratios": [1.35, 1]})

    w = 0.38
    ax1.bar([x - w / 2 for x in xs], [r["lut"] for r in rows], width=w - 0.04, color=SLOT[0],
            hatch=HATCHES[0], edgecolor="white", linewidth=0.4, label="LUTs")
    ax1.bar([x + w / 2 for x in xs], [r["ff"] for r in rows], width=w - 0.04, color=SLOT[1],
            hatch=HATCHES[1], edgecolor="white", linewidth=0.4, label="FFs")
    for x, r in zip(xs, rows):
        ax1.text(x - w / 2, r["lut"], f"{int(r['lut']):,}", ha="center", va="bottom", fontsize=5.5, color=INK2)
    ax1.set_xticks(xs)
    ax1.set_xticklabels([str(k) for k in ks])
    ax1.set_xlabel("Cores K")
    ax1.set_ylabel("Resources")
    ax1.yaxis.set_major_formatter(FuncFormatter(lambda v, _p: f"{v / 1000:g}k" if v else "0"))
    ax1.legend(loc="upper left", handlelength=1.2)
    ax1.set_title("(a)", loc="left")
    style_axes(ax1)

    ax2.plot(xs, [r["fmax_mhz"] for r in rows], color=SLOT[0], marker=MARKERS[0])
    for x, r in zip(xs, rows):
        ax2.text(x, r["fmax_mhz"] + 8, f"{r['fmax_mhz']:.1f}", ha="center", va="bottom", fontsize=5.5, color=INK2)
    ax2.set_xticks(xs)
    ax2.set_xticklabels([str(k) for k in ks])
    ax2.set_xlabel("Cores K")
    ax2.set_ylabel("$f_{\\max}$ (MHz)")
    # Zero-based axis: the K-to-K differences (a few MHz) are place-and-route
    # variation, not a trend; a truncated axis would exaggerate them.
    ax2.set_ylim(0, 1.25 * max(r["fmax_mhz"] for r in rows))
    ax2.set_xlim(-0.5, len(ks) - 0.5)
    ax2.set_title("(b)", loc="left")
    style_axes(ax2)

    fig.tight_layout(w_pad=1.0)
    save(fig, "fig_scaling")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", default="highrate", help="scenario for the multi-link figures")
    a = ap.parse_args()

    with open(os.path.join(HERE, "sim_params.json")) as f:
        params = json.load(f)

    lat = read_csv(os.path.join(RESULTS, "latency_table.csv"))
    if lat:
        fig_crypto_overhead(lat)
        table_latency(lat, params)

    ml = read_csv(os.path.join(RESULTS, "multilink.csv"))
    if ml:
        fig_multilink_delay(ml, a.scenario)
        fig_multilink_delivery(ml, a.scenario)
        fig_scheduler(ml, a.scenario)

    sc = read_arch_scaling()
    if sc:
        fig_scaling(sc)


if __name__ == "__main__":
    main()
