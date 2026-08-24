// raw_qc.nf
// Read summary / QC on the ULK + Pore-C FASTQs — raw-reads QC, distinct from assembly QC
// (QUAST/Merqury/BUSCO/etc., planned separately — see sessions/session_assembly_qc.md).

// SEQKIT_STATS
// Read summary / QC statistics, always run. Called once per read source (ULK, Pore-C,
// Dorado-corrected) — see workflows/expert.nf — so each gets its own report; `label` drives
// the output filename ("ultralong" / "porec" / "corrected").

process SEQKIT_STATS {
    tag "${params.sample}:${label}"
    label 'qc'
    publishDir "${params.output}/qc", mode: 'copy'

    input:
    tuple val(label), path(fastqs)

    output:
    tuple val(label), path("${params.sample}.${label}.read_stats.tsv"), emit: stats

    script:
    """
    seqkit stats -a -T -j ${task.cpus} ${fastqs} > ${params.sample}.${label}.read_stats.tsv
    """
}

// NANOPLOT
// Optional (params.plot) ONT-native QC: read-length/quality plots + HTML report, run on the
// ultra-long FASTQ only (that's where read-length/N50 matters for this workflow).

process NANOPLOT {
    tag "${params.sample}"
    label 'qc'
    publishDir "${params.output}/qc", mode: 'copy'

    input:
    path ulk_fastq

    output:
    path "nanoplot_${params.sample}/**", emit: report

    script:
    """
    NanoPlot --fastq ${ulk_fastq} -t ${task.cpus} -o nanoplot_${params.sample}
    """
}
