// VERKKO
// Handles both the Pore-C and Hi-C branches with optional inputs; expert.nf invokes this once
// per run with whichever branch's channel is populated (the other passed as empty placeholders).
//
// Runs in a STABLE directory under ${params.output}, not the ephemeral per-task work dir.
// Verkko manages its own Snakemake-based incremental state inside its -d directory — if a
// re-run changes --threads/--max_memory_gb (or anything else that changes this task's hash),
// Nextflow would normally start the new attempt in a brand-new empty work dir, throwing away
// any progress Verkko had made. Pointing -d at a fixed absolute path instead means Verkko finds
// its own prior state there and resumes internally, regardless of what Nextflow's own work-dir
// hashing decides to do. Must be an absolute path: the script block's CWD is the task's work
// dir, so a bare `${params.output}/...` would resolve inside that ephemeral directory instead
// of the intended stable location — file(params.output) resolves relative paths against the
// launch directory (same semantics params.output already has via publishDir elsewhere in this
// pipeline), then .toAbsolutePath() locks that in regardless of the task's own CWD.
def VERKKO_DIR = "${file(params.output).toAbsolutePath()}/${params.sample}/verkko"

process VERKKO {
    tag "${params.sample}"
    label 'verkko'
    // No publishDir: Verkko already writes directly into its final home under ${params.output}
    // (see VERKKO_DIR above), so there's nothing left to copy.

    input:
    path nano_fastq                 // uncorrected ULK reads
    path hifi_fasta                 // Dorado-corrected ULK reads
    path porec_fastq                // may be [] when running the Hi-C branch
    tuple path(hic1), path(hic2)    // may be [ [], [] ] when running the Pore-C branch

    output:
    path "${VERKKO_DIR}/**",                            emit: assembly
    path "${VERKKO_DIR}/assembly.fasta",                emit: assembly_fasta
    path "${VERKKO_DIR}/assembly.haplotype1.fasta",     emit: haplotype1_fasta
    path "${VERKKO_DIR}/assembly.haplotype2.fasta",     emit: haplotype2_fasta

    script:
    // Verkko quirk: uncorrected ULK reads go to --nano, Dorado-corrected reads go to --hifi;
    // --no-correction tells Verkko not to re-correct them.
    def reads_arg = porec_fastq ? "--porec ${porec_fastq}" : "--hic1 ${hic1} --hic2 ${hic2}"
    // task.cpus is params.threads directly (withLabel: 'verkko' in nextflow.config) — --threads
    // is meant for the assembler itself, passed straight through to --local-cpus.
    """
    mkdir -p ${VERKKO_DIR}
    verkko --nano ${nano_fastq} --hifi ${hifi_fasta} ${reads_arg} \
        --no-correction --local-memory ${params.max_memory_gb} --local-cpus ${task.cpus} \
        -d ${VERKKO_DIR}
    """
}
