// common.nf
// samtools-based read processing, shared across the ULK / Pore-C / Hi-C inputs.

// BAM_TO_FASTQ
// Merges any number of per-flowcell files for one read source into a single FASTQ, applying
// the qs/length filter for BAM input (per params.filtering) — one process, one piped command,
// no intermediate merged BAM/FASTQ ever touches disk. Reused for ULK, Pore-C, and Hi-C R1/R2
// (imported under a distinct alias per source in workflows/expert.nf — DSL2 forbids invoking
// the same process twice in one workflow scope) via the caller-supplied `ext` ('bam' | 'fastq'
// | 'fastq.gz'), which is validated uniform across the source's file list before this process
// is called. Hi-C reads are already FASTQ, so they only ever take the merge-only path below —
// no filtering is ever applied to non-BAM input, matching the ULK/Pore-C passthrough behaviour.
// Fails fast if the resulting FASTQ is empty (see the `[ -s ... ]` check) rather than letting
// an empty read set silently reach Dorado/Verkko.

process BAM_TO_FASTQ {
    tag "${params.sample}:${label}"
    label 'samtools'
    publishDir "${params.output}/fastq", mode: 'copy'

    input:
    tuple val(label), path(reads), val(ext)

    output:
    tuple val(label), path("${params.sample}.${label}.fastq"), emit: fastq

    script:
    def out    = "${params.sample}.${label}.fastq"
    def is_bam = (ext == 'bam')
    def is_gz  = (ext == 'fastq.gz')
    def multi  = (reads instanceof List) && reads.size() > 1
    // ULK and Pore-C use different length thresholds — see CLAUDE.md §3. ULK also filters on
    // qscore (--min_qs); Pore-C is length-only, no qscore requirement.
    def min_len     = (label == 'ultralong') ? params.min_len_ulk : params.min_len_porec
    def filter_expr = (label == 'ultralong')
        ? "[qs]>=${params.min_qs} && length(seq)>=${min_len}"
        : "length(seq)>=${min_len}"
    def do_filter = params.filtering.toString().toLowerCase() == 'true'
    // Merging N>1 BAMs streams straight into the filter/convert step (`-o -` / `-` = stdin);
    // a single BAM skips samtools merge entirely (no point re-muxing a single file).
    def merge_cmd = "samtools merge -u -@ ${task.cpus} -o - ${reads}"

    def cmd
    if (is_bam && multi && do_filter)
        cmd = "${merge_cmd} | samtools view -u -@ ${task.cpus} -e '${filter_expr}' - | samtools fastq -@ ${task.cpus} - > ${out}"
    else if (is_bam && multi)
        cmd = "${merge_cmd} | samtools fastq -@ ${task.cpus} - > ${out}"
    else if (is_bam && do_filter)
        cmd = "samtools view -u -@ ${task.cpus} -e '${filter_expr}' ${reads} | samtools fastq -@ ${task.cpus} > ${out}"
    else if (is_bam)
        cmd = "samtools fastq -@ ${task.cpus} ${reads} > ${out}"
    else if (is_gz)
        // zcat accepts multiple files, decompressing+concatenating in one pass — merge and
        // decompress together, same as the BAM branches never touch an intermediate file.
        cmd = "zcat ${reads} > ${out}"
    else
        cmd = "cat ${reads} > ${out}"

    """
    ${cmd}

    [ -s ${out} ] || {
        echo "ERROR: ${out} is empty (label=${label}) — the qs/length filter may be too strict," \
             "or the input has no reads. Check --min_qs/--min_len_ulk/--min_len_porec/--filtering," \
             "or the input BAM/FASTQ for this read source." >&2
        exit 1
    }
    """
}
