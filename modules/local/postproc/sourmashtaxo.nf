process POSTPROC_SOURMASHTAXO {
    tag "$meta.id"
    label 'process_single'

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/biopython:1.81':
        'quay.io/biocontainers/biopython:1.81' }"

    input:
    tuple val(meta), path(gather_result_csv)
    path(metadata_file)

    output:
    tuple val(meta), path("*.tsv"), emit: sm_taxo
    path "versions.yml"           , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def VERSION = '1.0' // WARN: Python script with no version control. This would be v1.0 of this script. 
    """
    sm_genome2species.py \\
        --sm_csv $gather_result_csv \\
        --metadata $metadata_file  \\
        --output ${prefix}_sm_species.tsv  \\
        $args

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        postproc: $VERSION
    END_VERSIONS
    """

    stub:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def VERSION = '1.0'
    """
    touch ${prefix}_sm_species.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        postproc: $VERSION
    END_VERSIONS
    """
}
