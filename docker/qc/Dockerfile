# Read-summary / QC image for step 2: seqkit (fast stats incl. N50) and
# NanoPlot (ONT read-length / quality plots). Installed via bioconda.
FROM condaforge/miniforge3:latest
# For reproducibility, pin to a dated tag of miniforge3.

# Left unpinned so conda resolves a compatible recent pair. Pin these once you
# know the exact versions you want (e.g. seqkit>=2.8, nanoplot>=1.42).
RUN mamba install -y -n base -c conda-forge -c bioconda \
        seqkit \
        nanoplot \
    && mamba clean -afy

ENV PATH="/opt/conda/bin:${PATH}"

CMD ["seqkit", "version"]
