"""
draw_architecture.py - Fig. 1 of the letter: secure multi-link architecture.

    (a) N UAV links -> gateway: packet handling + replay check, C2-first
        scheduler, K Ascon-AEAD128 cores
    (b) frame format: 15-byte AD (header + counter extension), ciphertext, tag
    (c) core: one-hot control unit + datapath with a single iterative round

Writes figures/fig_architecture.pdf and .png (single IEEE column, 3.5 in).

    python3 draw_architecture.py
"""

import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch, Rectangle  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "figures")

# Palette: reference slots (blue, orange, aqua) + neutrals; every block also
# carries a text label, so colour never carries meaning alone.
BLUE = "#2a78d6"
BLUE_L = "#cde2fb"
ORANGE = "#eb6834"
ORANGE_L = "#fbdccf"
AQUA_L = "#c9efe1"
GREY_L = "#f0efec"
GREY = "#8a8985"
INK = "#0b0b0b"
INK2 = "#52514e"

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Times", "Nimbus Roman", "DejaVu Serif"],
    "mathtext.fontset": "stix",
    "font.size": 7,
    "pdf.fonttype": 42,
    "savefig.bbox": "tight",
    "savefig.pad_inches": 0.02,
})

W, H = 3.5, 3.80          # inches; coordinates below are in inches


def box(ax, x, y, w, h, text="", fc=GREY_L, ec=INK2, lw=0.6, fs=6.5, bold=False,
        round_=0.03, color=INK):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle=f"round,pad=0,rounding_size={round_}",
                                fc=fc, ec=ec, lw=lw))
    if text:
        ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=fs, color=color,
                fontweight="bold" if bold else "normal", linespacing=1.1)


def arrow(ax, x0, y0, x1, y1, color=INK2, lw=0.7, style="-|>", ms=5):
    ax.add_patch(FancyArrowPatch((x0, y0), (x1, y1), arrowstyle=style, mutation_scale=ms,
                                 color=color, lw=lw, shrinkA=0, shrinkB=0))


def label(ax, x, y, text):
    ax.text(x, y, text, ha="left", va="top", fontsize=7.5, fontweight="bold", color=INK)


def panel_a(ax, y0):
    """System: N UAVs -> gateway with K cores. Panel spans y0 .. y0+1.45."""
    label(ax, 0.0, y0 + 1.45, "(a)")
    # Legend row (top): link directions and per-link state
    ly = y0 + 1.37
    arrow(ax, 0.30, ly, 0.50, ly, color=BLUE)
    ax.text(0.53, ly, "telemetry", ha="left", va="center", fontsize=5.8, color=INK2)
    arrow(ax, 1.20, ly, 1.00, ly, color=ORANGE)
    ax.text(1.23, ly, "C2", ha="left", va="center", fontsize=5.8, color=INK2)
    ax.text(1.45, ly, "per link: own key, nonce counter, replay window", ha="left", va="center",
            fontsize=5.8, color=INK2)

    # UAVs
    uav_y = [y0 + 0.94, y0 + 0.60, y0 + 0.06]
    for yy, name in zip(uav_y, ["UAV$_1$", "UAV$_2$", "UAV$_N$"]):
        box(ax, 0.22, yy, 0.52, 0.26, name, fs=6.5)
    ax.text(0.48, y0 + 0.44, "$\\vdots$", ha="center", va="center", fontsize=8, color=INK2)

    gx = 1.12
    for yy in uav_y:
        yc = yy + 0.13
        arrow(ax, 0.76, yc + 0.035, gx - 0.02, yc + 0.035, color=BLUE)    # telemetry
        arrow(ax, gx - 0.02, yc - 0.035, 0.76, yc - 0.035, color=ORANGE)  # C2

    # Gateway
    box(ax, gx, y0, 2.36, 1.26, fc="white", ec=INK2, lw=0.7, round_=0.04)
    ax.text(gx + 0.06, y0 + 1.22, "Gateway (GCS)", ha="left", va="top", fontsize=6.5,
            fontweight="bold", color=INK)
    box(ax, gx + 0.08, y0 + 0.08, 0.62, 0.96, "Frame I/O\n+ replay\ncheck", fs=6)
    box(ax, gx + 0.82, y0 + 0.08, 0.56, 0.96, "C2-first\nsched-\nuler", fc=ORANGE_L, ec=ORANGE, fs=6)
    arrow(ax, gx + 0.70, y0 + 0.56, gx + 0.82, y0 + 0.56)

    cx = gx + 1.52
    core_y = [y0 + 0.80, y0 + 0.50, y0 + 0.08]
    for yy, name in zip(core_y, ["Ascon core 0", "Ascon core 1", "Ascon core $K\\!-\\!1$"]):
        box(ax, cx, yy, 0.76, 0.24, name, fc=BLUE_L, ec=BLUE, fs=6)
        arrow(ax, gx + 1.38, yy + 0.12, cx, yy + 0.12)
    ax.text(cx + 0.38, y0 + 0.40, "$\\vdots$", ha="center", va="center", fontsize=8, color=INK2)


