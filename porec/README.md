# Running wf-pore-c on the LC2024 T2T open data

`run_wf-pore-c.lc2024.sh` launches [epi2me-labs/wf-pore-c](https://github.com/epi2me-labs/wf-pore-c)
on the Pore-C data from the [London Calling 2024 T2T release](https://epi2me.nanoporetech.com/lc2024_t2t/)
(GM24385 / HG002). It assumes the inputs are already downloaded locally.

Run it with:

```bash
bash run_wfporec.sh
```

## Inputs (edit at the top of the script)

- `POREC_BAM` — path to the Pore-C basecalled/unaligned concatemer BAM (`PAW44788.bam`).
- `REF` — path to the **uncompressed** reference FASTA (`hg002v1.0.1.fasta`); wf-pore-c runs
  `samtools faidx`, which won't read a plain-gzipped file.

## Parameters

Double-dash (`--`) options are wf-pore-c workflow parameters; single-dash (`-`) options are
Nextflow itself.

| Parameter | Value in script | What it does |
|---|---|---|
| `--bam` | `${POREC_BAM}` | Unaligned Pore-C concatemer BAM to analyse. (Use `--fastq` instead if starting from FASTQ.) |
| `--ref` | `${REF}` | Reference FASTA to align monomers against. Swap for your own assembly if scaffolding/QC-ing it. |
| `--cutter` | `NlaIII` | Restriction enzyme used in the digest; drives the virtual digest. **Must match the wet-lab prep.** |
| `--sample` | `${SAMPLE}` | Sample name; prefixes per-sample output files. |
| `--threads` | `${THREADS}` | Max threads for the heavier processes (alignment, annotation). Recommended 64 for a full human BAM. |
| `--pairs` | (on) | Emit a 4DN-format `.pairs.gz` file plus a pairs QC report (contact map + stats). |
| `--mcool` | (on) | Emit a multi-resolution cooler (`.mcool`) for cooltools / HiGlass. |
| `--hi_c` | (on) | Emit a `.hic` file for Juicebox. |
| `--paired_end` | (on) | Create a mock paired-end BAM (required by `--bed` and many downstream tools). |
| `--bed` | (on) | Emit a BED of alignments for scaffolding tools (e.g. YaHS). Also forces `--paired_end`. |
| `--out_dir` | `${OUT_DIR}` | Directory for all user-facing outputs. (Note: wf-pore-c uses `--out_dir`, not `--output`.) |
| `-resume` | — | Nextflow: reuse cached results from a previous run instead of restarting. |
| `-profile` | `singularity` | Nextflow: run tasks inside Singularity containers (use `standard` for Docker). |

## Notes

- **Enzyme:** `NlaIII` is wf-pore-c's default and ONT's standard Pore-C enzyme
- **No haplotagging:** the open dataset ships no phased VCF, so alignments aren't haplotagged.
  To haplotag, add `--vcf phased.vcf.gz`.
- **Output toggles:** drop any of `--pairs/--mcool/--hi_c/--paired_end/--bed` you don't need to
  save time; keep `--paired_end` if you keep `--bed`.
- **Resources:** a full human Pore-C BAM is large — ONT suggests ~64 CPU / 128 GB and ~12 h.
  Reduce `--chunk_size` (default 20000) if you hit memory limits.