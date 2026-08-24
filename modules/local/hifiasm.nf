// hifiasm.nf (scalable mode — see CLAUDE.md §11)

// HIFIASM
// Assembles uncorrected ONT long reads directly (hifiasm --ont; no Dorado correction step —
// that's expert-mode only). Mode-dependent phasing args, mirroring VERKKO's established
// optional-tuple-input pattern (modules/local/verkko.nf): hic1/hic2 may be [[],[]] outside
// Hi-C mode, pat_yak/mat_yak may be [[],[]] outside trio mode. Emits the full output set plus
// a `gfas` channel matching all three p_ctg GFAs regardless of which sub-mode ran (default:
// bp.*, Hi-C: hic.*, trio: dip.*).

process HIFIASM {
    tag "${params.sample}"
    label 'hifiasm'
    publishDir "${params.output}/${params.sample}", mode: 'copy'

    input:
    path longreads                     // normalized long reads (PREPARE_LONGREADS)
    tuple path(hic1), path(hic2)       // may be [ [], [] ] outside Hi-C mode
    tuple path(pat_yak), path(mat_yak) // may be [ [], [] ] outside trio mode

    output:
    path "hifiasmONT_asm*",                 emit: all
    path "hifiasmONT_asm.*.p_ctg.gfa",      emit: gfas

    script:
    def mode_args = hic1
        ? "--h1 ${hic1} --h2 ${hic2}"
        : (pat_yak ? "-1 ${pat_yak} -2 ${mat_yak}" : '')
    // task.cpus is already params.threads * 2 (withLabel: 'hifiasm' in nextflow.config) — the
    // executor{ $local { cpus = ... } } override there raises the local executor's ceiling so
    // this doesn't get silently capped back down to the host's real core count. Same approach
    // as VERKKO's --local-cpus (modules/local/verkko.nf).
    """
    hifiasm --ont --threads ${task.cpus} --telo-m ${params.telo_motif} --dual-scaf -o hifiasmONT_asm \
        ${mode_args} ${longreads}
    """
}

// GFA_TO_FASTA
// Converts each p_ctg GFA (collapsed + hap1 + hap2 — 3 files regardless of sub-mode) to FASTA.
// Called once, fed HIFIASM.out.gfas.flatten() — Nextflow fans that out into one task per GFA,
// no aliasing needed (single call site, unlike PREPARE_LONGREADS/YAK_COUNT). Reuses the
// samtools container/env (label 'samtools') — just needs awk, already on that image.

process GFA_TO_FASTA {
    tag "${params.sample}:${gfa.baseName}"
    label 'samtools'
    publishDir "${params.output}/${params.sample}", mode: 'copy'

    input:
    path gfa

    output:
    path "${gfa.baseName}.fasta", emit: fasta

    script:
    """
    awk '/^S/{print ">" \$2 "\n" \$3}' ${gfa} > ${gfa.baseName}.fasta
    """
}
