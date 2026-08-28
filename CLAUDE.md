# CLAUDE.md

Guidance for building the **ONT long-read T2T de novo assembly** Nextflow pipeline.
This file is the source of truth for the build. Read it fully before writing any code.

---

## 1. What we are building

A Nextflow (DSL2) pipeline that reproduces the Oxford Nanopore "expert telomere-to-telomere
(T2T)" downstream analysis workflow for `SQK-ULK114` ultra-long reads combined with Pore-C
or Hi-C data. Assembly is done with **Verkko**.

The pipeline is **modular by mode**, selected with `--mode`, sharing `main.nf`'s dispatch and
param validation:

- `expert`  → Verkko-based assembly (this document, §2–§9).
- `scalable` → hifiasm-based assembly — see §11.

### Scope / non-goals (read carefully)
- **No testing.** Do not add `nf-test`, a `test` profile, CI, stub-run data, or assertions.
  The user has explicitly asked to build without testing. GPU (Dorado) and multi-hundred-GB
  RAM (Verkko) steps cannot be run in a normal dev box anyway.
- Do not run the pipeline. Just produce correct, readable code.
- Two engines are supported: Singularity/Apptainer (`-profile singularity`, default; Docker
  support was removed — see `sessions/session.md`) and Conda/Mamba (`-profile conda`). `.sif`
  images are built from `singularity/*/*.def` into `images/` (gitignored local build
  artifacts); conda envs are built from `conda/*.yml` and cached by Nextflow automatically, no
  manual build step. Dorado has no conda package — under `-profile conda` it must already be on
  `PATH` (see README.md "Alternative: Conda").
- Keep it single-machine / local executor. No Slurm/SGE/LSF config (Verkko has its own grid
  support that is out of scope here).

---

## 2. Reference: the exact commands this pipeline wraps (expert mode)

These come from the ONT protocol PDF. Reproduce them faithfully.

**Step 1 — BAM → FASTQ conversion + quality/length filtering**
```bash
# ULK (ultra-long) reads — qscore + length floor, this is what "ultra-long" means
samtools view -u -e '[qs]>=10 && length(seq)>=10000' <input_ulk.bam>   | samtools fastq > ultralongreads.fastq
# Pore-C reads — length-only, no qscore floor
samtools view -u -e 'length(seq)>=500' <input_porec.bam> | samtools fastq > porec.fastq
```
- When `--filtering false`, drop the `-e '...'` expression and do a plain conversion
  (`samtools fastq <in.bam> > out.fastq`). See §5 for the exact rule.
- Length thresholds differ by read type: `--min_len_ulk` (default `10000`) vs `--min_len_porec`
  (default `500`). `--min_qs` (default `10`) applies to **ULK only** — Pore-C has no qscore
  filter, length-only. See §3.
- Thread both `samtools view` and `samtools fastq` with `-@ ${task.cpus}`.
- Hi-C reads are **already FASTQ** (`--hic_reads_1/2`); they are **not** converted here.

**Step 2 — Read summary / QC statistics** (our addition; see §6 for tool choice)
```bash
# one report per read source, not one combined file — see SEQKIT_STATS in §5
seqkit stats -a -T -j <threads> ultralongreads.fastq > ultralong.read_stats.tsv
seqkit stats -a -T -j <threads> porec.fastq           > porec.read_stats.tsv
seqkit stats -a -T -j <threads> ultralongreads.doradocorrect.fasta > corrected.read_stats.tsv
# optional (--plot), richer QC on the ultra-long reads (N50 / length / quality plots)
NanoPlot --fastq ultralongreads.fastq -o nanoplot_ulk
```

**Step 3 — Dorado correct (ULK only, GPU)**
```bash
dorado correct -x cuda:0 ultralongreads.fastq > ultralongreads.doradocorrect.fasta
```

**Step 4 — Verkko assembly** (one branch runs, depending on Pore-C vs Hi-C)
```bash
# Pore-C branch
verkko --nano ultralongreads.fastq --hifi ultralongreads.doradocorrect.fasta \
       --porec porec.fastq --no-correction --local-memory <max_mem_in_GB> -d verkko_output
# Hi-C branch
verkko --nano ultralongreads.fastq --hifi ultralongreads.doradocorrect.fasta \
       --hic1 hic_r1.fastq --hic2 hic_r2.fastq --no-correction --local-memory <max_mem_in_GB> -d verkko_output
```
Note the deliberate Verkko quirk: **uncorrected** reads go to `--nano`, **Dorado-corrected**
reads go to `--hifi`, and `--no-correction` tells Verkko not to re-correct them.

---

## 3. Parameters (define in `nextflow.config`, document in a `--help`)

| Param | Default | Meaning |
|---|---|---|
| `--mode` | `expert` | `expert` or `scalable`. Dispatches the workflow. |
| `--sample` | `sample` | Sample name; used to prefix all output filenames. |
| `--filtering` | `true` | `true` → apply the qs/length filter; `false` → plain BAM→FASTQ. Accept `true/false/True/False`. |
| `--ulk_reads` | `null` | Path to the ULK **BAM** (required in expert mode). Comma-separated list to merge multiple flowcells (typically 2-3 for ULK). |
| `--porec_reads` | `null` | Path to the Pore-C **BAM**. Mutually exclusive with the Hi-C pair. Comma-separated list supported. |
| `--hic_reads_1` | `null` | Path to Hi-C R1 **FASTQ**. Comma-separated list supported. |
| `--hic_reads_2` | `null` | Path to Hi-C R2 **FASTQ**. Comma-separated list supported; must match `--hic_reads_1`'s count. |
| `--output` | `results` | Output directory (publishDir target). |
| `--max_memory_gb` | `null` | Integer GB passed to Verkko `--local-memory`. Required in expert mode. |
| `--threads` | `8` | Default CPUs per process (maps to `task.cpus`). |
| `--dorado_device` | `cuda:0` | Device string for `dorado correct -x`. |
| `--dorado_path` | `null` | Override path to the `dorado` binary; defaults to `dorado` on `PATH`. Mainly for `-profile conda` (no dorado conda package). |
| `--min_qs` | `10` | Filter threshold, mean read qscore. **ULK only** — Pore-C has no qscore filter. |
| `--min_len_ulk` | `10000` | Filter threshold, ULK read length (bp). |
| `--min_len_porec` | `500` | Filter threshold, Pore-C read length (bp). Length-only (no qscore filter). |
| `--plot` | `false` | Also run NanoPlot in the QC step (seqkit stats always runs regardless). Opt-in. |

### Reads-type inference (do not add a separate flag)
- If `--porec_reads` is set → **Pore-C branch**.
- Else if `--hic_reads_1` **and** `--hic_reads_2` are set → **Hi-C branch**.
- Else → fail validation with a clear message.
- If both Pore-C and Hi-C are given → fail (ambiguous).

