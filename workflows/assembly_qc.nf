// ASSEMBLY_QC workflow
// Dispatches the requested --tools against the provided assembly FASTA(s). Reads params.* the
// same way workflows/expert.nf's EXPERT workflow does — assembly_qc.nf (root) has already
// validated everything (required params, --tools tokens, --reads/--merfin_peak requirements)
// before this is called, so no re-validation happens here.
//
// GFASTATS/SEQTK_TELO/COMPLEASM/MERFIN each run per assembly (1-3 of: combined/H1/H2). Nextflow
// DSL2 forbids invoking the same process more than once in one workflow scope (see CLAUDE.md
// §3's multi-flowcell note for where the main pipeline hit this), so each is called exactly
// once here, fed a single channel covering every assembly — Nextflow fans that out into one
// task per item automatically, rather than looping and calling the process per assembly.

include { GFASTATS; SEQTK_TELO; COMPLEASM; QUAST; MERYL_COUNT; MERQURY; GENOMESCOPE2; MERFIN } from '../modules/local/assembly_qc.nf'

// Splits/validates --tools the same way assembly_qc.nf's validation block does. Re-parsed here
// (rather than passed in) to match the main pipeline's convention of workflows reading params
// directly instead of receiving pre-parsed arguments from the entry script.
def parseTools(String toolsStr) {
    def allowed = ['gfastats', 'seqtk', 'compleasm', 'quast', 'merqury', 'merfin'] as Set
    if (!toolsStr || toolsStr.trim().toLowerCase() == 'none') return [] as Set
    toolsStr.split(',').collect { it.trim().toLowerCase() } as Set
}

workflow ASSEMBLY_QC {

    def tools = parseTools(params.tools)

    // --- Build the assembly list: always combined, optionally H1/H2 ---------
    def has_h1 = params.assembly_H1 as boolean
    def has_h2 = params.assembly_H2 as boolean
    def genome_size   = params.genome_size as long
    def combined_size = (has_h1 && has_h2) ? genome_size * 2 : genome_size

    def assemblies = [ [ 'combined', file(params.assembly), combined_size ] ]
    if (has_h1) assemblies << [ 'h1', file(params.assembly_H1), genome_size ]
    if (has_h2) assemblies << [ 'h2', file(params.assembly_H2), genome_size ]

    assemblies_ch = Channel.fromList(assemblies).map { label, fasta, size -> [ label, fasta ] }

    // --- Per-assembly tools ---------------------------------------------------
    if ('gfastats' in tools) {
        GFASTATS(Channel.fromList(assemblies))
    }
    if ('seqtk' in tools) {
        SEQTK_TELO(assemblies_ch)
    }
    if ('compleasm' in tools) {
        COMPLEASM(assemblies_ch)
    }

    // --- QUAST: one run over every provided assembly --------------------------
    if ('quast' in tools) {
        QUAST(assemblies_ch.map { label, fasta -> fasta }.collect())
    }

    // --- Merqury / Merfin share MERYL_COUNT ------------------------------------
    if ('merqury' in tools || 'merfin' in tools) {
        reads_ch = Channel.fromPath(params.reads, checkIfExists: true).collect()
        MERYL_COUNT(reads_ch)
    }

    if ('merqury' in tools) {
        merqury_fastas_ch = (has_h1 && has_h2)
            ? Channel.of(file(params.assembly_H1), file(params.assembly_H2)).collect()
            : Channel.of(file(params.assembly)).collect()
        MERQURY(MERYL_COUNT.out.meryl_db, merqury_fastas_ch)
    }

    if ('merfin' in tools) {
        GENOMESCOPE2(MERYL_COUNT.out.histogram)
        MERFIN(assemblies_ch, MERYL_COUNT.out.meryl_db, GENOMESCOPE2.out.lookup_table)
    }
}
