#!/usr/bin/env nextflow
// assembly_qc.nf — standalone assembly-QC workflow entry point
// Separate from the main ONT T2T assembly pipeline (main.nf) — does not chain off it, does not
// modify it. Evaluates one or more assembly FASTAs with a user-selected set of QC tools.
// See CLAUDE.md §10 for the full spec.

nextflow.enable.dsl = 2

include { ASSEMBLY_QC } from './workflows/assembly_qc.nf'

def helpMessage() {
    log.info """
    Standalone assembly-QC workflow
    ================================

    Usage:
      nextflow run assembly_qc.nf -profile conda \\
        --assembly asm.fasta [--assembly_H1 h1.fasta --assembly_H2 h2.fasta] \\
        --tools gfastats,seqtk,compleasm [options]

    Required:
      --assembly        Primary/combined assembly FASTA (the whole genome for haploid organisms).

    Options:
      --assembly_H1         Optional haplotype 1 FASTA.
      --assembly_H2         Optional haplotype 2 FASTA.
      --tools               Comma-separated subset of {gfastats,seqtk,compleasm,quast,merqury,merfin},
                             or 'none' (default: ${params.tools})
      --output              Output directory (default: ${params.output})
      --sample              Output prefix (default: ${params.sample})
      --genome_size         Haploid expected size in bp; used by gfastats/QUAST/GenomeScope2
                             (default: ${params.genome_size})
      --ploidy              1 (bacteria/haploid) or 2 (diploid); used by GenomeScope2/Merfin
                             (default: ${params.ploidy})
      --reads               Reads for the meryl k-mer DB (quoted glob). Required if --tools
                             includes merqury or merfin. Prefer accurate reads (Illumina/HiFi).
      --meryl_k              k-mer size for meryl/Merqury/Merfin (default: ${params.meryl_k})
      --merfin_peak          Homozygous k-mer coverage peak for Merfin. Required if --tools
                             includes merfin (automatic derivation from GenomeScope2 is not yet
                             implemented — see CLAUDE.md §10).
      --compleasm_lineage    compleasm lineage, e.g. primates/mammalia/bacteria/eukaryota
                             (default: ${params.compleasm_lineage})
      --compleasm_downloads  Optional pre-downloaded lineage dir (enables offline compleasm)
      --quast_reference      Optional reference FASTA for reference-based QUAST (default:
                             reference-free)
      --quast_large          true/false to force QUAST --large. If unset, auto-enables when
                             --genome_size > 100 Mb
      --help                Show this message and exit.

    Examples:
      # Bacterial/haploid genome, default (read-free) tools
      nextflow run assembly_qc.nf -profile conda --assembly asm.fasta --genome_size 5000000

      # Human diploid T2T assembly, full tool set against CHM13
      nextflow run assembly_qc.nf -profile conda \\
        --assembly combined.fasta --assembly_H1 hap1.fasta --assembly_H2 hap2.fasta \\
        --tools gfastats,seqtk,compleasm,quast,merqury,merfin \\
        --reads 'reads/*.fastq.gz' --merfin_peak 35 \\
        --quast_reference chm13v2.0.fasta --output results/assembly_qc

    Notes:
      Conda-only for now (-profile conda) — Singularity support for this workflow is not yet
      wired up (see CLAUDE.md §10).
    """.stripIndent()
}

// ---------------------------------------------------------------------------
// Entry point. Everything (defaults, help, validation, dispatch) lives inside this one
// top-level `workflow {}` block rather than as bare top-level statements — Nextflow's strict
// parser rejects "Statements cannot be mixed with script declarations" when imperative code sits
// outside a process/workflow/function (hit in practice — see sessions/session.md). Only
// `include`/`def` declarations are allowed at the true top level.
// ---------------------------------------------------------------------------
workflow {
    // --output/--sample aren't given their own defaults in nextflow.config — that file is
    // shared with main.nf, and a second default for the same key there would silently win for
    // both entry scripts (see the comment in nextflow.config). Apply this workflow's preferred
    // defaults here instead, before --help or validation run, but only when the value is still
    // exactly the inherited main-pipeline default (i.e. the user didn't pass --output/--sample
    // explicitly) — narrow edge case: someone who explicitly wants literally "results"/"sample"
    // for a QC run would get overridden too, an acceptable trade-off for sensible defaults in
    // the common case.
    if (params.output == 'results') { params.output = 'assembly_qc' }
    if (params.sample == 'sample')  { params.sample = 'assembly' }

    if (params.help) {
        helpMessage()
        exit 0
    }

    // -----------------------------------------------------------------------
    // Validation — fail fast, before any process launches
    // -----------------------------------------------------------------------
    def errors = []

    def ALLOWED_TOOLS = ['gfastats', 'seqtk', 'compleasm', 'quast', 'merqury', 'merfin'] as Set

    if (!params.assembly) {
        errors << "--assembly is required"
    }

    def toolsStr = (params.tools ?: '').trim().toLowerCase()
    def tools    = (!toolsStr || toolsStr == 'none') ? [] as Set : toolsStr.split(',').collect { it.trim() } as Set

    if (tools) {
        def bad = tools.findAll { !(it in ALLOWED_TOOLS) }
        if (bad) {
            errors << "--tools: unknown token(s) ${bad.join(', ')} — expected a comma-separated " +
                      "subset of ${ALLOWED_TOOLS.join(', ')}, or 'none'"
        }
    }

    if (('merqury' in tools || 'merfin' in tools) && !params.reads) {
        errors << "--reads is required when --tools includes merqury or merfin"
    }

    if ('merfin' in tools && !params.merfin_peak) {
        errors << "--merfin_peak is required when --tools includes merfin (automatic derivation " +
                  "from GenomeScope2 output is not implemented — see CLAUDE.md §10)"
    }

    if (errors) {
        log.error "Parameter validation failed:\n" + errors.collect { "  - ${it}" }.join('\n')
        exit 1
    }

    // -----------------------------------------------------------------------
    // Dispatch
    // -----------------------------------------------------------------------
    ASSEMBLY_QC()
}
