# Over-constrained to 3.0 ns (333 MHz) so placement/routing push harder;
# report Fmax = 1000 / (period - WNS). Original target: 3.333 ns (300 MHz).
create_clock -period 3.000 -name clk -waveform {0.000 1.500} [get_ports clk]