### Validation (expert mode)
Fail fast, before any process launches, if: `ulk_reads` missing; `max_memory_gb` missing;
neither Pore-C nor Hi-C provided; both provided; a Hi-C file provided without its pair;
`hic_reads_1`/`hic_reads_2` comma-separated lists have different lengths.

### Multi-flowcell inputs (comma-separated merge)
`--ulk_reads`, `--porec_reads`, `--hic_reads_1`, `--hic_reads_2` each accept a comma-separated
list of files (e.g. 2-3 ULK flowcells run separately). Rules:
- All entries in one list must be the **same file type** (all `.bam`, or all `.fastq`/`.fastq.gz`)
  — mixed types fail with a clear error before any process launches.
- `BAM_TO_FASTQ` (§5) does the merge itself — for BAM input it pipes `samtools merge` straight
  into the filter/convert step (`-o -` / stdin), so a multi-flowcell merge never touches an
  intermediate BAM on disk. Exactly one file skips `samtools merge` entirely.
- `--hic_reads_1` and `--hic_reads_2` lists must have matching lengths (validated in `main.nf`).
- See `BAM_TO_FASTQ` in §5 and the `splitReadsParam` helper in `workflows/expert.nf`. Nextflow
  DSL2 forbids invoking the same process twice in one workflow scope, so `BAM_TO_FASTQ` and
  `SEQKIT_STATS` are each imported once per read source with `include { X as X_LABEL }` (e.g.
  `BAM_TO_FASTQ_ULK`, `BAM_TO_FASTQ_POREC`, `BAM_TO_FASTQ_HIC_R1`, `BAM_TO_FASTQ_HIC_R2`) rather
  than called multiple times under one name.
- `BAM_TO_FASTQ` fails the task (`exit 1`) if its output FASTQ ends up empty — a too-strict
  filter or an empty/corrupt input source stops the pipeline immediately (`errorStrategy =
  'terminate'`) instead of silently reaching Dorado/Verkko with no reads.

---

## 4. File layout to create

```
ont-t2t-assembly/
├── CLAUDE.md                     # this file
├── session.md                    # working state / checklist / open questions
├── main.nf                       # entry: param validation + mode dispatch
├── nextflow.config               # params, singularity profile, per-process resources (ALREADY WRITTEN)
├── modules/
│   └── local/
│       ├── common.nf             # BAM_TO_FASTQ + PREPARE_LONGREADS (samtools-based read merge/convert)
│       ├── raw_qc.nf             # SEQKIT_STATS + NANOPLOT (NANOPLOT gated by --plot) — raw-reads QC,
│       │                         # distinct from assembly QC (see §10); reused by scalable mode too
│       ├── dorado_correct.nf     # DORADO_CORRECT (GPU, expert mode only)
│       ├── verkko.nf             # VERKKO (porec + hic handled with optional inputs, expert mode)
│       ├── yak_count.nf          # YAK_COUNT (scalable mode, trio phasing only) — see §11
│       ├── hifiasm.nf            # HIFIASM + GFA_TO_FASTA (scalable mode) — see §11
│       ├── tool_versions.nf      # SAMTOOLS_VERSION + QC_VERSIONS + DORADO_VERSION + VERKKO_VERSION
│       └── software_versions.nf  # SOFTWARE_VERSIONS — combines the above into one JSON
├── workflows/
│   ├── expert.nf                 # expert mode (Verkko)
│   └── scalable.nf               # scalable mode (hifiasm) — see §11
├── singularity/                  # .def recipes (ALREADY WRITTEN — one per tool)
│   ├── samtools/samtools.def
│   ├── dorado/dorado.def
│   ├── verkko/verkko.def
│   ├── hifiasm/hifiasm.def       # scalable mode
│   ├── yak/yak.def               # scalable mode, trio phasing only
│   └── qc/qc.def                 # seqkit + NanoPlot for the summary step
├── conda/                        # env YAMLs for -profile conda (no Dorado — no conda package)
│   ├── samtools.yml
│   ├── qc.yml
│   ├── verkko.yml
│   ├── hifiasm.yml               # scalable mode
│   └── yak.yml                   # scalable mode, trio phasing only
└── images/                       # built .sif files (gitignored — not checked in)
```

`nextflow.config` and all `singularity/*/*.def` files already exist — **do not rewrite them**,
just implement the `.nf` files against them.

---

## 5. Module specs (reference implementations)

Use DSL2, `tag "${params.sample}"`, and a `label` (see below), and `publishDir` into
`params.output`. Containers/conda envs are assigned in `nextflow.config` via `withLabel:`
selectors, keyed off each process's `label` directive — do not hard-code `container`/`conda` in
the modules unless a selector is missing. Using labels rather than `withName:` means the config
doesn't need updating when a process gets a new `include { X as Y }` alias in a workflow (see
`BAM_TO_FASTQ_ULK`/`_POREC` etc. in §3's multi-flowcell note) — the label travels with the
process definition regardless of what it's invoked as. Labels in use: `samtools`, `qc`,
`dorado`, `verkko` (one per container/conda env — see §7), plus `gpu` (adds `--nv`; only
`DORADO_CORRECT`) and `quick` (cuts cpus/memory for the five tiny version-capture processes).
Related processes that share a label are grouped into one file (`common.nf`, `raw_qc.nf`,
`tool_versions.nf`) rather than one-process-per-file.

### `common.nf` — samtools-based read merge + filter/convert

#### `BAM_TO_FASTQ` (modules/local/common.nf)
One process handles merge (multi-flowcell), BAM→FASTQ conversion, and the qs/length filter —
merge and filter/convert used to be two processes (`MERGE_READS` → `BAM_TO_FASTQ`), which meant
a multi-flowcell merge wrote a full intermediate BAM to disk before `BAM_TO_FASTQ` read it back
in. Now `samtools merge` streams straight into `samtools view`/`samtools fastq` via a pipe
(`-o -` / stdin) — no intermediate file, for any number of input BAMs.

Reused for ULK, Pore-C, and Hi-C R1/R2 — imported as `BAM_TO_FASTQ_ULK` / `BAM_TO_FASTQ_POREC` /
`BAM_TO_FASTQ_HIC_R1` / `BAM_TO_FASTQ_HIC_R2` in `expert.nf` (see the multi-flowcell note in
§3). A `label` string drives the output name, the length threshold for BAM input
(`--min_len_ulk` vs `--min_len_porec`), and whether the qscore filter applies (ULK: qscore +
length; Pore-C: length-only, no `--min_qs`). Hi-C reads are already FASTQ, so they only ever
take the merge-only path — filtering never applies to non-BAM input. The caller
(`splitReadsParam()` in `workflows/expert.nf`) determines `ext` (`'bam'` | `'fastq'` |
`'fastq.gz'`) from the file extensions, validated uniform across one source's file list, before
this process is called.

