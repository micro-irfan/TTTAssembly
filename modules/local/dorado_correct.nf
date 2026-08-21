// DORADO_CORRECT (GPU)
// ULK reads only. dorado correct downloads its correction model on first run (needs internet)
// unless it's pre-baked into the image or a model cache volume is mounted.

process DORADO_CORRECT {
    tag "${params.sample}"
    label 'dorado'
    label 'gpu'
    publishDir "${params.output}/corrected", mode: 'copy'

    input:
    path ulk_fastq

    output:
    path "${params.sample}.doradocorrect.fasta", emit: corrected

    script:
    // Fetching the correction model over the network is the default (dorado correct does this
    // automatically on first run). If a model cache volume is mounted, opt in on the CLI, e.g.:
    //   --dorado_model_path /models/<model_name>
    // NOTE: params.dorado_model_path is intentionally not declared in nextflow.config; leaving
    // it undeclared keeps it null (network fetch) unless the user opts in on the CLI.
    def model_path_arg = params.dorado_model_path ? "--model-path ${params.dorado_model_path}" : ''
    // --dorado_path overrides which `dorado` binary is invoked (e.g. a manual install under
    // -profile conda, which has no dorado conda package — see README.md "Alternative: Conda").
    // Defaults to plain 'dorado', resolved via PATH.
    def dorado_bin = params.dorado_path ?: 'dorado'
    """
    command -v ${dorado_bin} >/dev/null 2>&1 || {
        echo "ERROR: dorado is not installed (or not on PATH): '${dorado_bin}' not found. Install dorado or pass --dorado_path /path/to/dorado — see README.md 'Alternative: Conda'." >&2
        exit 1
    }
    ${dorado_bin} correct -x ${params.dorado_device} -t ${task.cpus} ${model_path_arg} ${ulk_fastq} > ${params.sample}.doradocorrect.fasta
    """
}
