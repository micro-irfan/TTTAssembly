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
- Singularity/Apptainer is the only container engine (Docker support was removed — see
  `sessions/session.md`). `.sif` images are built from `singularity/*/*.def` into `images/`
  (gitignored local build artifacts).
- Keep it single-machine / local executor. No Slurm/SGE/LSF config (Verkko has its own grid
  support that is out of scope here).

---

## 2. Reference: the exact commands this pipeline wraps (expert mode)

These come from the ONT protocol PDF. Reproduce them faithfully.

**Step 1 — BAM → FASTQ conversion + quality/length filtering**
```bash
# ULK (ultra-long) reads — higher length floor, this is what "ultra-long" means
samtools view -u -e '[qs]>=10 && length(seq)>=10000' <input_ulk.bam>   | samtools fastq > ultralongreads.fastq
# Pore-C reads — same qscore floor, lower length floor
samtools view -u -e '[qs]>=10 && length(seq)>=1000' <input_porec.bam> | samtools fastq > porec.fastq
```
- When `--filtering false`, drop the `-e '...'` expression and do a plain conversion
  (`samtools fastq <in.bam> > out.fastq`). See §5 for the exact rule.
- Length thresholds differ by read type: `--min_len_ulk` (default `10000`) vs `--min_len_porec`
  (default `1000`); `--min_qs` (default `10`) is shared by both. See §3.
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
| `--min_qs` | `10` | Filter threshold, mean read qscore. Shared by ULK and Pore-C. |
| `--min_len_ulk` | `10000` | Filter threshold, ULK read length (bp). |
| `--min_len_porec` | `1000` | Filter threshold, Pore-C read length (bp). |
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
- More than one file for a given input → merge with `MERGE_READS` first (`samtools merge` for
  BAM, `cat` for FASTQ/FASTQ.GZ — gzip streams concatenate cleanly). Exactly one file → passed
  through untouched, no merge process is invoked.
