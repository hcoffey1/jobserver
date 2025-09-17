#!/bin/bash

# Peak RSS values (in bytes)
merci_peak=$((22165644*1024))
liblinear_peak=$((72382548*1024))
gapbs_pr_spmv_peak=$((36947196*1024))
gapbs_pr_peak=$((36947496*1024))
flexkvs_peak=$((35223508*1024))
gapbs_bc_peak=$((36947268*1024))
gapbs_bfs_peak=$((36947744*1024))
gapbs_cc_peak=$((36947320*1024))
gapbs_cc_sv_peak=$((36947460*1024))
gapbs_sssp_peak=$((70221500*1024))
gapbs_tc_peak=$((39318208*1024))
graph500_peak=$((35888160*1024))

# Workload definitions: name, -b, -w, peak variable
workloads=(
	"merci merci merci_peak"
	"liblinear liblinear liblinear_peak"
	"gapbs pr_spmv gapbs_pr_spmv_peak"
	"gapbs pr gapbs_pr_peak"
	"flexkvs flexkvs flexkvs_peak"
	"gapbs bc gapbs_bc_peak"
	"gapbs bfs gapbs_bfs_peak"
	"gapbs cc gapbs_cc_peak"
	"gapbs cc_sv gapbs_cc_sv_peak"
	"gapbs sssp gapbs_sssp_peak"
	"graph500 graph500 graph500_peak"
)


	#"gapbs gapbs_tc gapbs_tc_peak"

MIN_INTERPOSE_MEM_SIZE=$((67108864/(2*1024)))
DRAM_SIZES=(0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1)
HEMEM_POL=(/users/hjcoffey/tiering_solutions/src/libhemem.so /users/hjcoffey/tiering_solutions/src/libhemem-lru.so /users/hjcoffey/tiering_solutions/src/libhemem-baseline.so)
#HEMEM_POL=(/users/hjcoffey/tiering_solutions/src/libhemem-lru.so /users/hjcoffey/tiering_solutions/src/libhemem-baseline.so)

# Dispatch jobs for each workload, dram size, and policy
for entry in "${workloads[@]}"; do
	set -- $entry
	base=$1
	work=$2
	peak_var=$3
	peak_val=${!peak_var}
	for size in "${DRAM_SIZES[@]}"; do
		for pol in "${HEMEM_POL[@]}"; do
			MEM_USED=$(echo "$peak_val * $size / 1" | bc)
			# Use env command to properly set environment variables
			j job add foo "{MACHINE} env MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$MEM_USED ~/workloads/run.sh -b $base -w $work -o results/freq_lru -r 5" ./hemem_lru
		done
	done
done
