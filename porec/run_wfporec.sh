#!/usr/bin/env bash
# Run epi2me-labs/wf-pore-c on the London Calling 2024 T2T open data (GM24385 / HG002).
# wf-pore-c aligns Pore-C concatemers to a reference and produces contact maps
# (pairs / .mcool / .hic) and, optionally, a paired-end BAM + BED for scaffolding.
#
# Docs:  https://github.com/epi2me-labs/wf-pore-c
# Data:  https://epi2me.nanoporetech.com/lc2024_t2t/
# Assumes the input BAM and reference FASTA have already been downloaded.
set -eo pipefail

# ---------------------------------------------------------------------------
# Config — edit these
# ---------------------------------------------------------------------------
SAMPLE=GM24385
THREADS=32                      # recommended 64 for a full human Pore-C BAM; min 8
OUT_DIR="results/${SAMPLE}_porec"
CUTTER=NlaIII                   # <-- CONFIRM the restriction enzyme used for this Pore-C prep
                                #     (NlaIII is the wf-pore-c default and ONT's standard Pore-C
                                #      enzyme, but it MUST match the wet-lab digest)

# Local inputs (already downloaded)
POREC_BAM="data/lc2024/PAW44788.bam"          # Pore-C basecalled/unaligned concatemer BAM
REF="data/lc2024/hg002v1.0.1.fasta"           # uncompressed FASTA (wf-pore-c runs samtools faidx)

# Fail early if inputs are missing
for f in "${POREC_BAM}" "${REF}"; do
  [[ -f "${f}" ]] || { echo "ERROR: input not found: ${f}" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# (Optional) pull/update the workflow. Pin a release for reproducibility.
#   tags: https://github.com/epi2me-labs/wf-pore-c/tags   (then add `-r "${WF_REV}"`)
# ---------------------------------------------------------------------------
NXF_VER=25.10.5 nextflow pull epi2me-labs/wf-pore-c

# ---------------------------------------------------------------------------
# Launch wf-pore-c in the background
# ---------------------------------------------------------------------------
echo "Launching wf-pore-c in the background..."
NXF_VER=25.10.5 nextflow run epi2me-labs/wf-pore-c \
  --bam "${POREC_BAM}" \
  --ref "${REF}" \
  --cutter "${CUTTER}" \
  --sample "${SAMPLE}" \
  --threads "${THREADS}" \
  --pairs \
  --mcool \
  --hi_c \
  --paired_end \
  --bed \
  --out_dir "${OUT_DIR}" \
  -resume > "nextflow_run.${SAMPLE}_porec.log" 2>&1 &

echo "Pipeline is running. PID: $!"
echo "You can safely close this terminal now."
echo "Check progress by running: tail -f nextflow_run.${SAMPLE}_porec.log"