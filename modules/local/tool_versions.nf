// tool_versions.nf
// Per-tool version capture — one process per container already used elsewhere in the pipeline
// (reuses the same image, so the reported version is guaranteed to match what actually ran).
// No pipeline inputs; each runs `<tool> --version` once per invocation. SOFTWARE_VERSIONS
// (modules/local/software_versions.nf) collects all of their outputs into one combined JSON.

// SAMTOOLS_VERSION
// Same container as BAM_TO_FASTQ (modules/local/common.nf).

process SAMTOOLS_VERSION {
    tag "${params.sample}"
    label 'samtools'
    label 'quick'

    output:
    path "samtools.version.txt", emit: version

    script:
    """
    samtools --version | head -n1 > samtools.version.txt
    """
}

// QC_VERSIONS
// Captures both seqkit and NanoPlot in one process — same qc container as SEQKIT_STATS/NANOPLOT
// (modules/local/qc.nf).

process QC_VERSIONS {
    tag "${params.sample}"
    label 'qc'
    label 'quick'

    output:
    path "*.version.txt", emit: versions

    script:
    """
    seqkit version   | head -n1 > seqkit.version.txt
    NanoPlot --version | head -n1 > nanoplot.version.txt
    """
}

// DORADO_VERSION
// Same container as DORADO_CORRECT. Deliberately no `--nv` — a version check doesn't
// need GPU hardware.

process DORADO_VERSION {
    tag "${params.sample}"
    label 'dorado'
    label 'quick'

    output:
    path "dorado.version.txt", emit: version

    script:
    // Same --dorado_path override as DORADO_CORRECT (modules/local/dorado_correct.nf).
    def dorado_bin = params.dorado_path ?: 'dorado'
    """
    command -v ${dorado_bin} >/dev/null 2>&1 || {
        echo "ERROR: dorado is not installed (or not on PATH): '${dorado_bin}' not found. Install dorado or pass --dorado_path /path/to/dorado — see README.md 'Alternative: Conda'." >&2
        exit 1
    }
    ${dorado_bin} --version 2>&1 | head -n1 > dorado.version.txt
    """
}

// VERKKO_VERSION
// Same container as VERKKO.

process VERKKO_VERSION {
    tag "${params.sample}"
    label 'verkko'
    label 'quick'

    output:
    path "verkko.version.txt", emit: version

    script:
    """
    verkko --version 2>&1 | head -n1 > verkko.version.txt
    """
}
