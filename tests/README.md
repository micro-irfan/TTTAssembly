# Running the tests

This directory holds [nf-test](https://www.nf-test.com/) process tests for the `expert`-mode
modules. They are currently **scaffolding only**: each `.nf.test` file asserts `process.success`
against a fixture path that doesn't exist yet (see the `// TODO(user)` markers). Fill in fixtures
under `tests/data/` and the real assertions before relying on these for anything.

## 1. Install nf-test

```bash
curl -fsSL https://code.askimed.com/install/nf-test | bash
# or: nf-core/setup-nf-test@v1 in CI (see .github/workflows/ci.yml)
```

Requires Nextflow `>=23.10.0` (same as the pipeline itself).

## 2. Build the images the tests need

Tests run each process inside its real container via the `test` profile
(`singularity.enabled = true` in `nextflow.config`). Build the non-GPU images at minimum,
into `images/` (see the top-level README's "Build the container images"):

```bash
singularity build images/samtools.sif singularity/samtools/samtools.def
singularity build images/qc.sif       singularity/qc/qc.def
```

`DORADO_CORRECT`'s test is tagged `gpu` and needs `images/dorado.sif` plus a GPU host; skip it
if you don't have one (see §4).

## 3. Add fixtures

Every test currently points at `params.test_data_dir + "/<name>"`, which isn't set anywhere yet.
Add small stub BAM/FASTQ files under `tests/data/` and set `test_data_dir` (e.g. in
`nf-test.config` or via `--test_data_dir` on the CLI) to point at that directory, then replace the
`// TODO(user)` fixture paths and assertions in each `.nf.test` file.

## 4. Run

From the repo root (`nf-test.config` picks up `testsDir "tests"`, `profile "test"` automatically):

```bash
nf-test test                       # run everything runnable on this host
nf-test test --exclude-tag gpu     # skip the Dorado test (no GPU available)
nf-test test tests/modules/local/bam_to_fastq.nf.test   # run a single file
```

## What's covered

| Test file | Process | Notes |
|---|---|---|
| `modules/local/bam_to_fastq.nf.test` | `BAM_TO_FASTQ` | filtering on/off, FASTQ passthrough, multi-file merge, empty-output failure |
| `modules/local/seqkit_stats.nf.test` | `SEQKIT_STATS` | per-source read stats (ULK example) |
| `modules/local/nanoplot.nf.test` | `NANOPLOT` | ULK FASTQ report |
| `modules/local/dorado_correct.nf.test` | `DORADO_CORRECT` | tagged `gpu`; excluded from standard CI runners |

`VERKKO` has no nf-test coverage — the assembly step is too heavy (memory, runtime) to run in CI
or on a dev box.
