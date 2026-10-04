#!/usr/bin/env python3
# Generated with assistance of claude code.
"""plot.py -- figures for the Lab 1 report from the jobs/ result directories.

    python3 plot.py sweep   OUT.png  A.csv [B.csv ...]   [--title T]
    python3 plot.py count   OUT.png  shardcount_X.csv [...] [--title T]
    python3 plot.py mix     OUT.png  RESULTS/part6_*/      [--title T]
    python3 plot.py writers OUT.png  RESULTS/part6_*/writers_table.tsv

sweep    throughput vs threads, linear axes, a dark line at the core count
         and a light one at the socket boundary (both read from the
         sweep.sh log next to each CSV), and the min..max of the three
         runs behind every median as an error bar.  Curves passed together
         share one set of axes (coarse + sharded, the five locks, ...).
count    throughput vs shard (or stripe) count, one curve per thread
         count per file, log2 x axis.
mix      the Part 6 grid: one panel per (shard count, mix), four locks each.
writers  the WRITERS=n split: reader and writer Mops/s per lock.

Labels default to the CSV name (sharded_ttas.csv -> sharded:ttas); when two
files have the same name the parent directory is added.
"""
import csv
import glob
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402


def sweep_log(csv_path):
    """(spread per T, cores, socket boundary) from sweep.sh's stderr log."""
    log = os.path.splitext(csv_path)[0] + ".log"
    spread, cores, sock = {}, None, None
    if not os.path.exists(log):
        return spread, cores, sock
    for line in open(log):
        m = re.search(r"cores=(\d+) .*cores/socket=(\d+)", line)
        if m:
            cores, sock = int(m.group(1)), int(m.group(2))
        m = re.match(r"T=(\d+)\s+\S+ Mops/s\s+\(([^)]*)\)", line)
        if m:
            runs = [float(x) for x in m.group(2).split() if x]
            if runs:
                spread[int(m.group(1))] = (min(runs), max(runs))
    return spread, cores, sock


def read_sweep(path):
    pts = []
    with open(path) as f:
        for row in csv.DictReader(f):
            if row.get("mops"):
                pts.append((int(row["threads"]), float(row["mops"])))
    return sorted(pts)


def impl_name(path):
    """sharded_shared_mutex.csv -> sharded:shared_mutex (undo make sweep's
    ':' -> '_' without splitting the one lock name that has a '_')."""
    s = os.path.splitext(os.path.basename(path))[0].replace("_", ":")
    return s.replace("shared:mutex", "shared_mutex")


def labels_for(paths):
    names = [impl_name(p) for p in paths]
    out = []
    for p, n in zip(paths, names):
        if names.count(n) > 1:
            n += " (" + os.path.basename(os.path.dirname(p)) + ")"
        out.append(n)
    return out


def boundaries(ax, cores, sock):
    if sock and cores and sock != cores:
        ax.axvline(sock, color="0.75", lw=1, ls="--",
                   label=f"socket boundary ({sock})")
    if cores:
        ax.axvline(cores, color="0.3", lw=1.2,
                   label=f"core count ({cores})")


def plot_sweep(out, paths, title):
    fig, ax = plt.subplots(figsize=(7, 4.2))
    cores = sock = None
    for p, lab in zip(paths, labels_for(paths)):
        pts = read_sweep(p)
        spread, c, s = sweep_log(p)
        cores, sock = cores or c, sock or s
        xs = [t for t, _ in pts]
        ys = [m for _, m in pts]
        lo = [m - spread.get(t, (m, m))[0] for t, m in pts]
        hi = [spread.get(t, (m, m))[1] - m for t, m in pts]
        ax.errorbar(xs, ys, yerr=[lo, hi], marker="o", ms=3.5, capsize=2.5,
                    lw=1.4, label=lab)
    boundaries(ax, cores, sock)
    ax.set_xlabel("threads (pinned, one per core)")
    ax.set_ylabel("throughput (Mops/s, median of 3)")
    ax.set_xlim(left=0)
    ax.set_ylim(bottom=0)
    ax.grid(alpha=0.3)
    ax.set_title(title or "throughput vs threads (bars: min..max of 3 runs)")
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=200)


def plot_count(out, paths, title):
    fig, ax = plt.subplots(figsize=(7, 4.2))
    for p in paths:
        rows = list(csv.DictReader(open(p)))
        name = impl_name(p).replace("shardcount:", "")
        for t in sorted({int(r["threads"]) for r in rows}):
            pts = sorted((int(r["count"]), float(r["mops"])) for r in rows
                         if int(r["threads"]) == t and r["mops"])
            ax.plot([c for c, _ in pts], [m for _, m in pts], marker="o",
                    ms=3.5, label=f"{name}, T={t}")
    ax.set_xscale("log", base=2)
    ax.set_xlabel("shard count N (log2 scale)")
    ax.set_ylabel("throughput (Mops/s, median of 3)")
    ax.set_ylim(bottom=0)
    ax.grid(alpha=0.3, which="both")
    ax.set_title(title or "throughput vs shard count")
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=200)