- `--hic_reads_1` and `--hic_reads_2` lists must have matching lengths (validated in `main.nf`).
- See `MERGE_READS` in §5 and the `splitReadsParam`/`mergeIfMultiple` helpers in `workflows/expert.nf`.

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
│       ├── common.nf             # BAM_TO_FASTQ + MERGE_READS (samtools-based read processing)
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
└── images/                       # built .sif files (gitignored — not checked in)
```

`nextflow.config` and all `singularity/*/*.def` files already exist — **do not rewrite them**,
just implement the `.nf` files against them.

---

## 5. Module specs (reference implementations)

Use DSL2, `tag "${params.sample}"`, and `publishDir` into `params.output`. Containers are
assigned in `nextflow.config` via `withName:` selectors — do not hard-code `container` in the
modules unless a selector is missing. Related processes that share a container are grouped into
one file (`common.nf`, `qc.nf`, `tool_versions.nf`) rather than one-process-per-file — `withName:`
selectors key off the **process name**, not the filename, so this doesn't affect config wiring.

### `common.nf` — samtools-based read processing

#### `MERGE_READS` (modules/local/common.nf)
Merges a comma-separated multi-flowcell input into one file, before `BAM_TO_FASTQ`/`VERKKO`.
Only invoked when there's more than one file for a given `--*_reads` param (see §3).
```groovy
process MERGE_READS {
    tag "${params.sample}:${label}"
    publishDir "${params.output}/merged", mode: 'copy'

    input:
    tuple val(label), path(reads), val(ext)

    output:
    tuple val(label), path("${params.sample}.${label}.merged.${ext}"), emit: merged

    script:
    def out = "${params.sample}.${label}.merged.${ext}"
    if (ext == 'bam')
        "samtools merge -@ ${task.cpus} -f ${out} ${reads}"
    else
        "cat ${reads} > ${out}"
}
```
- Reuses the `images/samtools.sif` image (both `samtools merge` and `cat` are available there)
  — no new container.
- `ext` is determined by the caller (`splitReadsParam()` in `workflows/expert.nf`) from the file
  extensions, not detected inside the process.
- Same `-@ ${task.cpus}` / `params.threads` wiring as `BAM_TO_FASTQ`.

#### `BAM_TO_FASTQ` (modules/local/common.nf)
Reused for both ULK and Pore-C. A `label` string ("ultralong" / "porec") drives the output name
**and** picks the length threshold (`--min_len_ulk` vs `--min_len_porec`); the qscore threshold
(`--min_qs`) is shared.

```groovy
process BAM_TO_FASTQ {
    tag "${params.sample}:${label}"
    publishDir "${params.output}/fastq", mode: 'copy'

    input:
    tuple val(label), path(bam)

    output:
    tuple val(label), path("${params.sample}.${label}.fastq"), emit: fastq

    script:
    def out     = "${params.sample}.${label}.fastq"
    def min_len = (label == 'ultralong') ? params.min_len_ulk : params.min_len_porec
    if (params.filtering.toString().toLowerCase() == 'true')
        """
        samtools view -u -@ ${task.cpus} -e '[qs]>=${params.min_qs} && length(seq)>=${min_len}' ${bam} \
            | samtools fastq -@ ${task.cpus} > ${out}
        """
    else
        """
        samtools fastq -@ ${task.cpus} ${bam} > ${out}
        """
}
```
- The samtools filter expression contains no `$`, so single-quoting it inside the double-quoted
  Nextflow script block is safe.
- Needs samtools ≥ 1.16 for the `-e` expression grammar (`[qs]`, `length(seq)`). Our image is 1.23.1.
- `-@ ${task.cpus}` comes from the `cpus` directive in `nextflow.config` (`params.threads`) — no
  hard-coded thread count in the module.

### `qc.nf` — read summary / QC

#### `SEQKIT_STATS` (modules/local/qc.nf)
Called once per read source from `expert.nf` — ULK, Pore-C (if present), and the
Dorado-corrected reads — so each gets its own report rather than one combined file. `label`
("ultralong" / "porec" / "corrected") drives the output filename, same pattern as `BAM_TO_FASTQ`.
```groovy
process SEQKIT_STATS {
    tag "${params.sample}:${label}"
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
    publishDir "${params.output}/corrected", mode: 'copy'
    input:  path ulk_fastq
    output: path "${params.sample}.doradocorrect.fasta", emit: corrected
    script:
    """
    dorado correct -x ${params.dorado_device} -t ${task.cpus} ${ulk_fastq} > ${params.sample}.doradocorrect.fasta
    """
}
```
- GPU is enabled by `containerOptions '--nv'` in the config (`withName: DORADO_CORRECT`).
- `dorado correct` downloads its correction model on first run (needs internet) unless it's
  pre-baked or a model cache volume is mounted. See the dorado `.def` comment. Leave a
  commented `--model-path` hook in the process for when a cached model is mounted.

### `VERKKO` (modules/local/verkko.nf)
Handle both branches with optional inputs. Pass empty file lists for the branch that isn't used.
```groovy
process VERKKO {
    tag "${params.sample}"
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
One tiny version-capture process per container already used elsewhere in the pipeline (reuses
the same image, so the reported version is guaranteed to match what actually ran), plus a
combiner. All have no pipeline inputs — they run `<tool> --version` once per invocation:

- `SAMTOOLS_VERSION` — `images/samtools.sif` (same container as `BAM_TO_FASTQ`/`MERGE_READS`)
- `QC_VERSIONS` — `images/qc.sif`; captures both seqkit and NanoPlot in one process (same
  container as `SEQKIT_STATS`/`NANOPLOT`)
- `DORADO_VERSION` — `images/dorado.sif`, deliberately **without** `--nv`: a version
  check doesn't need GPU hardware
- `VERKKO_VERSION` — `images/verkko.sif`

Each writes `<tool>.version.txt` containing the raw first line of `<tool> --version` output
(formats vary by tool — not reparsed/normalized further; see the module files if a
specific tool's format needs stripping down to a bare version number).

`SOFTWARE_VERSIONS` collects all `*.version.txt` files (`workflows/expert.nf` mixes + flattens
the four channels above) plus `workflow.nextflow.version` and `workflow.manifest.version`, and
writes `${params.sample}.software_versions.json` to `${params.output}/`. Runs in the qc
container (already has python3 via miniforge) — no new image.

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

## 7. Containers (already written under `singularity/`)

One image per tool, built into `images/` (gitignored) and referenced there by exact path
(set in `nextflow.config`):

| Process | Image | Base / install |
|---|---|---|
| `BAM_TO_FASTQ`, `MERGE_READS`, `SAMTOOLS_VERSION` | `images/samtools.sif` | ubuntu, samtools built from source |
| `SEQKIT_STATS`, `NANOPLOT`, `QC_VERSIONS`, `SOFTWARE_VERSIONS` | `images/qc.sif` | miniforge, `seqkit` + `nanoplot` |
| `DORADO_CORRECT`, `DORADO_VERSION` | `images/dorado.sif` | `nvidia/cuda` runtime + Dorado CDN binary |
| `VERKKO`, `VERKKO_VERSION` | `images/verkko.sif` | miniforge, `verkko` from bioconda |
| (scalable, later) | `images/hifiasm.sif` | ubuntu, hifiasm built from source |

Build all:
```bash
singularity build images/samtools.sif singularity/samtools/samtools.def
singularity build images/dorado.sif   singularity/dorado/dorado.def
singularity build images/verkko.sif   singularity/verkko/verkko.def
singularity build images/hifiasm.sif  singularity/hifiasm/hifiasm.def
singularity build images/qc.sif       singularity/qc/qc.def
```
GPU note: the host needs the NVIDIA driver; the Dorado process requests the GPU via `--nv`
(set in config). Verify with `singularity exec --nv images/dorado.sif dorado --version`.

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
- UPPER_SNAKE_CASE process names. Group related processes that share a container into one
  module file (e.g. `common.nf`, `qc.nf`, `tool_versions.nf`) rather than one-process-per-file —
  `withName:` selectors in `nextflow.config` key off the process name, not the filename.
- No hard-coded resources in modules — resources and `container` come from `nextflow.config`.
- `publishDir mode: 'copy'`.
- Prefix every output file with `${params.sample}`.
- Keep the Verkko quirk comment (nano=uncorrected, hifi=corrected) in `verkko.nf`.
- `scalable.nf` must exist and fail cleanly: `error "scalable mode not yet implemented"`.
- Don't touch `nextflow.config` or the `singularity/*/*.def` files unless a bug blocks the
  build; if you do, note it in `session.md`.
