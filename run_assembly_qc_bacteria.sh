#!/usr/bin/env bash
# Run the standalone assembly-QC workflow (assembly_qc.nf) on a bacterial (haploid) assembly:
# gfastats + QUAST + Merqury. No haplotypes, no compleasm/seqtk telo here — add them to
# --tools below if you want them too. Conda-only for now — see CLAUDE.md §10 /
# sessions/session_assembly_qc.md for the full spec.
set -eo pipefail

# ---------------------------------------------------------------------------
# Config — edit these
# ---------------------------------------------------------------------------
SAMPLE=isolate01
OUT_DIR="results/${SAMPLE}_assembly_qc"

ASSEMBLY="results/${SAMPLE}/assembly.fasta"     # single/combined assembly — bacteria has no H1/H2
READS="data/${SAMPLE}/reads_*.fastq.gz"         # quoted glob for the meryl k-mer DB (Merqury)
QUAST_REF=""                                    # optional reference FASTA; leave empty for reference-free QUAST

GENOME_SIZE=5000000                             # typical bacterial genome; adjust per organism
TOOLS="gfastats,quast,merqury"

# Bacteria are haploid; ploidy=1 also drives GenomeScope2/Merfin if you add merfin to --tools
# later. k=21 (the pipeline default) suits large genomes — bacteria often do better with a
# smaller k (e.g. 17-19); see CLAUDE.md §10 open question #4. Adjust if Merqury's QV looks off.
PLOIDY=1
MERYL_K=17

# Fail early if inputs are missing
[[ -f "${ASSEMBLY}" ]] || { echo "ERROR: input not found: ${ASSEMBLY}" >&2; exit 1; }
# shellcheck disable=SC2086  # READS is an intentional glob, not meant to be quoted here
if ! compgen -G "${READS}" > /dev/null; then
  echo "ERROR: no files match --reads glob: ${READS}" >&2
  exit 1
fi

QUAST_REF_ARG=()
if [[ -n "${QUAST_REF}" ]]; then
  [[ -f "${QUAST_REF}" ]] || { echo "ERROR: input not found: ${QUAST_REF}" >&2; exit 1; }
  QUAST_REF_ARG=(--quast_reference "${QUAST_REF}")
fi

# ---------------------------------------------------------------------------
# Launch assembly_qc.nf in the background
# ---------------------------------------------------------------------------
echo "Launching assembly_qc.nf in the background..."
nextflow run assembly_qc.nf -profile conda \
  --sample "${SAMPLE}" \
  --assembly "${ASSEMBLY}" \
  --reads "${READS}" \
  --tools "${TOOLS}" \
  --genome_size "${GENOME_SIZE}" \
  --ploidy "${PLOIDY}" \
  --meryl_k "${MERYL_K}" \
  "${QUAST_REF_ARG[@]}" \
  --output "${OUT_DIR}" \
  -resume > "nextflow_run.${SAMPLE}_assembly_qc.log" 2>&1 &

echo "Pipeline is running. PID: $!"
echo "You can safely close this terminal now."
echo "Check progress by running: tail -f nextflow_run.${SAMPLE}_assembly_qc.log"
