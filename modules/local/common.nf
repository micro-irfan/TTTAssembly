// common.nf
// samtools-based read processing, shared across the ULK / Pore-C / Hi-C inputs.

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
    def out     = "${params.sample}.${label}.fastq"
    def is_bam  = reads.name.toLowerCase().endsWith('.bam')
    def is_gz   = reads.name.toLowerCase().endsWith('.gz')
    // ULK and Pore-C use different length thresholds — see CLAUDE.md §3.
    def min_len = (label == 'ultralong') ? params.min_len_ulk : params.min_len_porec
    if (is_bam && params.filtering.toString().toLowerCase() == 'true')
        """
        samtools view -u -@ ${task.cpus} -e '[qs]>=${params.min_qs} && length(seq)>=${min_len}' ${reads} \
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

// MERGE_READS
// Merges multiple per-flowcell files into one (e.g. 2-3 ULK flowcells run separately). Only
// invoked when a comma-separated --*_reads value resolves to more than one file — see
// workflows/expert.nf, which imports this once per read source (MERGE_READS_ULK,
// MERGE_READS_POREC, MERGE_READS_HIC_R1, MERGE_READS_HIC_R2 — DSL2 forbids invoking the same
// process twice in one workflow scope). All files in one source's list must be the same type
// (all BAM, or all FASTQ/FASTQ.GZ); that's validated before this process is called.

process MERGE_READS {
    tag "${params.sample}:${label}"
    publishDir "${params.output}/merged", mode: 'copy'

    input:
    tuple val(label), path(reads), val(ext)

    output:
    tuple val(label), path("${params.sample}.${label}.merged.${ext}"), emit: merged

    script:
    def out = "${params.sample}.${label}.merged.${ext}"
    if (ext == 'bam')
        """
        samtools merge -@ ${task.cpus} -f ${out} ${reads}
        """
    else
        // Concatenation is valid for both plain and gzip-compressed FASTQ — gzip streams
        // concatenate cleanly into one multi-member stream that gunzip/samtools read fine.
        """
        cat ${reads} > ${out}
        """
}
