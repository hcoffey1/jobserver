#!/bin/bash
#==============================================================
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b merci -w merci -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b flexkvs -w flexkvs -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b graph500 -w graph500 -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b gapbs -w bc -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b gapbs -w pr -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b gapbs -w pr_spmv -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b gapbs -w cc -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b gapbs -w cc_sv -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b gapbs -w bfs -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b gapbs -w sssp -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b liblinear -w liblinear -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs
j job add pebs "{MACHINE} ~/workloads/run.sh --record-vma -b gapbs -w tc -o results/results_pebs_1k_1s_lite -i pebs -s 1000" ./run_pebs

#j job add foo "{MACHINE} ~/workloads/run.sh -b liblinear -w liblinear -o results/baseline -r 3" ./hemem_baseline
