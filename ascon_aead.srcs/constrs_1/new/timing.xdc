# Clock constraint (set by scripts/find_fmax.tcl).
# Fmax = 1 / period of the tightest constraint that closes timing (WNS >= 0, WHS >= 0).
create_clock -period 3.333 -name clk -waveform {0.000 1.667} [get_ports clk]
