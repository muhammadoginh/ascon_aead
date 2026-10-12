# Clock constraint (set by scripts/find_fmax.tcl).
# Fmax = 1 / period of the tightest constraint that closes timing (WNS >= 0, WHS >= 0).
create_clock -period 3.283 -name clk -waveform {0.000 1.641} [get_ports clk]
