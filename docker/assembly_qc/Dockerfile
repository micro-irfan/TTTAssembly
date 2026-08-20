# Single assembly-QC image: QUAST, BUSCO, Merqury (+meryl) and yak.
#
# These four tools have large, mutually incompatible dependency trees, so a
# single flat conda env tends to be unsolvable. Instead we install ONE env per
# tool inside ONE image, then expose each tool through a thin wrapper on PATH
# that runs it inside its own env (`conda run -n <env>`). Nextflow processes can
# therefore call `quast-lg.py`, `busco`, `merqury.sh`, `meryl`, `yak` directly.
#
# Note: this image is large (BUSCO + R for Merqury plots). That's expected for
# an all-in-one QC image.
FROM condaforge/miniforge3:latest
# For reproducibility, pin to a dated miniforge3 tag.

# BUSCO 6.1.0 is required for OrthoDB v12 / v12.2 lineages (e.g. primates_odb12).
ARG BUSCO_VERSION=6.1.0

# One env per tool (avoids cross-tool solver conflicts).
RUN mamba create -y -n quast   -c conda-forge -c bioconda quast                 && mamba clean -afy
RUN mamba create -y -n busco   -c conda-forge -c bioconda "busco=${BUSCO_VERSION}" && mamba clean -afy
RUN mamba create -y -n merqury -c conda-forge -c bioconda merqury               && mamba clean -afy
RUN mamba create -y -n yak     -c conda-forge -c bioconda yak                   && mamba clean -afy

# Wrapper scripts: <tool> -> conda run --no-capture-output -n <env> <tool> "$@"
# (the tool:env pairs below cover every entry point the pipeline calls)
RUN set -eu; \
    for pair in \
        "quast.py:quast" \
        "quast-lg.py:quast" \
        "busco:busco" \
        "merqury.sh:merqury" \
        "meryl:merqury" \
        "yak:yak" ; do \
      cmd="${pair%%:*}"; env="${pair##*:}"; \
      printf '#!/usr/bin/env bash\nexec conda run --no-capture-output -n %s %s "$@"\n' "$env" "$cmd" \
        > "/usr/local/bin/${cmd}"; \
      chmod +x "/usr/local/bin/${cmd}"; \
    done

ENV PATH="/opt/conda/bin:${PATH}"

# OPTIONAL: pre-download a BUSCO lineage so runtime needs no internet, then run
# BUSCO with `--offline --download_path /opt/busco_downloads`:
#   RUN busco --download primates_odb12 && \
#       mkdir -p /opt/busco_downloads && mv busco_downloads/* /opt/busco_downloads/ || true

CMD ["bash", "-lc", "quast-lg.py --version; busco --version; yak version 2>/dev/null || true; echo assembly-qc-ok"]
