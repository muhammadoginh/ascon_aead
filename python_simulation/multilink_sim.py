"""
multilink_sim.py - discrete-event simulation of N UAV links secured with
Ascon-AEAD128, with a gateway (GCS) that has K AEAD cores.

Packet path
    telemetry (UAV -> GCS): UAV encrypt -> radio uplink queue -> link delay
                            -> GCS decrypt/verify on the shared crypto
    C2        (GCS -> UAV): GCS encrypt on the shared crypto -> radio queue
                            -> link delay -> UAV decrypt/verify
Latency = generation at the sender -> verified plaintext at the receiver.

Security configurations
    plain       no AEAD (plain MAVLink frame, no crypto time)
    hw_stream   Ascon cores, data streamed to each core (no shared bus)
    hw_axilite  Ascon cores behind ascon_aead_axi_multi, one shared AXI-Lite bus
    sw_a9       software Ascon (one CPU thread at the GCS, one per UAV)

Gateway crypto: K cores; a job holds a core from dispatch to the end of its
output transfer; with a shared bus the input / output transfers of all cores
are serialized on one bus. Scheduler: 'priority' (C2 > telemetry > bulk) or
'fifo'. Each UAV has its own single core (same interface).

Optional real crypto (--verify N): the first N packets of every flow are
really sealed / opened with uav_packet.py, and attack frames (tampered and
replayed) are injected and must be rejected.

Examples
    python3 multilink_sim.py --links 20 --cores 2 --config hw_axilite
    python3 multilink_sim.py --sweep paper          # all CSVs for the figures
"""

from __future__ import annotations

import argparse
import csv
import heapq
import itertools
import os
import random
from collections import defaultdict, deque
from dataclasses import dataclass, field

import numpy as np

import uav_packet as up
from timing_model import AD_LEN, airtime, hw_op, load_params, message_table, sw_op

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")

PRIO = {"c2": 0, "telemetry": 1, "bulk": 2}
DRAIN_S = 0.05
CONFIGS = ("plain", "hw_stream", "hw_axilite", "sw_a9")


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------
SCENARIOS = {
    # Telemetry / C2 radio (e.g. 2 Mbps), a payload stream on a quarter of the links
    "radio": dict(rate_bps=2e6, bulk_bps=1.0e6, bulk_fraction=0.25),
    # High-rate links (Wi-Fi / 5G), every UAV streams payload data
    "highrate": dict(rate_bps=100e6, bulk_bps=20e6, bulk_fraction=1.0),
    # Control / telemetry only
    "c2only": dict(rate_bps=2e6, bulk_bps=0.0, bulk_fraction=0.0),
}


# ---------------------------------------------------------------------------
# Event engine
# ---------------------------------------------------------------------------
class Engine:
    def __init__(self):
        self.now = 0.0
        self._q = []
        self._seq = itertools.count()

    def at(self, t: float, fn, *args):
        heapq.heappush(self._q, (t, next(self._seq), fn, args))

    def run(self, until: float):
        while self._q and self._q[0][0] <= until:
            t, _, fn, args = heapq.heappop(self._q)
            self.now = t
            fn(*args)
        self.now = until


# ---------------------------------------------------------------------------
# Crypto resources
# ---------------------------------------------------------------------------
@dataclass
class Job:
    pkt: "Packet"
    t_in: float
    t_core: float
    t_out: float
    done: object            # callback(job)
    prio: int
    seq: int = 0
    t_submit: float = 0.0