```groovy
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
    def multi  = (reads instanceof List) && reads.size() > 1
    def min_len     = (label == 'ultralong') ? params.min_len_ulk : params.min_len_porec
    def filter_expr = (label == 'ultralong')
        ? "[qs]>=${params.min_qs} && length(seq)>=${min_len}"
        : "length(seq)>=${min_len}"
    def do_filter = params.filtering.toString().toLowerCase() == 'true'
    // Piped stages run concurrently — split task.cpus across however many are active in this
    // branch (min 1 each) instead of giving every stage the full task.cpus.
    def n_stages = is_bam ? ((multi && do_filter) ? 3 : (multi || do_filter) ? 2 : 1) : 1
    def cpus     = Math.max(task.cpus.intdiv(n_stages) as int, 1)
    def merge_cmd = "samtools merge -u -@ ${cpus} -o - ${reads}"

    def cmd
    if (is_bam && multi && do_filter)
        cmd = "${merge_cmd} | samtools view -u -@ ${cpus} -e '${filter_expr}' - | samtools fastq -@ ${cpus} - > ${out}"
    else if (is_bam && multi)
        cmd = "${merge_cmd} | samtools fastq -@ ${cpus} - > ${out}"
    else if (is_bam && do_filter)
        cmd = "samtools view -u -@ ${cpus} -e '${filter_expr}' ${reads} | samtools fastq -@ ${cpus} > ${out}"
    else if (is_bam)
        cmd = "samtools fastq -@ ${cpus} ${reads} > ${out}"
    else if (ext == 'fastq.gz')
        cmd = "zcat ${reads} > ${out}"       // zcat merges + decompresses N files in one pass
    else
        cmd = "cat ${reads} > ${out}"

    """
    ${cmd}

    [ -s ${out} ] || {
        echo "ERROR: ${out} is empty (label=${label})..." >&2
        exit 1
    }
    """
}
```
- The samtools filter expression contains no `$`, so single-quoting it inside the double-quoted
  Nextflow script block is safe.
- Needs samtools ≥ 1.16 for the `-e` expression grammar (`[qs]`, `length(seq)`). Our image is 1.23.1.
- Thread count ultimately comes from the `cpus` directive in `nextflow.config`
  (`params.threads`) — no hard-coded thread count in the module. But since pipe stages run
  concurrently, `-@ task.cpus` on every stage would ask for up to 3x what Nextflow scheduled
  for the task (merge | view | fastq); `cpus` (`task.cpus` split evenly across the branch's
  active stage count, min 1) is used for every `-@` instead.
- A single input file (`!multi`) skips `samtools merge` entirely — no point re-muxing one BAM.
- `[ -s ${out} ]` (POSIX `test -s`: exists and non-empty) fails the task with a clear message
  if filtering/conversion produces an empty FASTQ, instead of letting an empty read set reach
  Dorado/Verkko silently. `errorStrategy = 'terminate'` (set in `nextflow.config`) stops the
  whole run as soon as this — or any — task fails.

### `raw_qc.nf` — raw-reads summary / QC

#### `SEQKIT_STATS` (modules/local/raw_qc.nf)
Imported once per read source in `expert.nf` — `SEQKIT_STATS_ULK`, `SEQKIT_STATS_POREC`,
`SEQKIT_STATS_CORRECTED` (DSL2 forbids invoking the same process name twice in one workflow
scope; see the multi-flowcell note in §3) — so ULK, Pore-C (if present), and the
Dorado-corrected reads each get their own report rather than one combined file. `label`
("ultralong" / "porec" / "corrected") drives the output filename, same pattern as `BAM_TO_FASTQ`.
```groovy
process SEQKIT_STATS {
    tag "${params.sample}:${label}"
    label 'qc'
    publishDir "${params.output}/qc", mode: 'copy'
    input:  tuple val(label), path(fastqs)
    output: tuple val(label), path("${params.sample}.${label}.read_stats.tsv"), emit: stats
    script: "seqkit stats -a -T -j ${task.cpus} ${fastqs} > ${params.sample}.${label}.read_stats.tsv"
}
```
- `-j ${task.cpus}` threads seqkit the same way `-@ ${task.cpus}` threads samtools — comes from
  the `cpus` directive in `nextflow.config`, not hard-coded.

