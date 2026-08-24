#!/usr/bin/env bash
# Run --mode scalable (hifiasm-based assembly) — default (dual) sub-mode: long reads only, no
# Hi-C or trio phasing. For Hi-C or trio, add --hic_reads_1/--hic_reads_2 or
# --pat_reads/--mat_reads to the nextflow invocation below (mutually exclusive — see
# CLAUDE.md §11). See CLAUDE.md §11 / sessions/session_scalable.md for the full spec.
set -eo pipefail

# ---------------------------------------------------------------------------
# Config — edit these
# ---------------------------------------------------------------------------
SAMPLE=HG002
OUT_DIR="results/${SAMPLE}_scalable"

LONG_READS="data/${SAMPLE}/long_reads.bam"   # comma-separate multiple flowcells to merge them

# Fail early if inputs are missing
[[ -f "${LONG_READS%%,*}" ]] || { echo "ERROR: input not found: ${LONG_READS}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Launch main.nf --mode scalable in the background
# ---------------------------------------------------------------------------
echo "Launching main.nf (--mode scalable) in the background..."
nextflow run main.nf -profile singularity \
  --mode scalable \
  --sample "${SAMPLE}" \
  --long_reads "${LONG_READS}" \
  --output "${OUT_DIR}" \
  -resume > "nextflow_run.${SAMPLE}_scalable.log" 2>&1 &

echo "Pipeline is running. PID: $!"
echo "You can safely close this terminal now."
echo "Check progress by running: tail -f nextflow_run.${SAMPLE}_scalable.log"
