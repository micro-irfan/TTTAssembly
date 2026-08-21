# TTTAssembly

TTT (Telomere To Telomere) Assembly is a Nextflow (DSL2) pipeline wrapping the Oxford Nanopore 
T2T suggested analysis workflow for `SQK-ULK114` ultra-long reads combined with Pore-C or Hi-C data.
Assembly is done with **Verkko**. See [CLAUDE.md](CLAUDE.md) for the full spec.

Two modes, selected with `--mode`:
- `expert` — implemented: samtools (BAM → FASTQ, filtered) → QC (seqkit stats [+ NanoPlot with
  `--plot`]) → Dorado correct (GPU, ULK only) → Verkko assembly (Pore-C or Hi-C branch).
- `scalable` — stub only; fails fast until its steps are implemented.

## Requirements

- [Nextflow](https://www.nextflow.io/) `>=23.10.0`
- Either Singularity/Apptainer (`-profile singularity`, default) **or** Conda/Mamba
  (`-profile conda` — see "Alternative: Conda" below), with an NVIDIA driver on the host for
  the Dorado correct step (GPU) either way.

## 1. Build the container images

One image per tool, built from the recipes under `singularity/` into `images/` (gitignored —
these are large local build artifacts, not checked in):

```bash
singularity build images/samtools.sif singularity/samtools/samtools.def
singularity build images/dorado.sif   singularity/dorado/dorado.def
singularity build images/verkko.sif   singularity/verkko/verkko.def
singularity build images/hifiasm.sif  singularity/hifiasm/hifiasm.def   # not used by expert mode; for scalable mode
singularity build images/qc.sif       singularity/qc/qc.def
```

`nextflow.config` points each process at its `.sif` under `images/` by exact path (relative 
to the pipeline directory), so build them there before running.

Verify GPU access for Dorado:

```bash
singularity exec --nv images/dorado.sif dorado --version
```

### Alternative: Conda instead of Singularity

`-profile conda` uses Conda/Mamba environments instead of Singularity images — no image builds,
no root/`--fakeroot`. Requires `conda` or `mamba` on `PATH`; Nextflow reads
`NXF_CONDA_ENABLED`/uses whichever it finds and picks Mamba automatically if available (faster
solves).

Environment YAMLs live under `conda/` (`samtools.yml`, `qc.yml`, `verkko.yml`) — one per tool,
mirroring the `singularity/` `.def` layout. **You don't need to create these envs yourself**:
Nextflow creates and caches one per YAML automatically the first time you run with
`-profile conda` (slow on first run, cached — by content hash — after that; set
`NXF_CONDA_CACHEDIR` to control where).

**Dorado is the one exception** — there's no bioconda/conda-forge package for it, so
`DORADO_CORRECT` has no `conda` directive and just runs against whatever `dorado` binary is
already on `PATH`. Install ONT's binary manually (same version/URL as
`singularity/dorado/dorado.def`):

```bash
DORADO_VERSION=2.1.1
wget -q "https://cdn.oxfordnanoportal.com/software/analysis/dorado-${DORADO_VERSION}-linux-x64.tar.gz"
tar -xzf "dorado-${DORADO_VERSION}-linux-x64.tar.gz" -C ~/opt
rm "dorado-${DORADO_VERSION}-linux-x64.tar.gz"
export PATH="$HOME/opt/dorado-${DORADO_VERSION}-linux-x64/bin:$PATH"   # add to your shell rc to persist
dorado --version
```

Alternatively, point the pipeline at the binary directly instead of adjusting `PATH`. 
`--dorado_path` overrides `dorado` wherever it's invoked (`DORADO_CORRECT` and `DORADO_VERSION`,
under any profile).

```bash
--dorado_path "$HOME/opt/dorado-${DORADO_VERSION}-linux-x64/bin/dorado"
```

`images/` and the `singularity/*.def` builds aren't needed for `-profile conda`.

## 2. Run the pipeline

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

See all options:

```bash
nextflow run main.nf --help
```

### Key parameters

| Param | Default | Meaning |
|---|---|---|
| `--mode` | `expert` | `expert` or `scalable`. |
| `--sample` | `sample` | Sample name; prefixes all output filenames. |
| `--ulk_reads` | `null` | Path to the ULK BAM (required, expert mode). Comma-separate multiple flowcells to merge them. |
| `--porec_reads` | `null` | Path to the Pore-C BAM. Mutually exclusive with the Hi-C pair. Comma-separated list supported. |
| `--hic_reads_1/2` | `null` | Paths to the Hi-C R1/R2 FASTQs. Comma-separated lists supported (same count on both). |
| `--max_memory_gb` | `null` | Integer GB passed to Verkko `--local-memory` (required, expert mode). |
| `--filtering` | `true` | `true` → apply qs/length filter; `false` → plain BAM→FASTQ. |
| `--plot` | `false` | Also run NanoPlot in the QC step (seqkit stats always runs). |
| `--output` | `results` | Output directory. |

Full table in [CLAUDE.md §3](CLAUDE.md#3-parameters-define-in-nextflowconfig-document-in-a---help).

### Multiple flowcells (ULK/Pore-C/Hi-C)

`--ulk_reads`, `--porec_reads`, `--hic_reads_1`, and `--hic_reads_2` each accept a
comma-separated list of files — useful since ULK runs are typically split across 2-3 flowcells:

```bash
--ulk_reads fc1.bam,fc2.bam,fc3.bam
```

All files in one list must be the same type (all `.bam`, or all `.fastq`/`.fastq.gz`); they're
merged before the rest of the pipeline runs — `samtools merge` pipes straight into the
qs/length filter for BAM, `cat`/`zcat` for FASTQ, so no intermediate merged file is ever
written to disk. `--hic_reads_1` and `--hic_reads_2` must list the same number of files.

If the qs/length filter (or the merge itself) leaves zero reads for a source, the pipeline
fails immediately with a clear error rather than continuing on to Dorado/Verkko with an empty
FASTQ.

## 3. Outputs

Published under `--output` (default `results/`):

```
results/
├── fastq/          # ${sample}.ultralong.fastq, ${sample}.porec.fastq, ${sample}.hic_r1/r2.fastq — merge
│                    # (multi-flowcell) + filter/convert happen in one step, no intermediate file
├── qc/              # ${sample}.ultralong.read_stats.tsv, ${sample}.porec.read_stats.tsv (if Pore-C),
│                    # ${sample}.corrected.read_stats.tsv, nanoplot_${sample}/ (with --plot)
├── corrected/        # ${sample}.doradocorrect.fasta
├── verkko_output/     # assembly.fasta, assembly.haplotype1.fasta, assembly.haplotype2.fasta, ...
├── ${sample}.software_versions.json  # samtools/seqkit/NanoPlot/dorado/verkko/nextflow/pipeline versions
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