def panel_b(ax, y0):
    """Frame format. Panel spans y0 .. y0+0.85."""
    label(ax, 0.0, y0 + 0.85, "(b)")
    x, y, h = 0.22, y0 + 0.36, 0.24
    segs = [
        (0.78, "Header\n10 B", GREY_L, INK2),
        (0.44, "Ctr.\n5 B", GREY_L, INK2),
        (1.32, "Ciphertext (payload)\nlen B", BLUE_L, BLUE),
        (0.72, "Tag\n16 B", AQUA_L, "#1baf7a"),
    ]
    xs = []
    for w, t, fc, ec in segs:
        ax.add_patch(Rectangle((x, y), w, h, fc=fc, ec=ec, lw=0.6))
        ax.text(x + w / 2, y + h / 2, t, ha="center", va="center", fontsize=5.8, color=INK, linespacing=1.0)
        xs.append((x, w))
        x += w
    ad_x0, ad_x1 = xs[0][0], xs[1][0] + xs[1][1]
    by = y + h + 0.04
    ax.plot([ad_x0, ad_x0, ad_x1, ad_x1], [by, by + 0.05, by + 0.05, by], color=INK2, lw=0.6)
    ax.text((ad_x0 + ad_x1) / 2, by + 0.07, "AD = 15 B, authenticated", ha="center", va="bottom",
            fontsize=5.8, color=INK2)
    ex0, ew = xs[2]
    ax.plot([ex0, ex0, ex0 + ew, ex0 + ew], [by, by + 0.05, by + 0.05, by], color=BLUE, lw=0.6)
    ax.text(ex0 + ew / 2, by + 0.07, "encrypted", ha="center", va="bottom", fontsize=5.8, color=BLUE)
    ax.text(0.22, y - 0.05,
            "Nonce (not sent): salt$_{6\\,\\mathrm{B}}$ $\\|$ SYSID $\\|$ COMPID $\\|$ dir $\\|$ counter$_{7\\,\\mathrm{B}}$\n"
            "Receiver: replay window on the counter, plaintext released after the tag check",
            ha="left", va="top", fontsize=5.6, color=INK2, linespacing=1.3)


def panel_c(ax, y0):
    """Core: control unit + datapath. Panel spans y0 .. y0+1.25."""
    label(ax, 0.0, y0 + 1.25, "(c)")
    box(ax, 0.22, y0 + 0.04, 0.80, 1.12,
        "Control unit\n\none-hot FSM,\nround counter $i$,\nregistered\ncontrols\n\n9 cycles per\n128-bit block",
        fc=ORANGE_L, ec=ORANGE, fs=5.8)
    arrow(ax, 1.02, y0 + 0.60, 1.18, y0 + 0.60, color=ORANGE)

    dx = 1.18
    box(ax, dx, y0 + 0.04, 2.30, 1.12, fc="white", ec=INK2, lw=0.7, round_=0.04)
    ax.text(dx + 0.06, y0 + 1.12, "Datapath", ha="left", va="top", fontsize=6.5, fontweight="bold")

    sx, sy, sw, sh = dx + 0.10, y0 + 0.30, 0.42, 0.56
    box(ax, sx, sy, sw, sh, "State\n320 b", fc=BLUE_L, ec=BLUE, fs=6)
    box(ax, dx + 0.10, y0 + 0.08, 0.42, 0.16, "Key", fs=5.6)

    rx = dx + 0.66
    rw1, rw2 = 0.62, 0.66
    ry, rh = y0 + 0.62, 0.26
    box(ax, rx, ry, rw1, rh, "S-box\n(LUT6)", fs=5.6)
    box(ax, rx + rw1 + 0.12, ry, rw2, rh, "Linear + 2:1\nmux (LUT5)", fs=5.6)
    nry, nrh = y0 + 0.14, 0.30
    box(ax, rx, nry, rw1 + 0.12 + rw2, nrh, "load / absorb (byte masks) /\nkey and padding XOR", fs=5.6)

    # state -> S-box -> linear/mux
    arrow(ax, sx + sw, ry + rh / 2, rx, ry + rh / 2)
    arrow(ax, rx + rw1, ry + rh / 2, rx + rw1 + 0.12, ry + rh / 2)
    # state -> non-round path, key -> non-round path
    arrow(ax, sx + sw, nry + nrh * 0.70, rx, nry + nrh * 0.70)
    arrow(ax, dx + 0.52, y0 + 0.16, rx, y0 + 0.16)
    # non-round path -> mux (enters the mux box from below)
    mx = rx + rw1 + 0.12 + rw2 * 0.5
    arrow(ax, mx, nry + nrh, mx, ry)
    # feedback: mux -> state (the round loop)
    fx = rx + rw1 + 0.12 + rw2
    top = y0 + 0.99
    ax.plot([fx, fx + 0.08, fx + 0.08, sx + sw / 2], [ry + rh / 2, ry + rh / 2, top, top], color=BLUE, lw=0.8)
    arrow(ax, sx + sw / 2, top, sx + sw / 2, sy + sh, color=BLUE)
    ax.text((sx + sw / 2 + fx) / 2 + 0.25, top + 0.015, "round loop: 2 logic levels", ha="center",
            va="bottom", fontsize=5.4, color=BLUE)


def main():
    fig = plt.figure(figsize=(W, H))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, W)
    ax.set_ylim(0, H)
    ax.axis("off")

    panel_a(ax, 2.30)
    panel_b(ax, 1.32)
    panel_c(ax, 0.0)

    os.makedirs(OUT, exist_ok=True)
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(OUT, f"fig_architecture.{ext}"), dpi=300)
    print("wrote figures/fig_architecture.pdf/.png")


if __name__ == "__main__":
    main()
