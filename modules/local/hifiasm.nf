// hifiasm.nf (scalable mode — see CLAUDE.md §11)

// HIFIASM
// Assembles uncorrected ONT long reads directly (hifiasm --ont; no Dorado correction step —
// that's expert-mode only). Mode-dependent phasing args, mirroring VERKKO's established
// optional-tuple-input pattern (modules/local/verkko.nf): hic1/hic2 may be [[],[]] outside
// Hi-C mode, pat_yak/mat_yak may be [[],[]] outside trio mode. Emits the full output set plus
// a `gfas` channel matching all three p_ctg GFAs regardless of which sub-mode ran (default:
// bp.*, Hi-C: hic.*, trio: dip.*).
//
// Runs in a STABLE directory under ${params.output}, not the ephemeral per-task work dir — same
// rationale and mechanism as VERKKO_DIR (modules/local/verkko.nf). hifiasm caches its
// error-corrected reads and all-vs-all overlaps in binary checkpoint files (*.ec.bin,
// *.ovlp.reverse.bin, *.ovlp.source.bin) next to its output prefix, and on a subsequent run with
// the same prefix it detects and reuses them instead of recomputing that stage. If a re-run
// changes --threads (or anything else that changes this task's hash), Nextflow would normally
// start the retry in a brand-new empty work dir, losing those .bin files and forcing a full
// recompute. Pointing the output prefix at a fixed absolute path instead means hifiasm finds its
// own prior checkpoint files there on any re-run. Must be an absolute path for the same reason
// as VERKKO_DIR: the script block's CWD is the task's own ephemeral work dir, so a bare
// `${params.output}/...` would resolve inside that instead of the intended stable location.
def HIFIASM_DIR = "${file(params.output).toAbsolutePath()}/${params.sample}/hifiasm"

process HIFIASM {
    tag "${params.sample}"
    label 'hifiasm'
    // No publishDir: hifiasm already writes directly into its final home under ${params.output}
    // (see HIFIASM_DIR above), so there's nothing left to copy.

    input:
    path longreads                     // normalized long reads (PREPARE_LONGREADS)
    tuple path(hic1), path(hic2)       // may be [ [], [] ] outside Hi-C mode
    tuple path(pat_yak), path(mat_yak) // may be [ [], [] ] outside trio mode

    output:
    path "${HIFIASM_DIR}/hifiasmONT_asm*",            emit: all
    path "${HIFIASM_DIR}/hifiasmONT_asm.*.p_ctg.gfa", emit: gfas

    script:
    def mode_args = hic1
        ? "--h1 ${hic1} --h2 ${hic2}"
        : (pat_yak ? "-1 ${pat_yak} -2 ${mat_yak}" : '')
    // task.cpus is params.threads directly (withLabel: 'hifiasm' in nextflow.config) — --threads
    // is meant for the assembler itself, passed straight through to hifiasm's -t. Same approach
    // as VERKKO's --local-cpus (modules/local/verkko.nf).
    // hifiasm has no --threads long option, only -t (verified against CommandLines.cpp's
    // ketopt long_options table for v0.25.0 — thread count is parsed solely via `-t`).
    """
    mkdir -p ${HIFIASM_DIR}
    hifiasm --ont -t ${task.cpus} --telo-m ${params.telo_motif} --dual-scaf \
        -o ${HIFIASM_DIR}/hifiasmONT_asm ${mode_args} ${longreads}
    """
}

// GFA_TO_FASTA
// Converts each p_ctg GFA (collapsed + hap1 + hap2 — 3 files regardless of sub-mode) to FASTA.
// Called once, fed HIFIASM.out.gfas.flatten() — Nextflow fans that out into one task per GFA,
// no aliasing needed (single call site, unlike PREPARE_LONGREADS/YAK_COUNT). Reuses the
// samtools container/env (label 'samtools') — just needs awk, already on that image.
// Published alongside HIFIASM's own output (HIFIASM_DIR, same stable path) rather than a plain
// task-work-dir + publishDir copy, so the GFA and its derived FASTA live side by side.

process GFA_TO_FASTA {
    tag "${params.sample}:${gfa.baseName}"
    label 'samtools'
    publishDir "${HIFIASM_DIR}", mode: 'copy'

    input:
    path gfa

    output:
    path "${gfa.baseName}.fasta", emit: fasta

    script:
    """
    awk '/^S/{print ">" \$2 "\n" \$3}' ${gfa} > ${gfa.baseName}.fasta
    """
}
