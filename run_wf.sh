#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# TODO: fill in for your run — see README.md "Run the pipeline" / CLAUDE.md §8 for the Hi-C
# variant and the full parameter table.
SAMPLE=HG002
ULK_READS=ulk.bam          # comma-separate multiple flowcells, e.g. fc1.bam,fc2.bam,fc3.bam
POREC_READS=porec.bam      # or use --hic_reads_1/--hic_reads_2 instead (mutually exclusive)
MAX_MEMORY_GB=480

echo "Launching Nextflow in the background..."
nextflow run main.nf \
  --mode expert \
  --sample "${SAMPLE}" \
  --ulk_reads "${ULK_READS}" \
  --porec_reads "${POREC_READS}" \
  --max_memory_gb "${MAX_MEMORY_GB}" \
  -resume \
  -profile singularity \
  --output "results/${SAMPLE}" > "nextflow_run.${SAMPLE}.log" 2>&1 &

echo "Pipeline is running. PID: $!"
echo "You can safely close this terminal now."
echo "Check progress by running: tail -f nextflow_run.${SAMPLE}.log"
