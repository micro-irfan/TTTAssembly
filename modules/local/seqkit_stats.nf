// SEQKIT_STATS
// Read summary / QC statistics across all input FASTQs (ULK + Pore-C), always run.

process SEQKIT_STATS {
    tag "${params.sample}"
    publishDir "${params.output}/qc", mode: 'copy'

    input:
    path fastqs

    output:
    path "${params.sample}.read_stats.tsv", emit: stats

    script:
    """
    seqkit stats -a -T ${fastqs} > ${params.sample}.read_stats.tsv
    """
}
