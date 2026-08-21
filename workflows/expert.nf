// EXPERT workflow
// samtools (merge + BAM -> FASTQ, filtered) -> QC (seqkit stats [+ NanoPlot]) -> Dorado correct
// (GPU, ULK only) -> Verkko assembly (Pore-C or Hi-C branch). Reads-type is inferred from which
// of params.porec_reads / params.hic_reads_1+2 is set; main.nf has already validated that
// exactly one of those is populated before this workflow is invoked.
//
// Nextflow DSL2 only allows a process to be *invoked* once per workflow scope — fine for
// VERKKO/NANOPLOT (mutually-exclusive/conditional single call sites), but BAM_TO_FASTQ and
// SEQKIT_STATS each need to run on more than one read source in the same run (e.g. ULK +
// corrected always both run), so each is imported once per source with `as` and called under
// that distinct name.

include { BAM_TO_FASTQ as BAM_TO_FASTQ_ULK       } from '../modules/local/common.nf'
include { BAM_TO_FASTQ as BAM_TO_FASTQ_POREC     } from '../modules/local/common.nf'
include { BAM_TO_FASTQ as BAM_TO_FASTQ_HIC_R1    } from '../modules/local/common.nf'
include { BAM_TO_FASTQ as BAM_TO_FASTQ_HIC_R2    } from '../modules/local/common.nf'

include { SEQKIT_STATS as SEQKIT_STATS_ULK       } from '../modules/local/qc.nf'
include { SEQKIT_STATS as SEQKIT_STATS_POREC     } from '../modules/local/qc.nf'
include { SEQKIT_STATS as SEQKIT_STATS_CORRECTED } from '../modules/local/qc.nf'
include { NANOPLOT                               } from '../modules/local/qc.nf'
include { DORADO_CORRECT                         } from '../modules/local/dorado_correct.nf'
include { VERKKO                                 } from '../modules/local/verkko.nf'
include { SAMTOOLS_VERSION  ; QC_VERSIONS   ; DORADO_VERSION ; VERKKO_VERSION } from '../modules/local/tool_versions.nf'
include { SOFTWARE_VERSIONS } from '../modules/local/software_versions.nf'

// Splits a comma-separated --*_reads value into files + a shared extension ('bam' | 'fastq' |
// 'fastq.gz'). Multiple flowcells per input (e.g. 2-3 ULK flowcells) are common; they must all
// be the same file type so BAM_TO_FASTQ can merge them.
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

workflow EXPERT {

    // --- Step 1: reads -> FASTQ (merge multi-flowcell + qs/length filter, one step) ---------
    def (ulk_files, ulk_ext) = splitReadsParam('ulk_reads', params.ulk_reads)
    ulk_out   = BAM_TO_FASTQ_ULK(Channel.of([ 'ultralong', ulk_files, ulk_ext ]))
    ulk_fastq = ulk_out.fastq.map { label, fastq -> fastq }

    if (params.porec_reads) {
        def (porec_files, porec_ext) = splitReadsParam('porec_reads', params.porec_reads)
        porec_out       = BAM_TO_FASTQ_POREC(Channel.of([ 'porec', porec_files, porec_ext ]))
        porec_fastq_ch  = porec_out.fastq.map { label, fastq -> fastq }
    }
    else {
        porec_fastq_ch = Channel.empty()
    }

    // --- Step 2: read summary / QC (one report per read source) -------------
    SEQKIT_STATS_ULK(ulk_out.fastq)

    if (params.porec_reads) {
        SEQKIT_STATS_POREC(porec_out.fastq)
    }

    if (params.plot.toString().toLowerCase() == 'true') {
        NANOPLOT(ulk_fastq)
    }

    // --- Step 3: Dorado correct (ULK only, GPU) -----------------------------
    DORADO_CORRECT(ulk_fastq)
    SEQKIT_STATS_CORRECTED(DORADO_CORRECT.out.corrected.map { fasta -> [ 'corrected', fasta ] })

    // --- Step 4: Verkko assembly (Pore-C or Hi-C branch) --------------------
    if (params.porec_reads) {
        VERKKO(
            ulk_fastq,
            DORADO_CORRECT.out.corrected,
            porec_fastq_ch,
            [ [], [] ]
        )
    }
    else {
        def (hic1_files, hic1_ext) = splitReadsParam('hic_reads_1', params.hic_reads_1)
        def (hic2_files, hic2_ext) = splitReadsParam('hic_reads_2', params.hic_reads_2)
        if (hic1_files.size() != hic2_files.size()) {
            error "--hic_reads_1 and --hic_reads_2 must list the same number of comma-separated " +
                  "flowcell/lane files (got ${hic1_files.size()} vs ${hic2_files.size()})"
        }
        hic1_ch = BAM_TO_FASTQ_HIC_R1(Channel.of([ 'hic_r1', hic1_files, hic1_ext ])).fastq.map { label, f -> f }
        hic2_ch = BAM_TO_FASTQ_HIC_R2(Channel.of([ 'hic_r2', hic2_files, hic2_ext ])).fastq.map { label, f -> f }

        VERKKO(
            ulk_fastq,
            DORADO_CORRECT.out.corrected,
            [],
            hic1_ch.combine(hic2_ch)
        )
    }

    // --- Tool versions (independent of the data DAG above) ------------------
    versions_ch = SAMTOOLS_VERSION().version
        .mix(QC_VERSIONS().versions)
        .mix(DORADO_VERSION().version)
        .mix(VERKKO_VERSION().version)
        .flatten()
        .collect()
    SOFTWARE_VERSIONS(versions_ch)
}