#### `NANOPLOT` (modules/local/raw_qc.nf)
Run on the ultra-long FASTQ only (that's where read-length/N50 matters for this workflow).
Only invoked when `--plot` is set (opt-in; see §3) — `SEQKIT_STATS` always runs regardless.
```groovy
process NANOPLOT {
    tag "${params.sample}"
    label 'qc'
    publishDir "${params.output}/qc", mode: 'copy'
    input:  path ulk_fastq
    output: path "nanoplot_${params.sample}/**", emit: report
    script: "NanoPlot --fastq ${ulk_fastq} -t ${task.cpus} -o nanoplot_${params.sample}"
}
```

### `DORADO_CORRECT` (modules/local/dorado_correct.nf) — GPU
```groovy
process DORADO_CORRECT {
    tag "${params.sample}"
    label 'dorado'
    label 'gpu'
    publishDir "${params.output}/corrected", mode: 'copy'
    input:  path ulk_fastq
    output: path "${params.sample}.doradocorrect.fasta", emit: corrected
    script:
    def dorado_bin = params.dorado_path ?: 'dorado'
    """
    command -v ${dorado_bin} >/dev/null 2>&1 || {
        echo "ERROR: dorado is not installed (or not on PATH): '${dorado_bin}' not found. Install dorado or pass --dorado_path /path/to/dorado — see README.md 'Alternative: Conda'." >&2
        exit 1
    }
    ${dorado_bin} correct -x ${params.dorado_device} -t ${task.cpus} ${ulk_fastq} > ${params.sample}.doradocorrect.fasta
    """
}
```
- GPU is enabled by `containerOptions '--nv'`, added via the `gpu` label in the config
  (`withLabel: 'gpu'`) — `DORADO_CORRECT` is the only process with this label.
- `dorado correct` downloads its correction model on first run (needs internet) unless it's
  pre-baked or a model cache volume is mounted. See the dorado `.def` comment. Leave a
  commented `--model-path` hook in the process for when a cached model is mounted.
- `--dorado_path` overrides which `dorado` binary runs (default: plain `dorado`, resolved via
  `PATH`) — mainly for `-profile conda`, which has no dorado conda package (see §7). The
  `command -v` guard fails fast with a clear message instead of a raw shell "command not found"
  when dorado isn't installed/isn't on `PATH`. `DORADO_VERSION` (`modules/local/tool_versions.nf`)
  uses the same override + guard.

### `VERKKO` (modules/local/verkko.nf)
Handle both branches with optional inputs. Pass empty file lists for the branch that isn't used.
Runs in a **stable directory under `${params.output}`**, not the ephemeral per-task work dir —
see the note below.
```groovy
def VERKKO_DIR = "${file(params.output).toAbsolutePath()}/${params.sample}/verkko"

process VERKKO {
    tag "${params.sample}"
    label 'verkko'
    // No publishDir — Verkko already writes directly into VERKKO_DIR, under ${params.output}.

    input:
    path nano_fastq          // uncorrected ULK
    path hifi_fasta          // dorado-corrected ULK
    path porec_fastq         // may be []
    tuple path(hic1), path(hic2)   // may be [ [], [] ]

    output:
    path "verkko_out/**",                        emit: assembly
    path "verkko_out/assembly.fasta",            emit: assembly_fasta
    path "verkko_out/assembly.haplotype1.fasta", emit: haplotype1_fasta
    path "verkko_out/assembly.haplotype2.fasta", emit: haplotype2_fasta

    script:
    def reads_arg = porec_fastq ? "--porec ${porec_fastq}" : "--hic1 ${hic1} --hic2 ${hic2}"
    """
    mkdir -p ${VERKKO_DIR}
    ln -sfn ${VERKKO_DIR} verkko_out
    verkko --nano ${nano_fastq} --hifi ${hifi_fasta} ${reads_arg} \
        --no-correction --local-memory ${params.max_memory_gb} --local-cpus ${task.cpus} \
        -d verkko_out
    """
}
```
- Prefer wiring two explicit calls (a Pore-C call and a Hi-C call) from `expert.nf` over
  branching inside one process if the optional-path handling gets awkward — either is fine,
  pick the cleaner one. The key outputs to expose are `assembly.fasta`,
  `assembly.haplotype1.fasta`, `assembly.haplotype2.fasta`.
- `--local-cpus` uses `task.cpus` directly. `withLabel: 'verkko'` sets `cpus = { params.threads
  }` — `--threads` is meant for the assembler itself, passed straight through uncapped. Every
  other process's `cpus` is capped at `Math.min(params.threads as int, 48)` instead, set inside
  that process's own `withLabel:` block — **not** as a bare `process { cpus = ... }` default.
  `nextflow.config`'s `process {}` scope deliberately carries no bare `cpus`/`memory` at all: one
  was found in practice to win over a matching `withLabel: 'x' { cpus = ... }` for the same
  process (confirmed twice with `HIFIASM` — `task.cpus` kept coming out as the bare default's
  value regardless of `--threads`, the reverse of Nextflow's documented generic-lowest/
  `withLabel`-higher precedence; see `sessions/session.md`), so every label sets its own value
  directly instead of relying on that precedence. Separately, `executor.cpus = params.threads`
  raises the local executor's own cpu ceiling to `params.threads`, in case the host's
  auto-detected processor count is lower than that (Nextflow's local executor silently caps a
  task's `cpus` directive to its ceiling otherwise — this is JVM `Runtime.availableProcessors()`,
  which follows the launching process's own cgroup quota, not necessarily the full node). Must be
  the flat `executor.cpus` key, **not** nested as `executor { $local { cpus = ... } } }` — that
  form is silently ignored (`WARN: Unrecognized config option`); `$name` nesting is only valid
  for a handful of other executor options (queueSize, pollInterval, ...), not cpus/memory — see
  `sessions/session.md`. An earlier version doubled `cpus` to
  `params.threads * 2` to intentionally oversubscribe Verkko's internal thread pool — dropped
  (see `sessions/session.md`) once the underlying config-precedence bug made it clear that was
  never actually taking effect either.
- **`VERKKO_DIR` (stable output dir, not `publishDir`)**: Verkko manages its own Snakemake-based
  incremental state inside its `-d` directory. If a re-run changes `--threads`/
  `--max_memory_gb` (or anything else that changes this task's hash), Nextflow would normally
  start the retry in a brand-new, empty ephemeral work dir, discarding any progress Verkko had
  made. Pointing `-d` at a fixed absolute path under `${params.output}` instead means Verkko
  finds its own prior state there and resumes internally regardless of what Nextflow's own
  work-dir hashing/`-resume` decides. `VERKKO_DIR` itself must be an **absolute** path — the
  script block's CWD is still the task's ephemeral work dir, so a bare `${params.output}/...`
  would resolve inside that instead of the intended stable location; `file(params.output).
  toAbsolutePath()` resolves it against the launch directory (the same semantics
  `params.output` already has via `publishDir` elsewhere in this pipeline) before the path gets
  locked in. Consequence: the published layout is `${params.output}/${params.sample}/verkko/...`,
  not the old flat `${params.output}/verkko_output/...` — mirrors how scalable mode already
  publishes hifiasm's output under `${params.output}/${params.sample}/`.
- **`output: path` can't target `VERKKO_DIR` directly** — Nextflow requires declared outputs to
  resolve inside the task's own ephemeral work directory; a raw absolute path outside it throws
  `IllegalFileException: File ... is outside the scope of the process work directory` (hit in
  practice — see `sessions/session.md`). The fix: `ln -sfn ${VERKKO_DIR} verkko_out` inside the
  script, `-d verkko_out` (the relative symlink, not the absolute path) as Verkko's own argument,
  and `output: path "verkko_out/**"` etc. as the declarations. Verkko writes through the symlink
  to the same persistent `VERKKO_DIR` target either way (its resume logic operates on the
  resolved files, not the path label used to reach them), while Nextflow sees an ordinary
  work-dir-local entry to stage as this task's output.
- Since the process now writes directly to its final location, `publishDir` was removed for
  `VERKKO` — there is nothing left to copy. Running the same `--sample`/`--output` combination
  concurrently (two overlapping `nextflow run` invocations) would now collide on the same
  `VERKKO_DIR`; not a new pipeline-level guard, same as any other shared-output-path scenario.

### Tool versions (modules/local/tool_versions.nf + software_versions.nf)
One tiny version-capture process per label already used elsewhere in the pipeline (so it reuses
the matching container/conda env, and the reported version is guaranteed to match what actually
ran), plus a combiner. Each carries its tool's label **and** `quick` (cuts cpus/memory — see
§7/`nextflow.config`). All have no pipeline inputs — they run `<tool> --version` once per
invocation:

- `SAMTOOLS_VERSION` — `label 'samtools'; label 'quick'` (same env as `BAM_TO_FASTQ`)
- `QC_VERSIONS` — `label 'qc'; label 'quick'`; captures both seqkit and NanoPlot in one process
  (same env as `SEQKIT_STATS`/`NANOPLOT`)
- `DORADO_VERSION` — `label 'dorado'; label 'quick'`, deliberately **without** `label 'gpu'`: a
  version check doesn't need GPU hardware
- `VERKKO_VERSION` — `label 'verkko'; label 'quick'`

Each writes `<tool>.version.txt` containing the raw first line of `<tool> --version` output
(formats vary by tool — not reparsed/normalized further; see the module files if a
specific tool's format needs stripping down to a bare version number).

`SOFTWARE_VERSIONS` (`label 'qc'; label 'quick'`) collects all `*.version.txt` files
(`workflows/expert.nf` mixes + flattens the four channels above) plus `workflow.nextflow.version`
and `workflow.manifest.version`, and writes `${params.sample}.software_versions.json` to
`${params.output}/`. Runs in the qc env (already has python3 via miniforge) — no new image.

---

## 6. QC tool choice (step 2)

The doc stresses read **N50 ≥ 60 kb** as the driver of assembly quality, so the summary step
should surface N50 and the read-length distribution:

- **seqkit stats -a** — fast, always run. Tabular: num_seqs, sum_len, min/avg/max, **N50**,
  Q20(%), Q30(%). One TSV per read source (ULK, Pore-C, Dorado-corrected) — see `SEQKIT_STATS`
  in §5 — not one combined file, so pre- vs post-correction stats are easy to diff.
- **NanoPlot** — ONT-native, opt-in (`--plot`, default off). Adds read-length and quality plots
  and an HTML report for the ultra-long reads.

Both live in the single `qc` image. `NanoComp` is a reasonable alternative if the user later
wants to compare ULK vs Pore-C side by side — not needed now.

---

## 7. Containers and Conda envs (already written under `singularity/` and `conda/`)

Two mutually-exclusive engines, selected with `-profile singularity` (default) or `-profile
conda`. `nextflow.config` assigns these by `withLabel:` (see §5) rather than `withName:`, so it
doesn't matter that `BAM_TO_FASTQ` and `SEQKIT_STATS` are each imported under several aliases in
`workflows/expert.nf` (§3's multi-flowcell note) — the label lives on the
process definition, not the alias.

| Process | Singularity image | Conda env | Base / install |
|---|---|---|---|
| `BAM_TO_FASTQ`, `PREPARE_LONGREADS`, `GFA_TO_FASTA`, `SAMTOOLS_VERSION` | `images/samtools.sif` | `conda/samtools.yml` | ubuntu, samtools built from source / bioconda |
| `SEQKIT_STATS`, `NANOPLOT`, `QC_VERSIONS`, `SOFTWARE_VERSIONS` | `images/qc.sif` | `conda/qc.yml` | miniforge, `seqkit` + `nanoplot`, both bioconda |
| `DORADO_CORRECT`, `DORADO_VERSION` | `images/dorado.sif` | *(none — see below)* | `nvidia/cuda` runtime + Dorado CDN binary |
| `VERKKO`, `VERKKO_VERSION` | `images/verkko.sif` | `conda/verkko.yml` | miniforge, `verkko` from bioconda |
| `HIFIASM` (scalable mode) | `images/hifiasm.sif` | `conda/hifiasm.yml` | ubuntu, hifiasm built from source / bioconda |
| `YAK_COUNT` (scalable mode, trio only) | `images/yak.sif` | `conda/yak.yml` | ubuntu, yak built from source / bioconda |

Build all Singularity images:
```bash
singularity build images/samtools.sif singularity/samtools/samtools.def
singularity build images/dorado.sif   singularity/dorado/dorado.def
singularity build images/verkko.sif   singularity/verkko/verkko.def
singularity build images/hifiasm.sif  singularity/hifiasm/hifiasm.def
singularity build images/yak.sif      singularity/yak/yak.def
singularity build images/qc.sif       singularity/qc/qc.def
```
GPU note: the host needs the NVIDIA driver; the Dorado process requests the GPU via `--nv`
(set in config). Verify with `singularity exec --nv images/dorado.sif dorado --version`.

**Conda**: no build step — Nextflow creates and caches each `conda/*.yml` env automatically on
first run under `-profile conda`. **Dorado has no conda/bioconda package**: `DORADO_CORRECT`
and `DORADO_VERSION` get no `conda` directive in `nextflow.config` and just run against
whatever `dorado` binary is already on `PATH` under this profile — install ONT's binary
manually (same version/URL as `singularity/dorado/dorado.def`); see README.md "Alternative:
Conda" for the exact commands.

---

## 8. Run examples (for the README / --help text)

```bash
# Pore-C, expert mode
nextflow run main.nf -profile singularity \
  --mode expert --sample HG002 \
  --ulk_reads ulk.bam --porec_reads porec.bam \
  --max_memory_gb 480 --output results

# Hi-C, no pre-filtering
nextflow run main.nf -profile singularity \
  --mode expert --sample HG002 --filtering false \
  --ulk_reads ulk.bam --hic_reads_1 hic_R1.fastq --hic_reads_2 hic_R2.fastq \
  --max_memory_gb 480 --output results
```

---

## 9. Conventions

- Nextflow DSL2, `nextflow.enable.dsl=2`.
- UPPER_SNAKE_CASE process names. Every process carries a `label` (see §5) — `nextflow.config`
  assigns containers/conda envs/resources by `withLabel:`, not `withName:`, so config wiring
  survives a process being aliased (`include { X as Y }`) at however many call sites a workflow
  needs. Group related processes that share a label into one module file (e.g. `common.nf`,
  `raw_qc.nf`, `tool_versions.nf`) rather than one-process-per-file — the filename is irrelevant to
  config wiring either way.
- No hard-coded resources in modules — resources and `container`/`conda` come from
  `nextflow.config`.
- `publishDir mode: 'copy'`.
- Prefix every output file with `${params.sample}`.
- Keep the Verkko quirk comment (nano=uncorrected, hifi=corrected) in `verkko.nf`.
- `scalable.nf` is the hifiasm-based workflow (§11), not a stub — `main.nf` dispatches to it the
  same way it dispatches to `expert.nf`'s `EXPERT()`.
- Don't touch `nextflow.config` or the `singularity/*/*.def` files unless a bug blocks the
  build; if you do, note it in `session.md`.

---

## 10. Standalone assembly-QC workflow

A **separate** Nextflow (DSL2) workflow — `assembly_qc.nf` at the repo root — that QC's one or
more assembly FASTAs (contiguity, telomere-capping, gene completeness, k-mer QV/completeness).
Species-agnostic: takes assembly FASTA(s) directly rather than reading through the assembler, so
it works for bacteria, human, anything. It does **not** chain off the assembly pipeline above —
`main.nf`, `workflows/expert.nf`, and `workflows/scalable.nf` are untouched by this feature.
Full history/decisions/open questions: `sessions/session_assembly_qc.md`.

### Design
- Entry: `assembly_qc.nf` (repo root) — `--help`, fail-fast param validation, dispatches to the
  reusable `ASSEMBLY_QC` workflow (`workflows/assembly_qc.nf`, alongside `expert.nf`/
  `scalable.nf` — no separate `subworkflows/` directory). All 8 processes live in one module
  file, `modules/local/assembly_qc.nf`, grouped for fewer directories rather than by shared
  label (unlike `common.nf`/`raw_qc.nf`/`tool_versions.nf`, these 8 are 8 separate conda envs).
- Assembly list is built from what's provided: always `['combined', --assembly]`; adds
  `['h1', --assembly_H1]` / `['h2', --assembly_H2]` when given. A bacterial run is just
  `--assembly` with a bacterial `--compleasm_lineage`; a human run adds the haplotypes and the
  telomere/QV tools.
- Tools: **gfastats** (contiguity), **seqtk telo** (telomere-capped contigs), **compleasm**
  (gene completeness — supersedes BUSCO, not used here), **QUAST** (assembly evaluation),
  **Merqury** (k-mer QV/completeness), **Merfin** (read-aware QV*). Selected via `--tools`.

### Provisioning — conda only, for now
Each of the 8 processes in `modules/local/assembly_qc.nf` carries its own `label` (one per
tool — a distinct conda env per process, same one-label-per-env pattern as the main pipeline's
`samtools`/`qc`/`dorado`/`verkko` labels), assigned in `nextflow.config`'s
`profiles { conda { process { withLabel: ... } } } }`.
**No `container` directive exists for any of these yet** — `-profile singularity` is not
functional for this workflow until `.def` recipes are added and a matching
`profiles { singularity { process { withLabel: ... { container = ... } } } }` block is wired up.
Env YAMLs live in the existing `conda/` directory (not a separate one) — `conda/gfastats.yml`,
`conda/seqtk.yml`, `conda/compleasm.yml`, `conda/quast.yml`, `conda/meryl.yml`,
`conda/merqury.yml`, `conda/genomescope2.yml`, `conda/merfin.yml`. One env per process — don't
merge tools into a shared env.

Using labels here (rather than hardcoding `conda`/`container` directly on each process, as an
earlier draft of this feature's kickoff doc proposed) means tuning cpus/memory per tool later is
a one-line `withLabel:` addition in `nextflow.config`, not a module edit.

### Parameters (`nextflow.config`; `--output`/`--sample` intentionally NOT redeclared there — see below)
| Param | Default | Meaning |
|---|---|---|
| `--assembly` | `null` | **Required.** Primary/combined assembly FASTA. |
| `--assembly_H1` | `null` | Optional haplotype 1 FASTA. |
| `--assembly_H2` | `null` | Optional haplotype 2 FASTA. |
| `--tools` | `gfastats,seqtk,compleasm` | Comma-separated subset of `{gfastats,seqtk,compleasm,quast,merqury,merfin}`, or `none`. |
| `--output` | `assembly_qc`* | Output directory. |
| `--sample` | `assembly`* | Output prefix. |
| `--genome_size` | `3100000000` | Haploid expected size (bp) — gfastats NGx, QUAST `--est-ref-size`, GenomeScope2. |
| `--ploidy` | `2` | 1 = bacteria/haploid, 2 = diploid — GenomeScope2/Merfin. |
| `--reads` | `null` | Reads for the meryl k-mer DB (quoted glob). **Required if `--tools` includes `merqury` or `merfin`.** Prefer accurate reads (Illumina/HiFi). |
| `--meryl_k` | `21` | k-mer size for meryl/Merqury/Merfin. |
| `--merfin_peak` | `null` | Homozygous k-mer coverage peak for Merfin. **Required if `--tools` includes `merfin`** (auto-derivation from GenomeScope2 output is not implemented — see Open questions). |
| `--compleasm_lineage` | `primates` | e.g. `primates`, `mammalia`, `bacteria`, `eukaryota`. |
| `--compleasm_downloads` | `null` | Optional pre-downloaded lineage dir (`-L`); enables offline compleasm. |
| `--quast_reference` | `null` | Optional reference FASTA for reference-based QUAST. Default = reference-free. |
| `--quast_large` | `null` | `true`/`false` to force QUAST `--large`. If unset, auto-enables when `genome_size > 100 Mb`. |

\* `--output`/`--sample` are **not** declared in `nextflow.config`'s params (that file is shared
with `main.nf`; a second default for the same key there would silently win for both entry
scripts — Nextflow evaluates every `params{}` block in the file regardless of which script you
run). Instead `assembly_qc.nf` applies `'assembly_qc'`/`'assembly'` itself, but only when the
value is still exactly the inherited main-pipeline default (`'results'`/`'sample'`) — i.e. only
when the user didn't pass `--output`/`--sample` explicitly.

### `--tools` parsing rules
- Split on commas, trim, lowercase. Every token must be in
  `{gfastats,seqtk,compleasm,quast,merqury,merfin}` — else fail listing the bad token(s).
- `none` or empty → run nothing, don't error.
- `merqury` or `merfin` without `--reads` → fail. `merfin` without `--merfin_peak` → fail.
- All validated fail-fast in `assembly_qc.nf`, before any process launches.

### Which assemblies each tool runs on
- `gfastats`, `seqtk`, `compleasm`, `merfin`: **per assembly** in the list (1–3 of
  combined/h1/h2). Nextflow DSL2 forbids invoking the same process more than once in one
  workflow scope (see §3's multi-flowcell note for where the main pipeline hit this) — so each
  of these is called **once** in `workflows/assembly_qc.nf`, fed a single channel of
  `(label, fasta[, size])` tuples covering every assembly; Nextflow fans that out into one task
  per item automatically, rather than looping and calling the process per assembly.
- `quast`: **one run** over all provided assemblies together.
- `merqury`: diploid mode (`merqury.sh db h1 h2 out`) when H1 & H2 are both provided, else
  single mode against the combined assembly.
- `meryl_count` (shared upstream, built once): runs if `merqury` or `merfin` is requested.
  `genomescope2`: runs only if `merfin` is requested (Merfin needs its lookup table).

### Tool command references
```bash
# gfastats — size(combined) = 2*genome_size iff both haplotypes provided, else genome_size;
# size(hap) = genome_size always
gfastats ${fasta} ${expected_size} > ${prefix}.gfastats

# seqtk telo — keep intermediates AND the both-ends-capped contig count
seqtk telo ${fasta} > ${prefix}.telo.bed 2> ${prefix}.telo.count
both_ends=$(cut -f1 ${prefix}.telo.bed | sort | uniq -d | wc -l)

# compleasm
compleasm run -a ${fasta} -o compleasm_${label} -l ${params.compleasm_lineage} -t ${task.cpus} \
    ${params.compleasm_downloads ? "-L ${params.compleasm_downloads}" : ""}

# QUAST — one run, all assemblies; --large auto by genome size unless --quast_large forces it
quast.py -t ${task.cpus} -o quast --est-ref-size ${params.genome_size} \
    ${large ? "--large" : ""} ${params.quast_reference ? "-r ${params.quast_reference}" : ""} \
    ${all_assembly_fastas}

# Merqury (MERYL_COUNT builds the shared DB first)
meryl count k=${params.meryl_k} threads=${task.cpus} ${reads} output reads.meryl
meryl histogram reads.meryl > reads.hist
merqury.sh reads.meryl ${assemblies_for_merqury} ${params.sample}_merqury

# Merfin (GenomeScope2 first, for the -prob lookup table)
genomescope2 -i reads.hist -o genomescope -k ${params.meryl_k} -p ${params.ploidy} --fitted_hist
merfin -hist -sequence ${fasta} -readmers reads.meryl -prob genomescope/lookup_table.txt \
    -peak ${params.merfin_peak} -output ${prefix}.merfin
```

### Open questions (leave `// TODO(user):`, don't block)
1. **Merfin peak auto-derivation.** Parsing the homozygous coverage peak (`kmercov`) from
   GenomeScope2's output is brittle across versions — not implemented. `--merfin_peak` is
   required (fails fast if missing while `merfin` is requested) rather than attempting fragile
   parsing.
2. **Singularity container tags.** No `container` directives exist yet for any of the 8 tools —
   deferred until `.def` recipes are added for the ones worth containerizing.
3. **QV read source quality.** Merqury/Merfin QV is only as good as `--reads`; ONT-corrected
   reads under-report QV vs Illumina/HiFi. Merfin's QV* partly compensates.
4. **`meryl_k` for small genomes.** k=21 suits large genomes; bacteria may want smaller.

### Testing
nf-test scaffolding (TODO fixtures, same style as the main pipeline's `tests/`) exists for
`GFASTATS`, `COMPLEASM`, `SEQTK_TELO` only — not the read-dependent/shared tools. Conda-only, so
run with an explicit profile override rather than the shared `nf-test.config` default (that
default is the main pipeline's singularity-based `test` profile):
```bash
nf-test test --profile conda tests/modules/local/{gfastats,compleasm,seqtk_telo}.nf.test
```

---

## 11. Scalable mode (hifiasm)

`--mode scalable` (dispatched from the same `main.nf` as `--mode expert`, §1) assembles ONT
long reads with **hifiasm `--ont`** instead of Verkko/Dorado — ONT's "scalable (near) T2T"
method (`SQK-LSK114`). No Dorado correction step: hifiasm reads uncorrected ONT reads directly.
Full history/decisions/open questions: `sessions/session_scalable.md`.

### Sub-modes (auto-selected from which inputs are given)
- **default (dual)** — long reads only → collapsed + two dual (partially-phased) haplotypes.
- **Hi-C** — long reads + `--hic_reads_1`/`--hic_reads_2` → collapsed + two Hi-C-phased
  haplotypes. Shares the Hi-C params with expert mode.
- **trio** — long reads + `--pat_reads`/`--mat_reads` (via yak) → collapsed + two trio-phased
  haplotypes.

Selection priority (in `workflows/scalable.nf`): trio > Hi-C > default. `main.nf` validates
before any process launches: `--long_reads` required; `--mat_reads`/`--pat_reads` both-or-neither;
`--hic_reads_1`/`--hic_reads_2` both-or-neither; trio and Hi-C inputs can't both be set.

### Data requirements (from ONT)
- Long reads ~40–45x, N50 ~30 kb (works down to ~30x / N50 10 kb with reduced contiguity).
- Hi-C 20–30x, OR parental (long/short read) 20–30x **per parent**.
- Compute: ≥300 GB RAM; ~1,000–3,000 CPU-hours (+500–1,000 with Hi-C).
- Tools: Samtools, Hifiasm ≥ v0.25.0, Awk, Yak ≥ v0.1 (trio only).

### Provisioning — both engines, singularity default
Same as expert mode: `-profile singularity` (default) or `-profile conda`. `HIFIASM`
(`label 'hifiasm'`) and `YAK_COUNT` (`label 'yak'`, trio only) each get a container mapping
(`images/hifiasm.sif`, `images/yak.sif`) and a conda env (`conda/hifiasm.yml`, `conda/yak.yml`).
`PREPARE_LONGREADS` and `GFA_TO_FASTA` (`label 'samtools'`) reuse the existing samtools
image/env — no new container needed for either.

### Parameters
`--mode`, `--sample`, `--output`, `--threads`, `--hic_reads_1`, `--hic_reads_2` are shared with
expert mode (§3). `--max_memory_gb` and `--filtering` (expert-only) are ignored in scalable
mode. New:

| Param | Default | Meaning |
|---|---|---|
| `--long_reads` | `null` | **Required.** ONT long reads: `.bam`, `.fastq`, or `.fastq.gz`. Comma-separated list merges multiple flowcells (same mechanism as `--ulk_reads`, §3). |
| `--mat_reads` | `null` | Maternal reads for trio phasing (via yak). Single file only (no comma-separated merge). |
| `--pat_reads` | `null` | Paternal reads for trio phasing (via yak). Single file only. |
| `--telo_motif` | `CCCTAA` | Telomere motif for `hifiasm --telo-m` (human/vertebrate default; change per species). |

### `workflows/scalable.nf` steps
1. Sub-mode selection (trio > Hi-C > default).
2. `PREPARE_LONGREADS` normalizes `--long_reads` to plain FASTQ (merge multi-flowcell +
   BAM→FASTQ, no filtering — hifiasm handles uncorrected reads directly). In trio mode,
   `--pat_reads`/`--mat_reads` are **also** routed through `PREPARE_LONGREADS` uniformly
   (handles BAM or FASTQ/FASTQ.GZ either way), not just when they happen to be BAM.
3. **Pre-assembly QC — reused from expert mode, not a new module**: `SEQKIT_STATS` on the
   normalized long reads (always), `NANOPLOT` when `--plot` is set — the exact same processes
   `workflows/expert.nf` uses, from `modules/local/raw_qc.nf`.
4. Trio mode only: `YAK_COUNT` on each normalized parent's reads.
5. `HIFIASM` → `GFA_TO_FASTA`.

`PREPARE_LONGREADS` is called for up to 3 sources in one run (long reads always, pat/mat in
trio mode) and `YAK_COUNT` for 2 (pat+mat together) — DSL2 forbids invoking the same process
more than once in one workflow scope (§3's multi-flowcell note is where the main pipeline first
hit this), so each is imported under a distinct alias per call site
(`PREPARE_LONGREADS_LONGREADS`/`_PAT`/`_MAT`, `YAK_COUNT_PAT`/`_MAT`), same pattern as
`BAM_TO_FASTQ_ULK`/`_POREC`/etc. in `workflows/expert.nf`. `HIFIASM` and `GFA_TO_FASTA` need no
aliasing — each has exactly one call site (`GFA_TO_FASTA` is fed a flattened 3-item GFA channel
from one call, fanned out automatically, not looped).

### Tool command references
```bash
# PREPARE_LONGREADS — normalize to plain FASTQ, no filtering
samtools fastq -@ ${task.cpus} ${reads} > longreads.fastq          # .bam
zcat ${reads} > longreads.fastq                                    # .fastq.gz (merges N files)
cat ${reads} > longreads.fastq                                     # .fastq

# YAK_COUNT (trio only) — one call per parent
yak count -b37 -t ${task.cpus} -o ${label}.yak ${reads}

# HIFIASM — -t is task.cpus, itself params.threads directly (see below); -o points through a
# work-dir-local symlink at HIFIASM_DIR, a stable path, not the ephemeral task work dir directly
# (see below). hifiasm has no --threads long option, only -t (checked against its ketopt
# long_options table).
ln -sfn ${HIFIASM_DIR} hifiasm_out
hifiasm --ont -t ${task.cpus} --telo-m ${params.telo_motif} --dual-scaf \
    -o hifiasm_out/hifiasmONT_asm <MODE_ARGS> longreads.fastq
# MODE_ARGS: default = (empty) | Hi-C = --h1 ${hic1} --h2 ${hic2} | trio = -1 pat.yak -2 mat.yak

# GFA_TO_FASTA — per p_ctg GFA (collapsed + hap1 + hap2)
awk '/^S/{print ">" $2 "\n" $3}' ${gfa} > ${gfa.baseName}.fasta
```

Outputs (infix differs by sub-mode — `bp` default, `hic` Hi-C, `dip` trio), each emitting a
collapsed `p_ctg` plus `hap1`/`hap2` `p_ctg`: e.g. `hifiasmONT_asm.bp.p_ctg.gfa`,
`hifiasmONT_asm.bp.hap1.p_ctg.gfa`, `hifiasmONT_asm.bp.hap2.p_ctg.gfa`. `HIFIASM`'s `gfas`
output matches `hifiasmONT_asm.*.p_ctg.gfa` regardless of sub-mode, so `GFA_TO_FASTA` doesn't
need to know which sub-mode ran.

hifiasm's `-t` uses `task.cpus` directly. `withLabel: 'hifiasm'` sets `cpus = { params.threads
}`, same as `VERKKO` (§5) — `--threads` is meant for the assembler itself, passed straight
through uncapped, while every other process is capped at `Math.min(params.threads as int, 48)`
inside its own `withLabel:` block. See §5's `VERKKO` note and `sessions/session.md` for why
`nextflow.config`'s `process {}` scope carries no bare `cpus`/`memory` default (a bare value was
found to win over a matching `withLabel` override in practice) and why the flat
`executor.cpus = params.threads` ceiling-raise exists alongside it (not the `$local`-nested
form, which Nextflow silently ignores).

**`HIFIASM_DIR` (stable output dir, not `publishDir`)** — same pattern as `VERKKO_DIR` (§5):
`def HIFIASM_DIR = "${file(params.output).toAbsolutePath()}/${params.sample}/hifiasm"` at the
top of `modules/local/hifiasm.nf`, shared by both `HIFIASM` and `GFA_TO_FASTA` (the latter's
`publishDir` points at it too, so the derived FASTAs land next to their source GFAs). hifiasm
caches its error-corrected reads and all-vs-all overlaps in binary checkpoint files
(`*.ec.bin`, `*.ovlp.reverse.bin`, `*.ovlp.source.bin`) next to its `-o` prefix, and on a
subsequent run with the same prefix it detects and reuses them instead of recomputing that
stage — conceptually the same problem `VERKKO_DIR` solves for Verkko's Snakemake state, just a
prefix-keyed checkpoint mechanism instead of a DAG. Without a stable prefix, a re-run that
changes `--threads` (or anything else that changes the task hash) would land in a fresh,
empty ephemeral work dir and lose those `.bin` files, forcing a full recompute. `HIFIASM` has
no `publishDir` — it writes through a symlink directly to `HIFIASM_DIR`.

`output: path` can't target `HIFIASM_DIR` directly, same restriction as `VERKKO_DIR` (§5):
Nextflow requires declared outputs to resolve inside the task's own ephemeral work directory: a
raw absolute path outside it throws `IllegalFileException: File ... is outside the scope of the
process work directory` (hit in practice — see `sessions/session.md`). The fix is the same
symlink trick as `VERKKO`: `ln -sfn ${HIFIASM_DIR} hifiasm_out` inside the script, `-o
hifiasm_out/hifiasmONT_asm` (the relative symlink, not the absolute path) as hifiasm's own
argument, and `output: path "hifiasm_out/hifiasmONT_asm*"` /
`path "hifiasm_out/hifiasmONT_asm.*.p_ctg.gfa"` as the declarations — hifiasm writes through the
symlink to the same persistent `HIFIASM_DIR` target either way (its checkpoint-reuse logic
operates on the resolved files, not the path label used to reach them). Same concurrent-run
caveat as `VERKKO_DIR`: overlapping `nextflow run` invocations for the same `--sample`/`--output`
collide on this directory.

### Open questions (leave `// TODO(user):`, don't block)
1. **`.gz` passthrough.** hifiasm accepts gzipped FASTQ directly; for a single-file `.fastq.gz`
   input (no merge needed), `PREPARE_LONGREADS`'s normalization could be skipped and the `.gz`
   fed straight to hifiasm, saving I/O. Not implemented — always normalizes to plain FASTQ.
2. **Paired-end short-read parents.** `YAK_COUNT` takes one file per parent (long-read case).
   ONT's paired-end short-read variant uses a double process-substitution
   (`yak count ... <(cat r1 r2) <(cat r1 r2)`) — not implemented.
3. **Collapsed vs. haplotypes downstream.** All three GFAs/FASTAs are emitted per sub-mode;
   which to treat as "the" assembly for downstream use (e.g. the standalone assembly-QC
   workflow, §10) is left to the user.

### Testing
None — no `nf-test` coverage for scalable mode (unlike the assembly-QC workflow's 3-tool
coverage in §10). Matches this pipeline's original "no testing" scope (§1).
