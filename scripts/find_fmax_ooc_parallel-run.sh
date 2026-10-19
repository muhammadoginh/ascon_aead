#!/bin/zsh

# Results: build/fmax_ooc/<part>/ascon_aead/{summary.txt,results.txt}
root=$(cd "$(dirname "$0")/.." && pwd) || exit 1
mkdir -p "$root/build" && cd "$root/build" || exit 1   # .Xil etc. land here

pids=""
for ps in xc7a200tfbg676-2:3.6 xc7vx485tffg1761-2:3.6 xc7z020clg400-1:3.6; do
  p=${ps%%:*}; s=${ps##*:}                             # part : start_period
  vivado -mode batch -log "$p.log" -journal "$p.jou" \
    -source "$root/scripts/find_fmax_ooc.tcl" \
    -tclargs -top ascon_aead -start "$s" -max_runs 35 -part "$p" &
  pids="$pids $!"
done

rc=0
for pid in $pids; do wait "$pid" || rc=1; done
exit $rc
