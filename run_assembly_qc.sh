#!/usr/bin/env bash
# Run the standalone assembly-QC workflow (assembly_qc.nf) on a Human T2T assembly:
# gfastats + compleasm + seqtk telo (read-free tools), plus QUAST against a CHM13 reference.
# Conda-only for now — see CLAUDE.md §10 / sessions/session_assembly_qc.md for the full spec.
set -eo pipefail

# ---------------------------------------------------------------------------
# Config — edit these
# ---------------------------------------------------------------------------
SAMPLE=HG002
OUT_DIR="results/${SAMPLE}_assembly_qc"

# Assembly FASTAs — defaults assume a prior main-pipeline run (see run_wf.sh) landed here.
ASSEMBLY="results/${SAMPLE}/verkko/assembly.fasta"                # combined
ASSEMBLY_H1="results/${SAMPLE}/verkko/assembly.haplotype1.fasta"
ASSEMBLY_H2="results/${SAMPLE}/verkko/assembly.haplotype2.fasta"
CHM13_REF="data/chm13v2.0.fasta"                                         # QUAST reference

TOOLS="gfastats,seqtk,compleasm,quast"
COMPLEASM_LINEAGE="primates"

# Fail early if inputs are missing
for f in "${ASSEMBLY}" "${ASSEMBLY_H1}" "${ASSEMBLY_H2}" "${CHM13_REF}"; do
  [[ -f "${f}" ]] || { echo "ERROR: input not found: ${f}" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Launch assembly_qc.nf in the background
# ---------------------------------------------------------------------------
echo "Launching assembly_qc.nf in the background..."
nextflow run assembly_qc.nf -profile conda \
  --sample "${SAMPLE}" \
  --assembly "${ASSEMBLY}" \
  --assembly_H1 "${ASSEMBLY_H1}" \
  --assembly_H2 "${ASSEMBLY_H2}" \
  --tools "${TOOLS}" \
  --compleasm_lineage "${COMPLEASM_LINEAGE}" \
  --quast_reference "${CHM13_REF}" \
  --output "${OUT_DIR}" \
  -resume > "nextflow_run.${SAMPLE}_assembly_qc.log" 2>&1 &

echo "Pipeline is running. PID: $!"
echo "You can safely close this terminal now."
echo "Check progress by running: tail -f nextflow_run.${SAMPLE}_assembly_qc.log"