class CryptoPool:
    """K servers (cores or CPU threads), optional shared bus for transfers."""

    def __init__(self, eng: Engine, k: int, shared_bus: bool, policy: str):
        self.eng = eng
        self.free = k
        self.k = k
        self.shared_bus = shared_bus
        self.policy = policy
        self.waiting = []                  # heap (prio, seq, job)
        self.bus_q = []                    # heap (prio, seq, job, phase)
        self.bus_busy = False
        self._seq = itertools.count()
        self.core_busy_time = 0.0
        self.bus_busy_time = 0.0
        self.jobs_done = 0
        self.warmup = 0.0
        self.delay = defaultdict(list)     # traffic class -> crypto delay (queue + service)

    def _key(self, job):
        return (job.prio if self.policy == "priority" else 0, job.seq)

    def submit(self, job: Job):
        job.seq = next(self._seq)
        job.t_submit = self.eng.now
        heapq.heappush(self.waiting, (*self._key(job), job))
        self._dispatch()

    def backlog(self) -> int:
        return len(self.waiting) + (self.k - self.free)

    def _dispatch(self):
        while self.free and self.waiting:
            *_, job = heapq.heappop(self.waiting)
            self.free -= 1
            job._t_start = self.eng.now
            self._bus(job, "in")

    # -- bus ---------------------------------------------------------------
    def _bus(self, job, phase):
        t = job.t_in if phase == "in" else job.t_out
        if not self.shared_bus or t == 0.0:
            self.eng.at(self.eng.now + t, self._bus_done, job, phase, t)
            return
        heapq.heappush(self.bus_q, (*self._key(job), job, phase))
        self._bus_next()

    def _bus_next(self):
        if self.bus_busy or not self.bus_q:
            return
        *_, job, phase = heapq.heappop(self.bus_q)
        self.bus_busy = True
        t = job.t_in if phase == "in" else job.t_out
        self.eng.at(self.eng.now + t, self._bus_done, job, phase, t)

    def _bus_done(self, job, phase, t):
        if self.shared_bus and t > 0.0:
            self.bus_busy = False
            self.bus_busy_time += t
            self._bus_next()
        if phase == "in":
            self.eng.at(self.eng.now + job.t_core, self._bus, job, "out")
        else:
            self.free += 1
            self.core_busy_time += self.eng.now - job._t_start
            self.jobs_done += 1
            if job.pkt.t_gen >= self.warmup and not job.pkt.attack:
                self.delay[job.pkt.msg.traffic_class].append(self.eng.now - job.t_submit)
            job.done(job)
            self._dispatch()


# ---------------------------------------------------------------------------
# Packets / links
# ---------------------------------------------------------------------------
@dataclass
class Packet:
    link: int
    msg: up.MsgType
    t_gen: float
    attack: str = ""          # "", "tamper", "replay"
    frame: bytes = b""
    payload: bytes = b""


@dataclass
class Stats:
    lat: dict = field(default_factory=lambda: defaultdict(list))
    sent: dict = field(default_factory=lambda: defaultdict(int))
    lost: dict = field(default_factory=lambda: defaultdict(int))
    rejected: dict = field(default_factory=lambda: defaultdict(int))
    verified: int = 0
    verify_fail: int = 0


