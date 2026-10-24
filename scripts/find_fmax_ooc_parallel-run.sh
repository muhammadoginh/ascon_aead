#!/bin/bash
# Edit shebang as needed by the environment, or make sure settings64.sh is properly sourced to $PATH

# Results: build/fmax_ooc/<part>/ascon_aead/{summary.txt,results.txt}
root=$(cd "$(dirname -- "$0")/.." && pwd) || exit 1
mkdir -p "$root/build" && cd "$root/build" || exit 1   # .Xil etc. land here

pids=()
for psm in xc7a200tfbg676-2:3.55:35 xc7vx485tffg1761-2:3.55:35 xc7z020clg400-1:3.55:20; do
  IFS=':' read -r p s m <<< "$psm"

  vivado -mode batch -log "$p.log" -journal "$p.jou" \
    -source "$root/scripts/find_fmax_ooc.tcl" \
    -tclargs -top ascon_aead -start "$s" -max_runs "$m" -part "$p" &
  pids+=("$!")
done

rc=0
for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
exit $rc
