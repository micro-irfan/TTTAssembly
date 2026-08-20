# hifiasm built from source. Not used by expert mode; prepared ahead for the
# scalable-mode workflow (the user will supply those steps later).
FROM ubuntu:24.04

# hifiasm git tags are unprefixed (e.g. 0.25.0). If checkout fails, try v${HIFIASM_VERSION}.
ARG HIFIASM_VERSION=0.25.0
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git g++ make zlib1g-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/chhylp123/hifiasm /opt/hifiasm \
    && cd /opt/hifiasm \
    && git checkout "${HIFIASM_VERSION}" \
    && make -j"$(nproc)"

ENV PATH="/opt/hifiasm:${PATH}"

CMD ["hifiasm", "--version"]
