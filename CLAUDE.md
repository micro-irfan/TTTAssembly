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
- Docker is the only container engine wired up right now (a Singularity profile can be added
  later — leave a commented placeholder, don't implement).
- Keep it single-machine / local executor. No Slurm/SGE/LSF config (Verkko has its own grid
  support that is out of scope here).

---

## 2. Reference: the exact commands this pipeline wraps (expert mode)

These come from the ONT protocol PDF. Reproduce them faithfully.

**Step 1 — BAM → FASTQ conversion + quality/length filtering**
```bash
# ULK (ultra-long) reads
samtools view -u -e '[qs]>=10 && length(seq)>=1000' <input_ulk.bam>   | samtools fastq > ultralongreads.fastq
# Pore-C reads (same thresholds)
samtools view -u -e '[qs]>=10 && length(seq)>=1000' <input_porec.bam> | samtools fastq > porec.fastq
```
- When `--filtering false`, drop the `-e '...'` expression and do a plain conversion
  (`samtools fastq <in.bam> > out.fastq`). See §5 for the exact rule and the open question
  logged in `session.md`.
- Thread both `samtools view` and `samtools fastq` with `-@ ${task.cpus}`.
- Hi-C reads are **already FASTQ** (`--hic_reads_1/2`); they are **not** converted here.

**Step 2 — Read summary / QC statistics** (our addition; see §6 for tool choice)
```bash
seqkit stats -a -T ultralongreads.fastq porec.fastq > read_stats.tsv
# optional richer QC on the ultra-long reads (N50 / length / quality plots)
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
| `--ulk_reads` | `null` | Path to the ULK **BAM** (required in expert mode). |
| `--porec_reads` | `null` | Path to the Pore-C **BAM**. Mutually exclusive with the Hi-C pair. |
| `--hic_reads_1` | `null` | Path to Hi-C R1 **FASTQ**. |
| `--hic_reads_2` | `null` | Path to Hi-C R2 **FASTQ**. |
| `--output` | `results` | Output directory (publishDir target). |
| `--max_memory_gb` | `null` | Integer GB passed to Verkko `--local-memory`. Required in expert mode. |
| `--threads` | `8` | Default CPUs per process (maps to `task.cpus`). |
| `--dorado_device` | `cuda:0` | Device string for `dorado correct -x`. |
| `--min_qs` | `10` | Filter threshold, mean read qscore. |
| `--min_len` | `1000` | Filter threshold, read length (bp). |
| `--run_nanoplot` | `true` | Also run NanoPlot in the QC step (seqkit stats always runs). |

### Reads-type inference (do not add a separate flag)
- If `--porec_reads` is set → **Pore-C branch**.
- Else if `--hic_reads_1` **and** `--hic_reads_2` are set → **Hi-C branch**.
- Else → fail validation with a clear message.
- If both Pore-C and Hi-C are given → fail (ambiguous).

### Validation (expert mode)
Fail fast, before any process launches, if: `ulk_reads` missing; `max_memory_gb` missing;
neither Pore-C nor Hi-C provided; both provided; a Hi-C file provided without its pair.

---

## 4. File layout to create

```
ont-t2t-assembly/
├── CLAUDE.md                     # this file
├── session.md                    # working state / checklist / open questions
├── main.nf                       # entry: param validation + mode dispatch
├── nextflow.config               # params, docker profile, per-process resources (ALREADY WRITTEN)
├── modules/
│   └── local/
│       ├── bam_to_fastq.nf       # BAM_TO_FASTQ (reused for ULK and Pore-C)
│       ├── seqkit_stats.nf       # SEQKIT_STATS
│       ├── nanoplot.nf           # NANOPLOT (optional)
│       ├── dorado_correct.nf     # DORADO_CORRECT (GPU)
│       └── verkko.nf             # VERKKO (porec + hic handled with optional inputs)
├── workflows/
│   ├── expert.nf                 # the implemented workflow
│   └── scalable.nf               # STUB — fail-fast TODO, user fills later
└── docker/                       # Dockerfiles (ALREADY WRITTEN — one image per tool)
    ├── samtools/Dockerfile
    ├── dorado/Dockerfile
    ├── verkko/Dockerfile
    ├── hifiasm/Dockerfile        # not used by expert mode; built ahead for scalable mode
    └── qc/Dockerfile             # seqkit + NanoPlot for the summary step
```

`nextflow.config` and all `docker/*/Dockerfile` files already exist — **do not rewrite them**,
just implement the `.nf` files against them.

---

## 5. Module specs (reference implementations)

Use DSL2, one `process` per file, `tag "${params.sample}"`, and `publishDir` into `params.output`.
Containers are assigned in `nextflow.config` via `withName:` selectors — do not hard-code
`container` in the modules unless a selector is missing.

### `BAM_TO_FASTQ` (modules/local/bam_to_fastq.nf)
Reused for both ULK and Pore-C. A `label` string ("ultralong" / "porec") drives the output name.

```groovy
process BAM_TO_FASTQ {
    tag "${params.sample}:${label}"
    publishDir "${params.output}/fastq", mode: 'copy'

    input:
    tuple val(label), path(bam)

    output:
    tuple val(label), path("${params.sample}.${label}.fastq"), emit: fastq

    script:
    def out = "${params.sample}.${label}.fastq"
    if (params.filtering.toString().toLowerCase() == 'true')
        """
        samtools view -u -@ ${task.cpus} -e '[qs]>=${params.min_qs} && length(seq)>=${params.min_len}' ${bam} \
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

### `SEQKIT_STATS` (modules/local/seqkit_stats.nf)
Takes all FASTQs (collected) and writes one TSV.
```groovy
process SEQKIT_STATS {
    tag "${params.sample}"
    publishDir "${params.output}/qc", mode: 'copy'
    input:  path fastqs
    output: path "${params.sample}.read_stats.tsv", emit: stats
    script: "seqkit stats -a -T ${fastqs} > ${params.sample}.read_stats.tsv"
}
```

### `NANOPLOT` (modules/local/nanoplot.nf)
Run on the ultra-long FASTQ only (that's where read-length/N50 matters for this workflow).
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
- GPU is enabled by `containerOptions '--gpus all'` in the config (`withName: DORADO_CORRECT`).
- `dorado correct` downloads its correction model on first run (needs internet) unless it's
  pre-baked or a model cache volume is mounted. See the dorado Dockerfile comment. Leave a
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

---

## 6. QC tool choice (step 2)

The doc stresses read **N50 ≥ 60 kb** as the driver of assembly quality, so the summary step
should surface N50 and the read-length distribution:

- **seqkit stats -a** — fast, always run. Tabular: num_seqs, sum_len, min/avg/max, **N50**,
  Q20(%), Q30(%). One TSV covering ULK + Pore-C.
- **NanoPlot** — ONT-native, optional (`--run_nanoplot`). Adds read-length and quality plots
  and an HTML report for the ultra-long reads.

Both live in the single `qc` image. `NanoComp` is a reasonable alternative if the user later
wants to compare ULK vs Pore-C side by side — not needed now.

---

## 7. Containers (already built from `docker/`)

One image per tool, referenced by these local tags (set in `nextflow.config`):

| Process | Image tag | Base / install |
|---|---|---|
| `BAM_TO_FASTQ` | `ont-t2t/samtools:1.23.1` | ubuntu, samtools built from source |
| `SEQKIT_STATS`, `NANOPLOT` | `ont-t2t/qc:latest` | miniforge, `seqkit` + `nanoplot` |
| `DORADO_CORRECT` | `ont-t2t/dorado:2.1.1` | `nvidia/cuda` runtime + Dorado CDN binary |
| `VERKKO` | `ont-t2t/verkko:2.3.2` | miniforge, `verkko` from bioconda |
| (scalable, later) | `ont-t2t/hifiasm:0.25.0` | ubuntu, hifiasm built from source |

Build all:
```bash
docker build -t ont-t2t/samtools:1.23.1 docker/samtools
docker build -t ont-t2t/dorado:2.1.1    docker/dorado
docker build -t ont-t2t/verkko:2.3.2    docker/verkko
docker build -t ont-t2t/hifiasm:0.25.0  docker/hifiasm
docker build -t ont-t2t/qc:latest       docker/qc
```
GPU note: the host needs the NVIDIA driver + `nvidia-container-toolkit`; the Dorado process
requests the GPU via `--gpus all` (set in config). Verify with
`docker run --rm --gpus all ont-t2t/dorado:2.1.1 dorado --version`.

---

## 8. Run examples (for the README / --help text)

```bash
# Pore-C, expert mode
nextflow run main.nf -profile docker \
  --mode expert --sample HG002 \
  --ulk_reads ulk.bam --porec_reads porec.bam \
  --max_memory_gb 480 --output results

# Hi-C, no pre-filtering
nextflow run main.nf -profile docker \
  --mode expert --sample HG002 --filtering false \
  --ulk_reads ulk.bam --hic_reads_1 hic_R1.fastq --hic_reads_2 hic_R2.fastq \
  --max_memory_gb 480 --output results
```

---

## 9. Conventions

- Nextflow DSL2, `nextflow.enable.dsl=2`.
- One process per module file; UPPER_SNAKE_CASE process names.
- No hard-coded resources in modules — resources and `container` come from `nextflow.config`.
- `publishDir mode: 'copy'`.
- Prefix every output file with `${params.sample}`.
- Keep the Verkko quirk comment (nano=uncorrected, hifi=corrected) in `verkko.nf`.
- `scalable.nf` must exist and fail cleanly: `error "scalable mode not yet implemented"`.
- Don't touch `nextflow.config` or the Dockerfiles unless a bug blocks the build; if you do,
  note it in `session.md`.