class Sim:
    def __init__(self, n_links: int, k: int, config: str, scenario: dict, params: dict,
                 policy: str = "priority", seed: int = 1, verify: int = 0,
                 attack_rate: float = 0.0, warmup: float = 0.1):
        assert config in CONFIGS
        self.eng = Engine()
        self.p = params
        self.cfg = config
        self.sc = scenario
        self.rng = random.Random(seed)
        self.n = n_links
        self.k = k
        self.verify = verify
        self.attack_rate = attack_rate
        self.warmup = warmup
        self.st = Stats()
        self.link = params["link"]

        hw = config.startswith("hw_")
        iface = config[3:] if hw else None
        shared = hw and params["interfaces"][iface]["shared_bus"]
        n_gw = k if hw else 1                       # SW: one CPU thread at the GCS
        self.gw = CryptoPool(self.eng, n_gw, shared, policy)
        self.gw.warmup = warmup
        self.uav = [CryptoPool(self.eng, 1, shared, policy) for _ in range(n_links)]
        self.iface = iface

        # Radio channel per link and direction: FIFO, free-at time
        self.chan_free = [[0.0, 0.0] for _ in range(n_links)]

        # Real crypto endpoints (verify mode)
        self.ep = [up.link_pair(sysid=i + 1) for i in range(n_links)] if verify else None
        self.verified_count = defaultdict(int)
        self.last_frame = {}

        # Precompute per message: op timings
        self.op = {}
        for m in up.MSG_TYPES.values():
            ad, pt = AD_LEN, m.payload_len
            if config == "plain":
                self.op[m.name] = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
            elif hw:
                t = hw_op(params, iface, ad, pt)
                self.op[m.name] = (t.t_in, t.t_core, t.t_out) * 2
            else:
                te = sw_op(params, "a9_c", ad, pt, False)
                td = sw_op(params, "a9_c", ad, pt, True)
                self.op[m.name] = (0.0, te, 0.0, 0.0, td, 0.0)
            self.op[m.name + "_air"] = airtime_rate(params, scenario["rate_bps"], pt, config != "plain")

    # -- traffic -----------------------------------------------------------
    def start(self, duration: float):
        self.duration = duration
        for i in range(self.n):
            for m in up.MSG_TYPES.values():
                rate = m.rate_hz
                if m.traffic_class == "bulk":
                    has_bulk = (i / self.n) < self.sc["bulk_fraction"] if self.n > 1 else self.sc["bulk_fraction"] > 0
                    rate = self.sc["bulk_bps"] / (m.payload_len * 8) if has_bulk else 0.0
                if rate <= 0:
                    continue
                period = 1.0 / rate
                self.eng.at(self.rng.uniform(0, period), self._gen, i, m, period)
            if self.attack_rate > 0:
                self.eng.at(self.rng.expovariate(self.attack_rate), self._attack, i)
        # Traffic stops at `duration`; let packets in flight drain so the
        # delivered ratio only drops under real overload.
        self.eng.run(duration + DRAIN_S)

    def _gen(self, i, m, period):
        pkt = Packet(i, m, self.eng.now)
        if self.eng.now >= self.warmup:
            self.st.sent[m.traffic_class] += 1
        if self.ep is not None and self.verified_count[(i, m.name)] < self.verify:
            self.verified_count[(i, m.name)] += 1
            pkt.payload = os.urandom(m.payload_len)
        self._send(pkt)
        nxt = self.eng.now + period
        if nxt < self.duration:
            self.eng.at(nxt, self._gen, i, m, period)

    def _attack(self, i):
        if self.eng.now >= self.duration:
            return
        """Inject a forged downlink frame at the GCS: tampered (costs a decrypt)
        or replayed (dropped by the replay window before decryption)."""
        m = up.MSG_TYPES["ATTITUDE"]
        kind = "tamper" if self.rng.random() < 0.5 else "replay"
        pkt = Packet(i, m, self.eng.now, attack=kind)
        self._gw_receive(pkt)
        self.eng.at(self.eng.now + self.rng.expovariate(self.attack_rate), self._attack, i)

    # -- sender side ----------------------------------------------------------
    def _send(self, pkt):
        m = pkt.msg
        t_in, t_core, t_out = self.op[m.name][:3]
        proc_tx = (self.p["gateway"] if m.direction == up.DIR_GCS_TO_UAV else self.p["uav"])["processing_us"] * 1e-6
        if self.cfg == "plain":
            self.eng.at(self.eng.now + proc_tx, self._radio, pkt)
            return
        pool = self.gw if m.direction == up.DIR_GCS_TO_UAV else self.uav[pkt.link]
        if pkt.payload:
            tx = self.ep[pkt.link][0 if m.direction == up.DIR_GCS_TO_UAV else 1]
            pkt.frame = tx.seal(m, pkt.payload)
        pool.submit(Job(pkt, t_in, t_core, t_out,
                        lambda job: self.eng.at(self.eng.now + proc_tx, self._radio, job.pkt),
                        PRIO[m.traffic_class]))

    # -- radio ------------------------------------------------------------------
    def _radio(self, pkt):
        d = pkt.msg.direction
        ch = self.chan_free[pkt.link]
        start = max(self.eng.now, ch[d])
        ch[d] = start + self.op[pkt.msg.name + "_air"]
        if self.rng.random() < self.link["loss"]:
            if pkt.t_gen >= self.warmup:
                self.st.lost[pkt.msg.traffic_class] += 1
            return
        delay = self.link["base_delay_ms"] * 1e-3 + self.rng.uniform(0, self.link["jitter_ms"] * 1e-3)
        arrive = ch[d] + delay
        if d == up.DIR_UAV_TO_GCS:
            self.eng.at(arrive, self._gw_receive, pkt)
        else:
            self.eng.at(arrive, self._uav_receive, pkt)

    # -- receiver side ----------------------------------------------------------
    def _gw_receive(self, pkt):
        self._receive(pkt, self.gw, self.p["gateway"]["processing_us"] * 1e-6, 0)

    def _uav_receive(self, pkt):
        self._receive(pkt, self.uav[pkt.link], self.p["uav"]["processing_us"] * 1e-6, 1)

    def _receive(self, pkt, pool, proc_rx, rx_side):
        m = pkt.msg
        if pkt.attack == "replay":
            # Rejected by the replay window before any decryption
            self.st.rejected["replay"] += 1
            return
        if self.cfg == "plain":
            self.eng.at(self.eng.now + proc_rx, self._deliver, pkt, rx_side)
            return
        t_in, t_core, t_out = self.op[m.name][3:]
        pool.submit(Job(pkt, t_in, t_core, t_out,
                        lambda job: self.eng.at(self.eng.now + proc_rx, self._deliver, job.pkt, rx_side),
                        PRIO[m.traffic_class] if not pkt.attack else PRIO["telemetry"]))

    def _deliver(self, pkt, rx_side):
        if pkt.attack == "tamper":
            self.st.rejected["tag"] += 1
            if self.ep is not None:
                self._verify_attack(pkt)
            return
        if pkt.frame:
            rx = self.ep[pkt.link][rx_side]
            ok, why, pt = rx.open(pkt.frame)
            self.st.verified += 1
            if not ok or pt != pkt.payload:
                self.st.verify_fail += 1
        if pkt.t_gen >= self.warmup:
            self.st.lat[pkt.msg.traffic_class].append(self.eng.now - pkt.t_gen)

    def _verify_attack(self, pkt):
        """Real crypto check that a tampered frame is rejected."""
        gcs, uav = self.ep[pkt.link]
        frame = bytearray(uav.seal(pkt.msg, os.urandom(pkt.msg.payload_len)))
        frame[up.AD_LEN + self.rng.randrange(pkt.msg.payload_len)] ^= 1 << self.rng.randrange(8)
        ok, _, _ = gcs.open(bytes(frame))
        self.st.verified += 1
        if ok:
            self.st.verify_fail += 1

    # -- results -------------------------------------------------------------
    def summary(self) -> dict:
        T = self.duration - self.warmup
        t_sim = self.duration + DRAIN_S          # busy time also accrues while draining
        out = dict(links=self.n, cores=self.k, config=self.cfg,
                   gw_core_util=self.gw.core_busy_time / (t_sim * self.gw.k),
                   gw_bus_util=self.gw.bus_busy_time / t_sim,
                   gw_backlog=self.gw.backlog(),
                   verified=self.st.verified, verify_fail=self.st.verify_fail,
                   rejected_tag=self.st.rejected["tag"], rejected_replay=self.st.rejected["replay"])
        for cls in ("c2", "telemetry", "bulk"):
            lat = np.array(self.st.lat[cls]) * 1e6
            sent = self.st.sent[cls]
            out[f"{cls}_sent"] = sent
            out[f"{cls}_delivered"] = len(lat)
            out[f"{cls}_lost"] = self.st.lost[cls]
            out[f"{cls}_mean_us"] = float(lat.mean()) if len(lat) else float("nan")
            out[f"{cls}_p99_us"] = float(np.percentile(lat, 99)) if len(lat) else float("nan")
            out[f"{cls}_max_us"] = float(lat.max()) if len(lat) else float("nan")
            # Gateway crypto delay (queueing + transfers + core), the part K changes
            gd = np.array(self.gw.delay[cls]) * 1e6
            out[f"{cls}_gw_mean_us"] = float(gd.mean()) if len(gd) else float("nan")
            out[f"{cls}_gw_p99_us"] = float(np.percentile(gd, 99)) if len(gd) else float("nan")
            # Delivered share of what was sent and not lost on the radio
            exp = sent - self.st.lost[cls]
            out[f"{cls}_delivered_ratio"] = len(lat) / exp if exp > 0 else float("nan")
        # Saturated: offered work not served by the end of the run
        out["saturated"] = int(out["gw_backlog"] > 4 * self.gw.k)
        out["offered_pps"] = sum(self.st.sent.values()) / T if T > 0 else 0.0
        return out


