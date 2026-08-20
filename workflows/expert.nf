// EXPERT workflow
// samtools (BAM -> FASTQ, filtered) -> QC (seqkit stats [+ NanoPlot]) -> Dorado correct (GPU,
// ULK only) -> Verkko assembly (Pore-C or Hi-C branch). Reads-type is inferred from which of
// params.porec_reads / params.hic_reads_1+2 is set; main.nf has already validated that
// exactly one of those is populated before this workflow is invoked.

include { BAM_TO_FASTQ   } from '../modules/local/bam_to_fastq.nf'
include { SEQKIT_STATS   } from '../modules/local/seqkit_stats.nf'
include { NANOPLOT       } from '../modules/local/nanoplot.nf'
include { DORADO_CORRECT } from '../modules/local/dorado_correct.nf'
include { VERKKO         } from '../modules/local/verkko.nf'

workflow EXPERT {

    // --- Step 1: BAM -> FASTQ (+ qs/length filtering) -----------------------
    ulk_input_ch = Channel.of([ 'ultralong', file(params.ulk_reads) ])
    ulk_out      = BAM_TO_FASTQ(ulk_input_ch)
    ulk_fastq    = ulk_out.fastq.map { label, fastq -> fastq }

    if (params.porec_reads) {
        porec_input_ch = Channel.of([ 'porec', file(params.porec_reads) ])
        porec_out       = BAM_TO_FASTQ(porec_input_ch)
        porec_fastq_ch  = porec_out.fastq.map { label, fastq -> fastq }
    }
    else {
        porec_fastq_ch = Channel.empty()
    }

    // --- Step 2: read summary / QC ------------------------------------------
    all_fastq_ch = ulk_fastq.mix(porec_fastq_ch).collect()
    SEQKIT_STATS(all_fastq_ch)

    if (params.run_nanoplot.toString().toLowerCase() == 'true') {
        NANOPLOT(ulk_fastq)
    }

    // --- Step 3: Dorado correct (ULK only, GPU) -----------------------------
    DORADO_CORRECT(ulk_fastq)

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
        VERKKO(
            ulk_fastq,
            DORADO_CORRECT.out.corrected,
            [],
            [ file(params.hic_reads_1), file(params.hic_reads_2) ]
        )
    }
}
