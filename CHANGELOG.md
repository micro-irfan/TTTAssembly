# Changelog

All notable changes to this project are documented in this file.

## [1.1.0] - Unreleased

- Added a standalone assembly-QC workflow (`assembly_qc.nf`, conda-only for now): gfastats,
  seqtk telo, compleasm, QUAST, Merqury, Merfin. Independent of the main pipeline — takes
  assembly FASTA(s) directly

## [1.0.0] - 2026-08-21

- Initial Commit: Established Expert Workflow (Dorado Correct + Verkko for ULK + Pore-C) 
  added based on ONT's recommendations