#!/bin/bash
#==============================================================
j job add pebs "{MACHINE} ~/workloads/run.sh -b merci -w merci -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh -b flexkvs -w flexkvs -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh -b graph500 -w graph500 -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh -b gapbs -w bc -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh -b gapbs -w pr -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh -b gapbs -w pr_spmv -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh -b gapbs -w cc -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh -b gapbs -w cc_sv -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh -b gapbs -w bfs -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh -b gapbs -w sssp -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh -b liblinear -w liblinear -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh -b gapbs -w tc -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs

#j job add foo "{MACHINE} ~/workloads/run.sh -b liblinear -w liblinear -o results/baseline -r 3" ./hemem_baseline