def airtime_rate(params: dict, rate_bps: float, payload_len: int, aead: bool) -> float:
    p = dict(params)
    p["link"] = dict(params["link"], rate_bps=rate_bps)
    return airtime(p, payload_len, aead)


# ---------------------------------------------------------------------------
# Sweeps
# ---------------------------------------------------------------------------
def write_csv(path: str, rows: list[dict]):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {path} ({len(rows)} rows)")


def run_one(n, k, config, scenario_name, params, duration, policy="priority", seed=1, verify=0, attack_rate=0.0):
    sc = SCENARIOS[scenario_name]
    sim = Sim(n, k, config, sc, params, policy=policy, seed=seed, verify=verify, attack_rate=attack_rate)
    sim.start(duration)
    s = sim.summary()
    s["scenario"] = scenario_name
    s["policy"] = policy
    return s


def sweep_paper(params, duration):
    # 1. Per-message latency without / with AEAD (no contention)
    write_csv(os.path.join(RESULTS, "latency_table.csv"), message_table(params))

    # 2. Plain vs HW vs SW under load (K = 1)
    rows = []
    for scen in ("radio", "highrate"):
        for cfg in CONFIGS:
            for n in (1, 10, 50, 100):
                rows.append(run_one(n, 1, cfg, scen, params, duration))
                print_row(rows[-1])
    write_csv(os.path.join(RESULTS, "config_compare.csv"), rows)

    # 3. Multi-link, multi-core scaling (HW interfaces, both schedulers)
    rows = []
    for scen in ("radio", "highrate"):
        for cfg in ("hw_stream", "hw_axilite"):
            for k in (1, 2, 4, 8):
                for n in (1, 5, 10, 20, 50, 100, 200):
                    for pol in ("priority", "fifo"):
                        rows.append(run_one(n, k, cfg, scen, params, duration, policy=pol))
                        print_row(rows[-1])
    write_csv(os.path.join(RESULTS, "multilink.csv"), rows)

    # 4. Security check with real crypto + attack injection
    s = run_one(10, 2, "hw_axilite", "radio", params, 0.5, verify=5, attack_rate=20.0)
    write_csv(os.path.join(RESULTS, "security_check.csv"), [s])
    print(f"security: verified {s['verified']} frames, failures {s['verify_fail']}, "
          f"rejected tag {s['rejected_tag']}, replay {s['rejected_replay']}")


