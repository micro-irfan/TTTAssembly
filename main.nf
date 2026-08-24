#!/usr/bin/env nextflow
// ont-t2t-assembly — entry point
// Param validation + --mode dispatch. See CLAUDE.md for the full spec.

nextflow.enable.dsl = 2

include { EXPERT   } from './workflows/expert.nf'
include { SCALABLE } from './workflows/scalable.nf'

def helpMessage() {
    log.info """
    ONT long-read T2T de novo assembly pipeline (Verkko)
    =====================================================

    Usage:
      nextflow run main.nf -profile singularity --mode expert --sample <name> \\
        --ulk_reads <ulk.bam> [--porec_reads <porec.bam> | --hic_reads_1 <R1.fastq> --hic_reads_2 <R2.fastq>] \\
        --max_memory_gb <GB> [options]

    Required (expert mode):
      --ulk_reads       Path to the ULK BAM. Comma-separate multiple flowcells
                        (e.g. "fc1.bam,fc2.bam,fc3.bam") to merge them before use.
      --max_memory_gb   Integer GB passed to Verkko --local-memory.
      One of:
        --porec_reads             Path to the Pore-C BAM. Comma-separated list supported.
        --hic_reads_1/2           Paths to the Hi-C R1/R2 FASTQs (both required together).
                                   Each accepts a comma-separated list; --hic_reads_1 and
                                   --hic_reads_2 must list the same number of files.

    Multi-flowcell inputs:
      Any of --ulk_reads/--porec_reads/--hic_reads_1/--hic_reads_2 may be a comma-separated
      list (e.g. 2-3 ULK flowcells). All entries in one list must be the same file type (all
      .bam, or all .fastq/.fastq.gz); they are merged (samtools merge for BAM, concatenation
      for FASTQ) before the rest of the pipeline runs.

    Required (scalable mode):
      --long_reads      ONT long reads: .bam, .fastq, or .fastq.gz. Comma-separated list
                        supported (multiple flowcells merge, same as --ulk_reads above).

    Scalable-mode options (sub-mode is auto-selected — see CLAUDE.md §11):
      --mat_reads / --pat_reads   Maternal/paternal reads for trio phasing (via yak). Both
                                   required together, or neither. Mutually exclusive with
                                   --hic_reads_1/2.
      --hic_reads_1 / --hic_reads_2   Hi-C pair for Hi-C phasing (shared with expert mode).
                                        Both required together, or neither. Mutually exclusive
                                        with --mat_reads/--pat_reads.
      --telo_motif      Telomere motif for `hifiasm --telo-m` (default: ${params.telo_motif})
      --plot            Also run NanoPlot on the long reads (default: ${params.plot})
      --threads         Default CPUs per process (default: ${params.threads})
      --output          Output directory (default: ${params.output})

      Note: --max_memory_gb and --filtering (expert-only) are ignored in scalable mode.

    Options:
      --mode            expert | scalable                         (default: ${params.mode})
      --sample          Sample name, prefixes all output filenames (default: ${params.sample})
      --filtering       true | false — apply qs/length filter on BAM->FASTQ (default: ${params.filtering})
      --min_qs          Filter threshold, mean read qscore, ULK only — Pore-C has no qscore
                        filter (default: ${params.min_qs})
      --min_len_ulk     Filter threshold, ULK read length in bp (default: ${params.min_len_ulk})
      --min_len_porec   Filter threshold, Pore-C read length in bp; length-only, no qscore
                        filter (default: ${params.min_len_porec})
      --plot            Also run NanoPlot in the QC step (default: ${params.plot}). seqkit
                        stats always runs regardless.
      --threads         Default CPUs per process (default: ${params.threads})
      --dorado_device   Device string for `dorado correct -x` (default: ${params.dorado_device})
      --dorado_path     Override path to the dorado binary (default: 'dorado' on PATH). Mainly
                        for -profile conda, which has no dorado conda package.
      --output          Output directory (default: ${params.output})
      --help            Show this message and exit.

    Examples:
      # Pore-C, expert mode
      nextflow run main.nf -profile singularity \\
        --mode expert --sample HG002 \\
        --ulk_reads ulk.bam --porec_reads porec.bam \\
        --max_memory_gb 480 --output results

      # Hi-C, no pre-filtering
      nextflow run main.nf -profile singularity \\
        --mode expert --sample HG002 --filtering false \\
        --ulk_reads ulk.bam --hic_reads_1 hic_R1.fastq --hic_reads_2 hic_R2.fastq \\
        --max_memory_gb 480 --output results

      # Scalable mode, default (dual) sub-mode
      nextflow run main.nf -profile singularity \\
        --mode scalable --sample HG002 --long_reads long.bam --output results

      # Scalable mode, trio phasing
      nextflow run main.nf -profile singularity \\
        --mode scalable --sample HG002 --long_reads long.bam \\
        --pat_reads father.fastq --mat_reads mother.fastq --output results
    """.stripIndent()
}

if (params.help) {
    helpMessage()
    exit 0
}

// ---------------------------------------------------------------------------
// Validation — fail fast, before any process launches (CLAUDE.md §3)
// ---------------------------------------------------------------------------
def errors = []

if (params.mode == 'expert') {
    if (!params.ulk_reads)     errors << "--ulk_reads is required in expert mode"
    if (!params.max_memory_gb) errors << "--max_memory_gb is required in expert mode"

    def has_porec = params.porec_reads as boolean
    def has_hic1  = params.hic_reads_1 as boolean
    def has_hic2  = params.hic_reads_2 as boolean

    if (has_porec && (has_hic1 || has_hic2)) {
        errors << "Provide either --porec_reads or the --hic_reads_1/--hic_reads_2 pair, not both"
    }
    else if (!has_porec && !has_hic1 && !has_hic2) {
        errors << "One of --porec_reads or --hic_reads_1 + --hic_reads_2 is required in expert mode"
    }
    else if (!has_porec && (has_hic1 != has_hic2)) {
        errors << "--hic_reads_1 and --hic_reads_2 must both be provided"
    }
    else if (has_hic1 && has_hic2) {
        def n1 = params.hic_reads_1.split(',').size()
        def n2 = params.hic_reads_2.split(',').size()
        if (n1 != n2) {
            errors << "--hic_reads_1 and --hic_reads_2 must list the same number of " +
                      "comma-separated flowcell/lane files (got ${n1} vs ${n2})"
        }
    }
}
else if (params.mode == 'scalable') {
    if (!params.long_reads) errors << "--long_reads is required in scalable mode"

    def has_mat  = params.mat_reads as boolean
    def has_pat  = params.pat_reads as boolean
    def has_hic1 = params.hic_reads_1 as boolean
    def has_hic2 = params.hic_reads_2 as boolean

    if (has_mat != has_pat) {
        errors << "--mat_reads and --pat_reads must both be provided (trio phasing needs both parents)"
    }
    if (has_hic1 != has_hic2) {
        errors << "--hic_reads_1 and --hic_reads_2 must both be provided"
    }
    if (has_mat && has_pat && has_hic1 && has_hic2) {
        errors << "Provide either --mat_reads/--pat_reads (trio) or --hic_reads_1/--hic_reads_2 " +
                  "(Hi-C), not both — choose one phasing method"
    }
}
else {
    errors << "Unknown --mode '${params.mode}'; expected 'expert' or 'scalable'"
}

if (errors) {
    log.error "Parameter validation failed:\n" + errors.collect { "  - ${it}" }.join('\n')
    exit 1
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------
workflow {
    if (params.mode == 'expert') {
        EXPERT()
    }
    else if (params.mode == 'scalable') {
        SCALABLE()
    }
}
