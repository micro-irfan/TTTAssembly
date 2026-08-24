// SCALABLE workflow
// hifiasm-based ONT long-read assembly (scalable mode, ONT's "scalable (near) T2T" method) —
// see CLAUDE.md §11. Reads params.* the same way workflows/expert.nf's EXPERT workflow does;
// main.nf has already validated (--long_reads required, exactly-one-of mat/pat, exactly-one-of
// hic1/hic2, trio+Hi-C mutually exclusive) before this is called.
//
// Sub-mode is inferred (trio > Hi-C > default). PREPARE_LONGREADS is reused for all three read
// sources that might need BAM/FASTQ normalization (--long_reads always; --pat_reads/
// --mat_reads in trio mode) — DSL2 forbids invoking the same process more than once in one
// workflow scope, so each is imported under its own alias, same pattern as BAM_TO_FASTQ_ULK/
// _POREC/etc. in workflows/expert.nf. YAK_COUNT is likewise aliased per parent (both always
// called together when trio mode fires).

include { PREPARE_LONGREADS as PREPARE_LONGREADS_LONGREADS } from '../modules/local/common.nf'
include { PREPARE_LONGREADS as PREPARE_LONGREADS_PAT       } from '../modules/local/common.nf'
include { PREPARE_LONGREADS as PREPARE_LONGREADS_MAT       } from '../modules/local/common.nf'
include { SEQKIT_STATS as SEQKIT_STATS_LONGREADS } from '../modules/local/raw_qc.nf'
include { NANOPLOT                               } from '../modules/local/raw_qc.nf'
include { YAK_COUNT as YAK_COUNT_PAT } from '../modules/local/yak_count.nf'
include { YAK_COUNT as YAK_COUNT_MAT } from '../modules/local/yak_count.nf'
include { HIFIASM ; GFA_TO_FASTA }    from '../modules/local/hifiasm.nf'

// Splits a comma-separated --long_reads value into files + a shared extension ('bam' |
// 'fastq' | 'fastq.gz') — same pattern as workflows/expert.nf's splitReadsParam().
def splitReadsParam(String paramName, String pathsStr) {
    def files = pathsStr.split(',').collect { file(it.trim()) }
    def exts  = files.collect { f ->
        def n = f.name.toLowerCase()
        n.endsWith('.bam')                                ? 'bam' :
        (n.endsWith('.fastq.gz') || n.endsWith('.fq.gz'))  ? 'fastq.gz' :
                                                              'fastq'
    }.unique()
    if (exts.size() > 1) {
        error "--${paramName}: comma-separated inputs mix file types (${exts.join(', ')}) — " +
              "all entries must be the same type (all .bam, or all .fastq/.fastq.gz)."
    }
    [ files, exts[0] ]
}

// Single-file extension detection for --pat_reads/--mat_reads (no comma-separated support —
// see CLAUDE.md §11 open questions).
def detectExt(f) {
    def n = f.name.toLowerCase()
    n.endsWith('.bam')                               ? 'bam' :
    (n.endsWith('.fastq.gz') || n.endsWith('.fq.gz')) ? 'fastq.gz' :
                                                         'fastq'
}

workflow SCALABLE {

    // --- Sub-mode selection: trio > Hi-C > default ---------------------------
    def has_trio = (params.mat_reads as boolean) && (params.pat_reads as boolean)
    def has_hic  = (params.hic_reads_1 as boolean) && (params.hic_reads_2 as boolean)

    // --- Step 1: normalize long reads (merge multi-flowcell + BAM/FASTQ -> FASTQ) -----------
    def (long_files, long_ext) = splitReadsParam('long_reads', params.long_reads)
    longreads_out   = PREPARE_LONGREADS_LONGREADS(Channel.of([ 'longreads', long_files, long_ext ]))
    longreads_fastq = longreads_out.fastq.map { label, fastq -> fastq }

    // --- Step 2: pre-assembly QC, same as expert mode -------------------------
    SEQKIT_STATS_LONGREADS(longreads_out.fastq)

    if (params.plot.toString().toLowerCase() == 'true') {
        NANOPLOT(longreads_fastq)
    }

    // --- Step 3: trio phasing (yak), only when both parents are given --------
    if (has_trio) {
        def pat_ext = detectExt(file(params.pat_reads))
        def mat_ext = detectExt(file(params.mat_reads))
        pat_fastq = PREPARE_LONGREADS_PAT(Channel.of([ 'pat', file(params.pat_reads), pat_ext ])).fastq.map { label, fastq -> fastq }
        mat_fastq = PREPARE_LONGREADS_MAT(Channel.of([ 'mat', file(params.mat_reads), mat_ext ])).fastq.map { label, fastq -> fastq }

        pat_yak_ch = YAK_COUNT_PAT(pat_fastq.map { fq -> [ 'pat', fq ] }).yak.map { label, yak -> yak }
        mat_yak_ch = YAK_COUNT_MAT(mat_fastq.map { fq -> [ 'mat', fq ] }).yak.map { label, yak -> yak }
        yak_ch     = pat_yak_ch.combine(mat_yak_ch)
    }
    else {
        yak_ch = Channel.of([ [], [] ])
    }

    // --- Step 4: Hi-C pair, only when both are given --------------------------
    if (has_hic) {
        hic_ch = Channel.of([ file(params.hic_reads_1), file(params.hic_reads_2) ])
    }
    else {
        hic_ch = Channel.of([ [], [] ])
    }

    // --- Step 5: hifiasm assembly -> GFA -> FASTA ------------------------------
    HIFIASM(longreads_fastq, hic_ch, yak_ch)
    GFA_TO_FASTA(HIFIASM.out.gfas.flatten())
}
