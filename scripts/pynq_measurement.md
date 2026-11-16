# PYNQ-Z1 measurement and Vivado 2026.1 re-runs

Two independent tasks. Part A gives Table II of the letter; Part B gives the final numbers of Table I and Fig. 2.

---

## Part A – Per-message latency through the gateway (PYNQ-Z1)

What is measured: for each MAVLink message type and direction, the time from the ARM processor starting to write a frame into the gateway until it has read back the verified output and tag (`gw_run()` in `pynq/gw_driver.c`). Every run is checked against the expected output; any mismatch aborts.

The driver has been verified against the RTL in Verilator (`pynq/sim`,
K = 1, 4, 8, 400 messages each, 0 failures), so a failure on the board points to the overlay / board setup, not to the driver logic.

### Files to copy to the board

Everything is collected in **`build/pynq/board_package/`** (overlay K = 4 at 142.86 MHz, C sources, Makefile, loader, vectors). Copy the whole folder to the board, e.g. to `/home/xilinx/ascon/`:

```shell
scp -r build/pynq/board_package xilinx@<pynq-ip>:/home/xilinx/ascon
```

(`ascon_gw.bit` and `ascon_gw.hwh` must keep the same basename.)

### Steps on the board

```shell
cd /home/xilinx/ascon
make                                   # builds gw_latency (gcc on the board)
sudo python3 load_overlay.py           # loads ascon_gw.bit, prints K and FCLK0
sudo ./gw_latency -f <FCLK0 MHz printed above>      # 142.857 for the current overlay
```

Options: `-r 1000` repetitions per frame (default), `-w 50` warm-up runs, `-c 0` core index, `-o gw_latency.csv` output file.

Expected output: a table per message type × direction (HEARTBEAT,
ATTITUDE, GLOBAL_POSITION_INT, COMMAND_LONG, SET_POSITION_TARGET; enc / dec) with the core cycles, mean / p50 / p99 latency from the PL cycle counter, and the p99 from the Linux clock, followed by `all 200 x 1000 runs verified`.

### Send back

- `gw_latency.csv`
- the full console output (contains K, FCLK0, timer overhead)
- `build_info.txt` from the overlay directory (K, clock, WNS, LUT/FF)

### If something fails

| Symptom                           | Likely cause                                                       |
| --------------------------------- | ------------------------------------------------------------------ |
| `no Ascon gateway at 0x43c00000`  | overlay not loaded, or `.hwh` missing / renamed                    |
| `FAIL ... timeout`                | PL clock or reset not running – reload the overlay                 |
| `FAIL ... mismatch`               | wrong vector files (use the `packet_*` files from this repository) |
| `open /dev/mem` permission denied | run with `sudo`                                                    |

---

## Part B – Vivado 2026.1 re-runs

All scripts run from the project root and do not need the GUI. Close the project in the GUI before Part B.3.

### B.1 Functional regressions (must all PASS before anything else)

```tcl
mkdir regression
vivado -mode batch -log regression/vivado.log -journal regression/vivado.jou -source scripts/run_encrypt_regression.tcl
vivado -mode batch -log regression/vivado.log -journal regression/vivado.jou -source scripts/run_decrypt_regression.tcl
vivado -mode batch -log regression/vivado.log -journal regression/vivado.jou -source scripts/run_axi_regression.tcl
vivado -mode batch -log regression/vivado.log -journal regression/vivado.jou -source scripts/run_axi_multi_regression.tcl -tclargs -k 4
```

### B.2 Architecture Fmax, K = 1, 2, 4, 8 (Table I, Fig. 2)

Pure architecture (`ascon_aead_array`, no bus wrapper), out of context, post place-and-route, tightest period with WNS ≥ 0 and WHS ≥ 0:

```tcl
cd build
vivado -mode batch -log ./fmax_ooc_k1.log -journal ./fmax_ooc_k1.jou -source ../scripts/find_fmax_ooc.tcl -tclargs -top ascon_aead_array -k 1 -clk clk -max_runs 1 -start 3.55 -strat ae
vivado -mode batch -log ./fmax_ooc_k2.log -journal ./fmax_ooc_k2.jou -source ../scripts/find_fmax_ooc.tcl -tclargs -top ascon_aead_array -k 2 -clk clk -max_runs 1 -start 3.60 -strat ae
vivado -mode batch -log ./fmax_ooc_k4.log -journal ./fmax_ooc_k4.jou -source ../scripts/find_fmax_ooc.tcl -tclargs -top ascon_aead_array -k 4 -clk clk -max_runs 1 -start 3.55 -strat ae
vivado -mode batch -log ./fmax_ooc_k8.log -journal ./fmax_ooc_k8.jou -source ../scripts/find_fmax_ooc.tcl -tclargs -top ascon_aead_array -k 8 -clk clk -max_runs 1 -start 3.65 -strat ae
```

The four runs are independent and can run in parallel (about 1–2 h each). Results: `build/fmax_ooc/xc7z020clg400-1/ascon_aead_array_K<k>/summary.txt` and `results.txt` (every period tried). Do **not** report a frequency from a failing period.

Reference (Vivado 2023.2): 281.7 / 277.8 / 281.7 / 274.0 MHz, 1,328 / 2,633 / 5,258 / 10,478 LUT.

### B.3 Resource-only rows for other devices (Table I)

```tcl
vivado -mode batch -source scripts/find_fmax_ooc.tcl -tclargs -top ascon_aead_array -k 1 -clk clk -start 3.55 -part <artix-7 part>
vivado -mode batch -source scripts/find_fmax_ooc.tcl -tclargs -top ascon_aead_array -k 1 -clk clk -start 3.55 -part <virtex-7 part>
```

Use the same parts as the comparison works (check licence availability for Virtex-7). Only LUT / FF go into Table I for these rows.

To run all three parts in parallel:

```shell
./scripts/find_fmax_ooc_parallel-run.sh <start_period_xc7a>:<max_runs_xc7a> <start_period_xc7vx>:<max_runs_xc7vx> <start_period_xc7z>:<max_runs_xc7z> <strat>
```

For example, to use *AsconAEAD128_AggressiveExplore* strategy and skip running on `xc7z2020clg400-1`:

```shell
./scripts/find_fmax_ooc_parallel-run.sh 2.95:1 1.90:1 3.55:0 ae
```

### B.4 Overlay (if Part A is repeated with 2026.1)

```tcl
vivado -mode batch -source scripts/create_pynq_bd.tcl -tclargs -k 4 -fclk 142.86
```

The script exits with an error and exports nothing if routed timing fails. With Vivado 2023.2, K = 4 fails at 200 MHz (WNS −1.338 ns) and meets at 142.86 MHz (WNS +0.303 ns, 6,302 LUT, 4,938 FF).

### Send back

All `summary.txt` / `results.txt` files of B.2 and B.3, and the `build_info.txt` of B.4.

---

## After the data is back

1. Put the measured gateway time per message into `python_simulation/sim_params.json` (`interfaces.axilite`), re-run `python3 multilink_sim.py --sweep paper` and `python3 plot_results.py`, copy the figures to the manuscript.
2. Replace every `\tbd{}` in the manuscript with the measured values.
