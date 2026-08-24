// YAK_COUNT (scalable mode, trio only — see CLAUDE.md §11)
// Builds a parental k-mer index from PREPARE_LONGREADS-normalized parent reads, for hifiasm
// trio phasing (-1/-2). Called once per parent — imported as YAK_COUNT_PAT / YAK_COUNT_MAT in
// workflows/scalable.nf (DSL2 forbids invoking the same process twice in one workflow scope;
// both parents are always processed together whenever trio mode fires).
//
// TODO(user): this takes one file per parent (long-read case). ONT's paired-end short-read
// variant uses a double process-substitution (`yak count ... <(cat r1 r2) <(cat r1 r2)`) —
// not implemented; single-file only for now.

process YAK_COUNT {
    tag "${params.sample}:${label}"
    label 'yak'

    input:
    tuple val(label), path(reads)

    output:
    tuple val(label), path("${label}.yak"), emit: yak

    script:
    """
    yak count -b37 -t ${task.cpus} -o ${label}.yak ${reads}
    """
}
