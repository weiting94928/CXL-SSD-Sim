#!/bin/sh

set -x

echo "===== RUNSCRIPT LOADED ====="

if ! cd /home; then
    echo "ERROR: cannot enter /home"
    /sbin/m5 exit
fi

pwd
ls -l /home/benchmark.sh
ls -ld /home/cxl_benchmark

echo "===== SMOKE TEST PASSED ====="
/sbin/m5 exit
