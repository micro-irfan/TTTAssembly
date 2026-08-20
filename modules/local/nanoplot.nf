// NANOPLOT
// Optional (params.run_nanoplot) ONT-native QC: read-length/quality plots + HTML report,
// run on the ultra-long FASTQ only (that's where read-length/N50 matters for this workflow).

process NANOPLOT {
    tag "${params.sample}"
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
