# ont-t2t-assembly

Nextflow (DSL2) pipeline reproducing the Oxford Nanopore "expert telomere-to-telomere (T2T)"
downstream analysis workflow for `SQK-ULK114` ultra-long reads combined with Pore-C or Hi-C
data. Assembly is done with **Verkko**. See [CLAUDE.md](CLAUDE.md) for the full spec.

Two modes, selected with `--mode`:
- `expert` — implemented: samtools (BAM → FASTQ, filtered) → QC (seqkit stats [+ NanoPlot]) →
  Dorado correct (GPU, ULK only) → Verkko assembly (Pore-C or Hi-C branch).
- `scalable` — stub only; fails fast until its steps are implemented.

## Requirements

- [Nextflow](https://www.nextflow.io/) `>=23.10.0`
- Docker (or Singularity — see below), with an NVIDIA driver + `nvidia-container-toolkit` on
  the host for the Dorado correct step (GPU).

## 1. Build the container images

One image per tool, built from `docker/`:

```bash
docker build -t ont-t2t/samtools:1.23.1 docker/samtools
docker build -t ont-t2t/dorado:2.1.1    docker/dorado
docker build -t ont-t2t/verkko:2.3.2    docker/verkko
docker build -t ont-t2t/hifiasm:0.25.0  docker/hifiasm   # not used by expert mode; for scalable mode
docker build -t ont-t2t/qc:latest       docker/qc
```

Verify GPU access for Dorado:

```bash
docker run --rm --gpus all ont-t2t/dorado:2.1.1 dorado --version
```

## 2. Run the pipeline

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

See all options:

```bash
nextflow run main.nf --help
```

### Key parameters

| Param | Default | Meaning |
|---|---|---|
| `--mode` | `expert` | `expert` or `scalable`. |
| `--sample` | `sample` | Sample name; prefixes all output filenames. |
| `--ulk_reads` | `null` | Path to the ULK BAM (required, expert mode). |
| `--porec_reads` | `null` | Path to the Pore-C BAM. Mutually exclusive with the Hi-C pair. |
| `--hic_reads_1/2` | `null` | Paths to the Hi-C R1/R2 FASTQs. |
| `--max_memory_gb` | `null` | Integer GB passed to Verkko `--local-memory` (required, expert mode). |
| `--filtering` | `true` | `true` → apply qs/length filter; `false` → plain BAM→FASTQ. |
| `--run_nanoplot` | `true` | Also run NanoPlot in the QC step. |
| `--output` | `results` | Output directory. |

Full table in [CLAUDE.md §3](CLAUDE.md#3-parameters-define-in-nextflowconfig-document-in-a---help).

### Container engine

```bash
nextflow run main.nf -profile docker ...        # default, fully supported
nextflow run main.nf -profile singularity ...    # alternative, no GPU flags needed on the CLI —
                                                  # Singularity picks up host GPUs via --nv where configured
```

#### Building the Singularity/Apptainer images

Recipe files mirroring `docker/` live under `singularity/` (one `.def` per tool):

```bash
singularity build singularity/samtools/samtools.sif singularity/samtools/samtools.def
singularity build singularity/dorado/dorado.sif     singularity/dorado/dorado.def
singularity build singularity/verkko/verkko.sif     singularity/verkko/verkko.def
singularity build singularity/hifiasm/hifiasm.sif   singularity/hifiasm/hifiasm.def   # scalable mode
singularity build singularity/qc/qc.sif             singularity/qc/qc.def
```

(`apptainer build ...` works identically if that's what's installed.) Building most of these
requires root or `--fakeroot` (`singularity build --fakeroot ...`), since they install system
packages via `apt-get`/`mamba` in `%post`.

The `singularity` profile in `nextflow.config` points each process at its local `.sif` under
`singularity/<tool>/` (built with the commands above) instead of the Docker tags used by
`-profile docker`, since those are local-only images Singularity can't pull by tag. Build the
`.sif` files at those exact paths (relative to the pipeline directory) before running with
`-profile singularity`. It also overrides `DORADO_CORRECT`'s GPU flag to `--nv` (Singularity's
equivalent of Docker's `--gpus all`, which isn't a valid Singularity flag).

## 3. Outputs

Published under `--output` (default `results/`):

```
results/
├── fastq/          # ${sample}.ultralong.fastq, ${sample}.porec.fastq
├── qc/              # ${sample}.read_stats.tsv, nanoplot_${sample}/
├── corrected/        # ${sample}.doradocorrect.fasta
├── verkko_output/     # assembly.fasta, assembly.haplotype1.fasta, assembly.haplotype2.fasta, ...
└── pipeline_info/     # timeline/report/trace/dag
```

## Testing

`nf-test` skeletons live under `tests/` (scaffolding only — no stub fixtures or real assertions
yet; see `// TODO(user)` markers in each `.nf.test` file). Once fixtures are added:

```bash
nf-test test                       # run everything runnable on this host
nf-test test --exclude-tag gpu     # skip the Dorado test on non-GPU runners
```

The Verkko/assembly step is intentionally not covered by nf-test (too heavy to run in CI).
