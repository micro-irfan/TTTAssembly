// VERKKO
// Handles both the Pore-C and Hi-C branches with optional inputs; expert.nf invokes this once
// per run with whichever branch's channel is populated (the other passed as empty placeholders).

process VERKKO {
    tag "${params.sample}"
    label 'verkko'
    publishDir "${params.output}", mode: 'copy'

    input:
    path nano_fastq                 // uncorrected ULK reads
    path hifi_fasta                 // Dorado-corrected ULK reads
    path porec_fastq                // may be [] when running the Hi-C branch
    tuple path(hic1), path(hic2)    // may be [ [], [] ] when running the Pore-C branch

    output:
    path "verkko_output/**", emit: assembly
    path "verkko_output/assembly.fasta", emit: assembly_fasta
    path "verkko_output/assembly.haplotype1.fasta", emit: haplotype1_fasta
    path "verkko_output/assembly.haplotype2.fasta", emit: haplotype2_fasta

    script:
    // Verkko quirk: uncorrected ULK reads go to --nano, Dorado-corrected reads go to --hifi;
    // --no-correction tells Verkko not to re-correct them.
    def reads_arg = porec_fastq ? "--porec ${porec_fastq}" : "--hic1 ${hic1} --hic2 ${hic2}"
    // --local-cpus is deliberately params.threads * 2, not task.cpus: the `cpus` directive
    // (nextflow.config, withLabel: 'verkko') is capped by the local executor to the host's
    // actual available processors, so task.cpus can't exceed that even when we want Verkko's
    // internal thread pool sized larger. Computed straight from params here instead, decoupled
    // from Nextflow's own scheduling/cpu accounting.
    def local_cpus = (params.threads as int) * 2
    """
    verkko --nano ${nano_fastq} --hifi ${hifi_fasta} ${reads_arg} \
        --no-correction --local-memory ${params.max_memory_gb} --local-cpus ${local_cpus} \
        -d verkko_output
    """
}
