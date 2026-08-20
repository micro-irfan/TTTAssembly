# samtools built from source (bundles htslib).
# Needs >= 1.16 for the filter-expression grammar used by BAM_TO_FASTQ
#   ( -e '[qs]>=10 && length(seq)>=1000' ).
FROM ubuntu:24.04

ARG SAMTOOLS_VERSION=1.23.1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        wget ca-certificates bzip2 \
        build-essential \
        zlib1g-dev libbz2-dev liblzma-dev \
        libcurl4-openssl-dev libncurses-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q "https://github.com/samtools/samtools/releases/download/${SAMTOOLS_VERSION}/samtools-${SAMTOOLS_VERSION}.tar.bz2" \
    && tar -xjf "samtools-${SAMTOOLS_VERSION}.tar.bz2" \
    && cd "samtools-${SAMTOOLS_VERSION}" \
    && ./configure \
    && make -j"$(nproc)" \
    && make install \
    && cd .. \
    && rm -rf "samtools-${SAMTOOLS_VERSION}" "samtools-${SAMTOOLS_VERSION}.tar.bz2"

# samtools installs to /usr/local/bin
CMD ["samtools", "--version"]
