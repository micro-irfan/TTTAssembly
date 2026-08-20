# Dorado (GPU) for read self-correction (`dorado correct`).
# Uses ONT's prebuilt Linux x64 binary, which bundles libtorch + htslib.
#
# Base image: match to your host NVIDIA driver. Dorado 2.1.1 x64 wants a
# reasonably recent CUDA driver (>= 525.105). The binary ships its own CUDA
# runtime libs, so a CUDA *runtime* base is sufficient; adjust the tag if your
# host driver is older/newer.
FROM nvidia/cuda:12.8.0-runtime-ubuntu22.04

ARG DORADO_VERSION=2.1.1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        wget ca-certificates tar \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q "https://cdn.oxfordnanoportal.com/software/analysis/dorado-${DORADO_VERSION}-linux-x64.tar.gz" \
    && tar -xzf "dorado-${DORADO_VERSION}-linux-x64.tar.gz" -C /opt \
    && rm "dorado-${DORADO_VERSION}-linux-x64.tar.gz" \
    && ln -s "/opt/dorado-${DORADO_VERSION}-linux-x64/bin/dorado" /usr/local/bin/dorado

ENV PATH="/opt/dorado-${DORADO_VERSION}-linux-x64/bin:${PATH}"

# OPTIONAL: pre-download the correction model so `dorado correct` doesn't need
# internet at runtime. Confirm the exact model name for your Dorado version:
#   RUN dorado download --model <correction-model-name> --models-directory /opt/dorado-models
# then at runtime pass it via the process:  dorado correct --model-path /opt/dorado-models ...
# If omitted, `dorado correct` fetches the model automatically on first run.

# Run with:  docker run --rm --gpus all ont-t2t/dorado:2.1.1 dorado --version
CMD ["dorado", "--version"]
