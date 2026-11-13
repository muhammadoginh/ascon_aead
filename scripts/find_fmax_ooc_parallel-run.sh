#!/bin/bash
# Edit shebang as needed by the environment, or make sure settings64.sh is properly sourced to $PATH

# Results: build/fmax_ooc/<part>/ascon_aead/{summary.txt,results.txt}
root=$(cd "$(dirname -- "$0")/.." && pwd) || exit 1
mkdir -p "$root/build" && cd "$root/build" || exit 1   # .Xil etc. land here

# Argument validation check
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <start_period_xc7a>:<max_runs_xc7a> <start_period_xc7vx>:<max_runs_xc7vx> <start_period_xc7z>:<max_runs_xc7z> <strat>"
    echo "Example: $0 3.55:35 3.55:35 3.60:20 explore"
    exit 1
fi

pids=()
for psm in xc7a200tfbg676-2:$1 xc7vx485tffg1761-2:$2 xc7z020clg400-1:$3; do
  IFS=':' read -r p s m <<< "$psm"

  if [ "$m" -eq 0 ]; then
    echo "Skipping $p: max_runs is 0"
    continue
  fi
  vivado -mode batch -log "$p.log" -journal "$p.jou" \
    -source "$root/scripts/find_fmax_ooc.tcl" \
    -tclargs -top ascon_aead -start "$s" -max_runs "$m" -part "$p" -strat "$4" &
  pids+=("$!")
done

rc=0
for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
exit $rc
