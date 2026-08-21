# CLAUDE.md

Guidance for building the **ONT long-read T2T de novo assembly** Nextflow pipeline.
This file is the source of truth for the build. Read it fully before writing any code.

---

## 1. What we are building

A Nextflow (DSL2) pipeline that reproduces the Oxford Nanopore "expert telomere-to-telomere
(T2T)" downstream analysis workflow for `SQK-ULK114` ultra-long reads combined with Pore-C
or Hi-C data. Assembly is done with **Verkko**.

The pipeline is **modular by mode**, selected with `--mode`:

- `expert`  → implemented now (this document).
- `scalable` → **stub only** for now. The user will supply the steps later. Create the
  file and the `--mode scalable` dispatch, but leave the body as a clearly-marked TODO that
  fails fast with an informative message. Do **not** invent scalable-mode steps.

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
│       ├── common.nf             # BAM_TO_FASTQ (samtools-based read merge + filter/convert)
│       ├── qc.nf                 # SEQKIT_STATS + NANOPLOT (NANOPLOT gated by --plot)
│       ├── dorado_correct.nf     # DORADO_CORRECT (GPU)
│       ├── verkko.nf             # VERKKO (porec + hic handled with optional inputs)
│       ├── tool_versions.nf      # SAMTOOLS_VERSION + QC_VERSIONS + DORADO_VERSION + VERKKO_VERSION
│       └── software_versions.nf  # SOFTWARE_VERSIONS — combines the above into one JSON
├── workflows/
│   ├── expert.nf                 # the implemented workflow
│   └── scalable.nf               # STUB — fail-fast TODO, user fills later
├── singularity/                  # .def recipes (ALREADY WRITTEN — one per tool)
│   ├── samtools/samtools.def
│   ├── dorado/dorado.def
│   ├── verkko/verkko.def
│   ├── hifiasm/hifiasm.def       # not used by expert mode; built ahead for scalable mode
│   └── qc/qc.def                 # seqkit + NanoPlot for the summary step
├── conda/                        # env YAMLs for -profile conda (no Dorado — no conda package)
│   ├── samtools.yml
│   ├── qc.yml
│   └── verkko.yml
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
Related processes that share a label are grouped into one file (`common.nf`, `qc.nf`,
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
- `-@ ${task.cpus}` comes from the `cpus` directive in `nextflow.config` (`params.threads`) — no
  hard-coded thread count in the module.
- A single input file (`!multi`) skips `samtools merge` entirely — no point re-muxing one BAM.
- `[ -s ${out} ]` (POSIX `test -s`: exists and non-empty) fails the task with a clear message
  if filtering/conversion produces an empty FASTQ, instead of letting an empty read set reach
  Dorado/Verkko silently. `errorStrategy = 'terminate'` (set in `nextflow.config`) stops the
  whole run as soon as this — or any — task fails.

### `qc.nf` — read summary / QC

#### `SEQKIT_STATS` (modules/local/qc.nf)
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

#### `NANOPLOT` (modules/local/qc.nf)
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
```groovy
process VERKKO {
    tag "${params.sample}"
    label 'verkko'
    publishDir "${params.output}", mode: 'copy'

    input:
    path nano_fastq          // uncorrected ULK
    path hifi_fasta          // dorado-corrected ULK
    path porec_fastq         // may be []
    tuple path(hic1), path(hic2)   // may be [ [], [] ]

    output:
    path "verkko_output/**", emit: assembly

    script:
    def reads_arg = porec_fastq ? "--porec ${porec_fastq}" : "--hic1 ${hic1} --hic2 ${hic2}"
    """
    verkko --nano ${nano_fastq} --hifi ${hifi_fasta} ${reads_arg} \
        --no-correction --local-memory ${params.max_memory_gb} --local-cpus ${task.cpus} \
        -d verkko_output
    """
}
```
- Prefer wiring two explicit calls (a Pore-C call and a Hi-C call) from `expert.nf` over
  branching inside one process if the optional-path handling gets awkward — either is fine,
  pick the cleaner one. The key outputs to expose are `assembly.fasta`,
  `assembly.haplotype1.fasta`, `assembly.haplotype2.fasta`.

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
| `BAM_TO_FASTQ`, `SAMTOOLS_VERSION` | `images/samtools.sif` | `conda/samtools.yml` | ubuntu, samtools built from source / bioconda |
| `SEQKIT_STATS`, `NANOPLOT`, `QC_VERSIONS`, `SOFTWARE_VERSIONS` | `images/qc.sif` | `conda/qc.yml` | miniforge, `seqkit` + `nanoplot`, both bioconda |
| `DORADO_CORRECT`, `DORADO_VERSION` | `images/dorado.sif` | *(none — see below)* | `nvidia/cuda` runtime + Dorado CDN binary |
| `VERKKO`, `VERKKO_VERSION` | `images/verkko.sif` | `conda/verkko.yml` | miniforge, `verkko` from bioconda |
| (scalable, later) | `images/hifiasm.sif` | *(none yet)* | ubuntu, hifiasm built from source |

Build all Singularity images:
```bash
singularity build images/samtools.sif singularity/samtools/samtools.def
singularity build images/dorado.sif   singularity/dorado/dorado.def
singularity build images/verkko.sif   singularity/verkko/verkko.def
singularity build images/hifiasm.sif  singularity/hifiasm/hifiasm.def
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
  `qc.nf`, `tool_versions.nf`) rather than one-process-per-file — the filename is irrelevant to
  config wiring either way.
- No hard-coded resources in modules — resources and `container`/`conda` come from
  `nextflow.config`.
- `publishDir mode: 'copy'`.
- Prefix every output file with `${params.sample}`.
- Keep the Verkko quirk comment (nano=uncorrected, hifi=corrected) in `verkko.nf`.
- `scalable.nf` must exist and fail cleanly: `error "scalable mode not yet implemented"`.
- Don't touch `nextflow.config` or the `singularity/*/*.def` files unless a bug blocks the
  build; if you do, note it in `session.md`.
