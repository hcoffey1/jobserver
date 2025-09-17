#!/bin/bash

# Collects baseline results for workload suite, these are not using hemem. 
# We can get baseline time and memory usage from these runs. Then use the peak RSS to determine memory ratios for HeMem.
#j job add foo "{MACHINE} ~/workloads/run.sh -b graph500 -w graph500 -o results/baseline -r 3" ./hemem_baseline
j job add foo "{MACHINE} ~/workloads/run.sh -b liblinear -w liblinear -o results/baseline -r 3" ./hemem_baseline
#j job add foo "{MACHINE} ~/workloads/run.sh -b flexkvs -w flexkvs -o results/baseline -r 3" ./hemem_baseline
#j job add foo "{MACHINE} ~/workloads/run.sh -b merci -w merci -o results/baseline -r 3" ./hemem_baseline
#
#j job add foo "{MACHINE} ~/workloads/run.sh -b gapbs -w bc -o results/baseline -r 3" ./hemem_baseline
#j job add foo "{MACHINE} ~/workloads/run.sh -b gapbs -w pr -o results/baseline -r 3" ./hemem_baseline
j job add foo "{MACHINE} ~/workloads/run.sh -b gapbs -w pr_spmv -o results/baseline -r 3" ./hemem_baseline
j job add foo "{MACHINE} ~/workloads/run.sh -b gapbs -w cc -o results/baseline -r 3" ./hemem_baseline
#j job add foo "{MACHINE} ~/workloads/run.sh -b gapbs -w cc_sv -o results/baseline -r 3" ./hemem_baseline
#j job add foo "{MACHINE} ~/workloads/run.sh -b gapbs -w bfs -o results/baseline -r 3" ./hemem_baseline
#j job add foo "{MACHINE} ~/workloads/run.sh -b gapbs -w sssp -o results/baseline -r 3" ./hemem_baseline
#j job add foo "{MACHINE} ~/workloads/run.sh -b gapbs -w tc -o results/baseline -r 3" ./hemem_baseline