def plot_mix(out, root, title):
    dirs = sorted(d for d in glob.glob(os.path.join(root, "mix*_shards*"))
                  if os.path.isdir(d))
    if not dirs:
        sys.exit(f"no mix*_shards* directories under {root}")
    key = lambda d: re.search(r"mix([\d-]+)_shards(\d+)", d).groups()
    mixes = sorted({key(d)[0] for d in dirs},
                   key=lambda m: -int(m.split("-")[0]))
    shards = sorted({key(d)[1] for d in dirs}, key=lambda s: -int(s))
    fig, axes = plt.subplots(len(shards), len(mixes), squeeze=False,
                             figsize=(4.2 * len(mixes), 3.4 * len(shards)))
    for d in dirs:
        m, s = key(d)
        ax = axes[shards.index(s)][mixes.index(m)]
        cores = sock = None
        for p in sorted(glob.glob(os.path.join(d, "*.csv"))):
            pts = read_sweep(p)
            spread, c, so = sweep_log(p)
            cores, sock = cores or c, sock or so
            lab = impl_name(p).replace("sharded:", "")
            ax.errorbar([t for t, _ in pts], [y for _, y in pts],
                        yerr=[[y - spread.get(t, (y, y))[0] for t, y in pts],
                              [spread.get(t, (y, y))[1] - y for t, y in pts]],
                        marker="o", ms=3, capsize=2, lw=1.2, label=lab)
        boundaries(ax, cores, sock)
        ax.set_title(f"MIX={m.replace('-', '/')}, {s} shard(s)", fontsize=9)
        ax.set_xlabel("threads")
        ax.set_ylabel("Mops/s")
        ax.set_xlim(left=0)
        ax.set_ylim(bottom=0)
        ax.grid(alpha=0.3)
        ax.legend(fontsize=7)
    if title:
        fig.suptitle(title)
    fig.tight_layout()
    fig.savefig(out, dpi=200)


def plot_writers(out, tsv, title):
    rows = list(csv.DictReader(open(tsv), delimiter="\t"))
    groups = []
    for r in rows:
        w = re.search(r"writers(\d+)_shards(\d+)", r["file"])
        tag = f"W={w.group(1)} N={w.group(2)} T={r['T']}" if w else r["T"]
        groups.append((tag, r["impl"].replace("sharded:", ""),
                       float(r["rd_Mops"]), float(r["wr_Mops"])))
    tags = list(dict.fromkeys(g[0] for g in groups))
    impls = list(dict.fromkeys(g[1] for g in groups))
    fig, ax = plt.subplots(figsize=(max(7, 0.9 * len(tags) * len(impls)), 4))
    width = 0.8 / len(impls)
    for i, impl in enumerate(impls):
        xs, rd, wr = [], [], []
        for j, tag in enumerate(tags):
            for g in groups:
                if g[0] == tag and g[1] == impl:
                    xs.append(j + i * width)
                    rd.append(g[2])
                    wr.append(g[3])
        ax.bar(xs, rd, width, label=f"{impl} readers")
        ax.bar(xs, wr, width, bottom=rd, label=f"{impl} writers",
               hatch="//", alpha=0.6)
    ax.set_xticks([j + 0.4 - width / 2 for j in range(len(tags))])
    ax.set_xticklabels(tags, rotation=30, ha="right", fontsize=8)
    ax.set_ylabel("Mops/s (readers + writers stacked)")
    ax.set_title(title or "WRITERS=n: reader vs writer throughput")
    ax.legend(fontsize=7, ncol=2)
    ax.grid(alpha=0.3, axis="y")
    fig.tight_layout()
    fig.savefig(out, dpi=200)


def main(argv):
    title = None
    if "--title" in argv:
        i = argv.index("--title")
        title = argv[i + 1]
        del argv[i:i + 2]
    if len(argv) < 4:
        sys.exit(__doc__)
    cmd, out, args = argv[1], argv[2], argv[3:]
    if cmd == "sweep":
        plot_sweep(out, args, title)
    elif cmd == "count":
        plot_count(out, args, title)
    elif cmd == "mix":
        plot_mix(out, args[0], title)
    elif cmd == "writers":
        plot_writers(out, args[0], title)
    else:
        sys.exit(__doc__)
    print("wrote", out)


if __name__ == "__main__":
    main(sys.argv)