def print_row(s):
    print(f"  {s['scenario']:8s} {s['config']:10s} N={s['links']:3d} K={s['cores']} {s['policy']:8s} "
          f"C2 e2e p99 {s['c2_p99_us']:8.1f} us  GW p99 C2 {s['c2_gw_p99_us']:9.2f} tel {s['telemetry_gw_p99_us']:9.2f} us  "
          f"deliv tel {s['telemetry_delivered_ratio']:6.1%}  core {s['gw_core_util']:5.1%} bus {s['gw_bus_util']:5.1%}"
          f"{'  SATURATED' if s['saturated'] else ''}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--links", type=int, default=10)
    ap.add_argument("--cores", type=int, default=1)
    ap.add_argument("--config", choices=CONFIGS, default="hw_stream")
    ap.add_argument("--scenario", choices=SCENARIOS, default="radio")
    ap.add_argument("--policy", choices=("priority", "fifo"), default="priority")
    ap.add_argument("--duration", type=float, default=1.0, help="simulated seconds")
    ap.add_argument("--verify", type=int, default=0, help="real crypto for the first N packets of each flow")
    ap.add_argument("--attack-rate", type=float, default=0.0, help="forged frames per second per link")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--params", default=None, help="parameter file (default sim_params.json)")
    ap.add_argument("--sweep", choices=("paper",), default=None)
    a = ap.parse_args()

    params = load_params(a.params)
    if a.sweep == "paper":
        sweep_paper(params, a.duration)
        return
    s = run_one(a.links, a.cores, a.config, a.scenario, params, a.duration,
                policy=a.policy, seed=a.seed, verify=a.verify, attack_rate=a.attack_rate)
    for k_, v in s.items():
        print(f"  {k_:20s} {v}")


if __name__ == "__main__":
    main()
