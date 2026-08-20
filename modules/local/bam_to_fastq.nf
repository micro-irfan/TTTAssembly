// BAM_TO_FASTQ
// Reused for both the ULK (label "ultralong") and Pore-C (label "porec") reads.
// Accepts BAM (filtered or plain conversion, per params.filtering) or an already-FASTQ
// input (passed through under the conventional output name) — see session.md decision #2.

process BAM_TO_FASTQ {
    tag "${params.sample}:${label}"
    publishDir "${params.output}/fastq", mode: 'copy'

    input:
    tuple val(label), path(reads)

    output:
    tuple val(label), path("${params.sample}.${label}.fastq"), emit: fastq

    script:
    def out    = "${params.sample}.${label}.fastq"
    def is_bam = reads.name.toLowerCase().endsWith('.bam')
    def is_gz  = reads.name.toLowerCase().endsWith('.gz')
    if (is_bam && params.filtering.toString().toLowerCase() == 'true')
        """
        samtools view -u -@ ${task.cpus} -e '[qs]>=${params.min_qs} && length(seq)>=${params.min_len}' ${reads} \
            | samtools fastq -@ ${task.cpus} > ${out}
        """
    else if (is_bam)
        """
        samtools fastq -@ ${task.cpus} ${reads} > ${out}
        """
    else if (is_gz)
        """
        zcat ${reads} > ${out}
        """
    else
        """
        cat ${reads} > ${out}
        """
}
