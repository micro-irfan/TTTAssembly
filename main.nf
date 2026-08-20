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
      nextflow run main.nf -profile docker --mode expert --sample <name> \\
        --ulk_reads <ulk.bam> [--porec_reads <porec.bam> | --hic_reads_1 <R1.fastq> --hic_reads_2 <R2.fastq>] \\
        --max_memory_gb <GB> [options]

    Required (expert mode):
      --ulk_reads       Path to the ULK BAM.
      --max_memory_gb   Integer GB passed to Verkko --local-memory.
      One of:
        --porec_reads             Path to the Pore-C BAM.
        --hic_reads_1/2           Paths to the Hi-C R1/R2 FASTQs (both required together).

    Options:
      --mode            expert | scalable                         (default: ${params.mode})
      --sample          Sample name, prefixes all output filenames (default: ${params.sample})
      --filtering       true | false — apply qs/length filter on BAM->FASTQ (default: ${params.filtering})
      --min_qs          Filter threshold, mean read qscore (default: ${params.min_qs})
      --min_len         Filter threshold, read length in bp (default: ${params.min_len})
      --run_nanoplot    Also run NanoPlot in the QC step (default: ${params.run_nanoplot})
      --threads         Default CPUs per process (default: ${params.threads})
      --dorado_device   Device string for `dorado correct -x` (default: ${params.dorado_device})
      --output          Output directory (default: ${params.output})
      --help            Show this message and exit.

    Examples:
      # Pore-C, expert mode
      nextflow run main.nf -profile docker \\
        --mode expert --sample HG002 \\
        --ulk_reads ulk.bam --porec_reads porec.bam \\
        --max_memory_gb 480 --output results

      # Hi-C, no pre-filtering
      nextflow run main.nf -profile docker \\
        --mode expert --sample HG002 --filtering false \\
        --ulk_reads ulk.bam --hic_reads_1 hic_R1.fastq --hic_reads_2 hic_R2.fastq \\
        --max_memory_gb 480 --output results

    Notes:
      --mode scalable is a stub for now; it fails fast until its steps are implemented.
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
}
else if (params.mode == 'scalable') {
    // Reads-type validation is not enforced for scalable mode (CLAUDE.md §3); the stub
    // workflow itself fails fast with an informative message.
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
