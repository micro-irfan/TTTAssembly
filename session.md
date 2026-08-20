# session.md — Claude Code kickoff prompt

You are implementing the **expert mode** of a modular Nextflow (DSL2) pipeline that wraps the
Oxford Nanopore `SQK-ULK114` telomere-to-telomere workflow: samtools → read QC → Dorado
correct → Verkko.

**Read `CLAUDE.md` in full before writing anything.** It is the source of truth: it has the
exact commands, the parameter table (§3), the file layout (§4), and a reference implementation
for every module (§5). This file tells you *what to do this session*; CLAUDE.md tells you *how*.

## Do this
Create these files, in this order. Implement them against the specs in CLAUDE.md §3–§5.

1. `modules/local/bam_to_fastq.nf`   — `BAM_TO_FASTQ` (reused for ULK and Pore-C)
2. `modules/local/seqkit_stats.nf`   — `SEQKIT_STATS`
3. `modules/local/nanoplot.nf`       — `NANOPLOT` (optional, gated by `--run_nanoplot`)
4. `modules/local/dorado_correct.nf` — `DORADO_CORRECT` (GPU)
5. `modules/local/verkko.nf`         — `VERKKO` (Pore-C and Hi-C branches)
6. `workflows/expert.nf`             — wire the four steps + Pore-C/Hi-C reads-type inference
7. `workflows/scalable.nf`           — STUB only: `error "scalable mode not yet implemented"`
8. `main.nf`                         — param validation (CLAUDE.md §3), `--mode` dispatch, `--help`
9. `README.md`                       — build + run commands (from CLAUDE.md §7–§8)

## Constraints (do not violate)
- **No testing.** No nf-test, no `test` profile, no CI, no stub data, no assertions.
- **Docker only.** Leave the Singularity profile commented as-is.
- **Do not modify** `nextflow.config` or any `docker/*/Dockerfile` — they are already written
  and correct. If something in them genuinely blocks the build, stop and note it here rather
  than editing silently.
- Local executor only. No Slurm/SGE/LSF.
- One process per module file, UPPER_SNAKE_CASE names, `container` + resources come from the
  config (via `withName:` selectors), not from the modules.
- Prefix every output file with `${params.sample}`; `publishDir mode: 'copy'` into `${params.output}`.

## Target dataflow (expert mode)
```
ulk.bam ──BAM_TO_FASTQ(ultralong)──► ulk.fastq ─┬─► SEQKIT_STATS ──► read_stats.tsv
                                                 ├─► NANOPLOT (opt) ─► html/plots
                                                 ├─► DORADO_CORRECT ─► corrected.fasta ─┐
                                                 └───────────────────────────────────► VERKKO ─► assembly.*.fasta
porec.bam ─BAM_TO_FASTQ(porec)─► porec.fastq ────────────────────────────────────────►  (Pore-C branch)
hic_R1/R2.fastq ─────────────────────────────────────────────────────────────────────►  (Hi-C branch)
```
- Only ULK goes through Dorado correct.
- Pore-C fastq feeds SEQKIT_STATS too; Hi-C fastqs are already FASTQ and skip BAM_TO_FASTQ.

## Decisions already made — implement these, don't re-litigate
1. `--filtering false` → drop the `-e` filter but still convert BAM→FASTQ (both ULK and Pore-C).
2. Reads type is **inferred**: `--porec_reads` set → Pore-C; both Hi-C files set → Hi-C.
   Neither, or both, → validation error.
3. QC = `seqkit stats -a -T` (always) + NanoPlot (optional). One `qc` image.
4. Dorado uses the single combined GPU command (`dorado correct -x <device> -t <cpus>`).
5. `--max_memory_gb` → Verkko `--local-memory`.

## Open questions — proceed with the default, leave a `// TODO(user):` comment, don't block
1. `--filtering false` semantics: implemented as "skip filter, still convert". The alternative
   is "ULK input is already FASTQ, pass through". Add a TODO where this is decided.
2. Pore-C filter thresholds currently equal ULK (qs≥10, len≥1000). If separate Pore-C
   thresholds are wanted later, that's a param addition — leave a TODO, don't add now.
3. Dorado correction model is fetched at runtime (needs internet) unless pre-baked/mounted.
   Add a commented `--model-path` hook in `dorado_correct.nf`.

## Done when
- All nine files exist and parse (`nextflow run main.nf --help` prints usage without error).
- `--mode scalable` fails fast with the not-implemented message.
- Expert mode validates inputs before launching any process and builds a complete DAG for
  both the Pore-C and Hi-C branches.
- No file under `nextflow.config` or `docker/` was changed.
