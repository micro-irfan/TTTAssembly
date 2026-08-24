// assembly_qc.nf (modules/local/) — all processes for the standalone assembly-QC workflow
// (workflows/assembly_qc.nf, entry point ./assembly_qc.nf at the repo root). See CLAUDE.md §10.
// Each carries its own label (one per tool/conda env — see nextflow.config's conda profile);
// grouped into one file per the repo's directory-decluttering preference, not because they
// share a label (unlike common.nf/raw_qc.nf/tool_versions.nf, these 8 are all separate envs).

// GFASTATS
// Contiguity stats, per assembly (combined/H1/H2). Expected size comes from the workflow
// (workflows/assembly_qc.nf) since it depends on whether both haplotypes were provided:
// combined = 2*genome_size iff H1 & H2 both given, else genome_size; each haplotype is always
// genome_size.

process GFASTATS {
    tag "${params.sample}:${label}"
    label 'gfastats'
    publishDir "${params.output}/gfastats", mode: 'copy'

    input:
    tuple val(label), path(fasta), val(expected_size)

    output:
    tuple val(label), path("${params.sample}.${label}.gfastats"), emit: stats

    script:
    """
    gfastats ${fasta} ${expected_size} > ${params.sample}.${label}.gfastats
    """
}

// SEQTK_TELO
// Telomere-capped contig detection, per assembly (combined/H1/H2). Keeps the raw .telo.bed and
// .telo.count intermediates and additionally derives+prints the both-ends-capped contig count
// (a contig with telomere repeats detected at both ends of the same sequence). Meaningful only
// for telomere-bearing genomes — see CLAUDE.md §10.

process SEQTK_TELO {
    tag "${params.sample}:${label}"
    label 'seqtk'
    publishDir "${params.output}/seqtk_telo", mode: 'copy'

    input:
    tuple val(label), path(fasta)

    output:
    tuple val(label), path("${params.sample}.${label}.telo.bed"),           emit: bed
    tuple val(label), path("${params.sample}.${label}.telo.count"),         emit: count
    tuple val(label), path("${params.sample}.${label}.telo.both_ends.tsv"), emit: both_ends

    script:
    def prefix = "${params.sample}.${label}"
    """
    seqtk telo ${fasta} > ${prefix}.telo.bed 2> ${prefix}.telo.count
    both_ends=\$(cut -f1 ${prefix}.telo.bed | sort | uniq -d | wc -l)
    printf '%s\tboth_ends_capped\t%s\n' "${prefix}" "\${both_ends}" | tee ${prefix}.telo.both_ends.tsv
    """
}

// COMPLEASM
// Gene-completeness assessment, per assembly (combined/H1/H2). Supersedes BUSCO in this
// workflow (compleasm reuses BUSCO lineages but is faster) — see CLAUDE.md §10.

process COMPLEASM {
    tag "${params.sample}:${label}"
    label 'compleasm'
    publishDir "${params.output}/compleasm", mode: 'copy'

    input:
    tuple val(label), path(fasta)

    output:
    tuple val(label), path("compleasm_${label}/**"), emit: report

    script:
    def downloads_arg = params.compleasm_downloads ? "-L ${params.compleasm_downloads}" : ''
    """
    compleasm run -a ${fasta} -o compleasm_${label} -l ${params.compleasm_lineage} -t ${task.cpus} ${downloads_arg}
    """
}

// QUAST
// One run over every provided assembly (combined + H1/H2 if given) — not per-assembly, unlike
// GFASTATS/SEQTK_TELO/COMPLEASM/MERFIN. Reference-free by default (--est-ref-size); enable
// reference-based metrics with --quast_reference. --large auto-enables above 100 Mb unless
// --quast_large forces it either way.

process QUAST {
    tag "${params.sample}"
    label 'quast'
    publishDir "${params.output}/quast", mode: 'copy'

    input:
    path assembly_fastas

    output:
    path "quast/**", emit: report

    script:
    def large = (params.quast_large != null)
        ? params.quast_large.toString().toLowerCase() == 'true'
        : (params.genome_size as long) > 100_000_000
    def large_arg = large ? '--large' : ''
    def ref_arg   = params.quast_reference ? "-r ${params.quast_reference}" : ''
    """
    quast.py -t ${task.cpus} -o quast --est-ref-size ${params.genome_size} ${large_arg} ${ref_arg} ${assembly_fastas}
    """
}

// MERYL_COUNT
// Builds the meryl k-mer DB + histogram from --reads (prefer accurate reads — Illumina/HiFi;
// see the QV-reliability note in CLAUDE.md §10). Shared upstream: built once, feeds both
// MERQURY and MERFIN rather than each tool counting k-mers separately.

process MERYL_COUNT {
    tag "${params.sample}"
    label 'meryl'
    publishDir "${params.output}/meryl", mode: 'copy'

    input:
    path reads

    output:
    path "reads.meryl", emit: meryl_db
    path "reads.hist",  emit: histogram

    script:
    """
    meryl count k=${params.meryl_k} threads=${task.cpus} ${reads} output reads.meryl
    meryl histogram reads.meryl > reads.hist
    """
}

// MERQURY
// K-mer-based reference-free QV + completeness. Diploid mode (both haplotypes passed to
// merqury.sh in one call) when --assembly_H1 and --assembly_H2 are both given, else single
// mode against the combined assembly — decided by the caller (workflows/assembly_qc.nf), which
// passes the appropriate fasta(s) here.

process MERQURY {
    tag "${params.sample}"
    label 'merqury'
    publishDir "${params.output}/merqury", mode: 'copy'

    input:
    path meryl_db
    path assemblies

    output:
    path "${params.sample}_merqury*", emit: results

    script:
    """
    merqury.sh ${meryl_db} ${assemblies} ${params.sample}_merqury
    """
}

// GENOMESCOPE2
// Fits a k-mer coverage model to MERYL_COUNT's histogram, producing (among other outputs) the
// lookup table Merfin needs for its -prob argument. Only run when --tools includes merfin.

process GENOMESCOPE2 {
    tag "${params.sample}"
    label 'genomescope2'
    publishDir "${params.output}/genomescope2", mode: 'copy'

    input:
    path histogram

    output:
    path "genomescope/**",               emit: report
    path "genomescope/lookup_table.txt", emit: lookup_table

    script:
    """
    genomescope2 -i ${histogram} -o genomescope -k ${params.meryl_k} -p ${params.ploidy} --fitted_hist
    """
}

// MERFIN
// Read-aware QV*/completeness, per assembly (combined/H1/H2). Needs a homozygous k-mer coverage
// peak (-peak): --merfin_peak is required by this workflow — automatic derivation from
// GenomeScope2's output (kmercov) is brittle across genomescope2 versions and intentionally not
// implemented yet (TODO — see CLAUDE.md §10 open questions). assembly_qc.nf's validation fails
// fast before any process launches if --merfin_peak is missing while merfin is requested, so
// params.merfin_peak is guaranteed set by the time this process runs.

process MERFIN {
    tag "${params.sample}:${label}"
    label 'merfin'
    publishDir "${params.output}/merfin", mode: 'copy'

    input:
    tuple val(label), path(fasta)
    path meryl_db
    path lookup_table

    output:
    tuple val(label), path("${params.sample}.${label}.merfin*"), emit: results

    script:
    def prefix = "${params.sample}.${label}"
    """
    merfin -hist -sequence ${fasta} -readmers ${meryl_db} -prob ${lookup_table} \
        -peak ${params.merfin_peak} -output ${prefix}.merfin
    """
}
