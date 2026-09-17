#!/bin/sh

set -x

echo "===== FULL BENCHMARK START ====="

if ! cd /home; then
    echo "ERROR: cannot enter /home"
    /sbin/m5 exit
fi

# Exclude checkpoint restoration and guest setup from benchmark statistics.
/sbin/m5 resetstats

# This script is stored inside parsec.img at /home/benchmark.sh.
/bin/sh ./benchmark.sh
status=$?

echo "===== FULL BENCHMARK END: status=$status ====="
sync

# Without this, gem5 keeps simulating the idle guest after the benchmark ends.
/sbin/m5 exit
