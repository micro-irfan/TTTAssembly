# Verkko (assembly) via bioconda. The conda package pulls in its dependencies
# (snakemake, GraphAligner, MashMap, Winnowmap) and, for Pore-C/Hi-C mode,
# samtools, bwa, minimap2, seqtk and networkx.
#
# Alternative to building this image: pull the prebuilt biocontainer directly
#   docker pull quay.io/biocontainers/verkko:2.3.2--<buildhash>
# and point the VERKKO process at that tag instead.
FROM condaforge/miniforge3:latest
# For reproducibility, pin to a dated tag, e.g. condaforge/miniforge3:24.11.3-2

ARG VERKKO_VERSION=2.3.2

RUN mamba install -y -n base -c conda-forge -c bioconda \
        "verkko=${VERKKO_VERSION}" \
    && mamba clean -afy

# miniforge's base env is already on PATH at /opt/conda/bin
ENV PATH="/opt/conda/bin:${PATH}"

CMD ["verkko", "--version"]
