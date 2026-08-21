// SOFTWARE_VERSIONS
// Combines the per-tool version snippets (SAMTOOLS_VERSION, QC_VERSIONS, DORADO_VERSION,
// VERKKO_VERSION) plus the Nextflow/pipeline versions into one JSON file in the output
// directory. Runs in the qc container (has python3 via miniforge) — no new image needed.

process SOFTWARE_VERSIONS {
    tag "${params.sample}"
    publishDir "${params.output}", mode: 'copy'

    input:
    path versions

    output:
    path "${params.sample}.software_versions.json", emit: versions_json

    script:
    """
    python3 - <<'PYEOF' > ${params.sample}.software_versions.json
import glob, json

report = {}
for f in sorted(glob.glob("*.version.txt")):
    tool = f[:-len(".version.txt")]
    with open(f) as fh:
        report[tool] = fh.read().strip()

report["nextflow"] = "${workflow.nextflow.version}"
report["pipeline"]  = "${workflow.manifest.name}:${workflow.manifest.version}"

print(json.dumps(report, indent=2, sort_keys=True))
PYEOF
    """
}
