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
    """
    verkko --nano ${nano_fastq} --hifi ${hifi_fasta} ${reads_arg} \
        --no-correction --local-memory ${params.max_memory_gb} --local-cpus ${task.cpus} \
        -d verkko_output
    """
}
