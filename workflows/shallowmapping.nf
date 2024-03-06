include { validateParameters; paramsHelp; paramsSummaryLog; fromSamplesheet; paramsSummaryMap } from 'plugin/nf-validation'

def summary_params = paramsSummaryMap(workflow)

validateParameters()

log.info paramsSummaryLog(workflow)

if (params.help) {
   log.info paramsHelp("nextflow run ebi-metagenomics-shallowmapping --help")
   exit 0
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

ch_multiqc_config          = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config   = params.multiqc_config ? Channel.fromPath( params.multiqc_config, checkIfExists: true ) : Channel.empty()
ch_multiqc_logo            = params.multiqc_logo   ? Channel.fromPath( params.multiqc_logo, checkIfExists: true ) : Channel.empty()
ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Preprocessing modules
include { FASTQC                      } from '../modules/nf-core/fastqc/main'
include { MULTIQC                     } from '../modules/nf-core/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/custom/dumpsoftwareversions/main'
include { FASTP                       } from '../modules/local/fastp/main'

// Mapping modules
include { SOURMASH_GATHER             } from '../modules/nf-core/sourmash/gather/main'
include { SOURMASH_SKETCH             } from '../modules/nf-core/sourmash/sketch/main'
include { POSTPROC_SOURMASHTAXO       } from '../modules/local/postproc/sourmashtaxo'
include { POSTPROC_FUNCTIONSPRED      } from '../modules/local/postproc/functionspred'

include { BWAMEM2_MEM                 } from '../modules/nf-core/bwamem2/mem/main'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
q
include { READS_BWAMEM2_DECONTAMINATION as PHIX_DECONT  } from '../subworkflows/ebi-metagenomics/reads_bwamem2_decontamination/main'
include { READS_BWAMEM2_DECONTAMINATION as HUMAN_DECONT } from '../subworkflows/ebi-metagenomics/reads_bwamem2_decontamination/main'
include { READS_BWAMEM2_DECONTAMINATION as HOST_DECONT  } from '../subworkflows/ebi-metagenomics/reads_bwamem2_decontamination/main'


/////////////////////////////////////////////////////
/* --  Create channels for reference databases  -- */
/////////////////////////////////////////////////////

//ch_sourmash_db              = file(params.sourmash_db)
//ch_bwa_db                   = file(params.bwa_db)                 
//ch_pangenome_db             = file(params.pangenome_db)

//ch_host_ref_genome          = file(params.host_ref)
//ch_human_ref_genome         = file(params.human_ref)


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def multiqc_report = []

workflow SHALLOWMAPPING {

    ch_versions      = Channel.empty()
    ch_log           = Channel.empty()
    ch_multiqc_files = Channel.empty()


    // ---- Combine data into the reads channel ---- //
    groupReads = { list ->
        def meta = [id: list[0]]
        def reads = list[1..-1]
        if (reads.size() == 1) {
            return tuple(meta + [single_end: true], reads)
        }
        else {
            return tuple(meta + [single_end: false], reads)
        }
    }
    ch_reads = Channel.fromSamplesheet("input").map(groupReads) // [ meta, [raw_reads] ]



    // ---- PREPROCESSING: reads QC, trimming and decontamination ---- //
    FASTQC ( ch_reads )
    ch_versions = ch_versions.mix(FASTQC.out.versions.first())

    FASTP ( ch_reads )
    ch_versions = ch_versions.mix(FASTP.out.versions.first())


    // Creating channel for decontamination with phix
    phix_ref = Channel.fromPath("$params.reference_genomes_folder/phiX174*", checkIfExists: true).collect().map { db_files ->
        [ [id: 'phiX174'], db_files ]
    }
    PHIX_DECONT ( FASTP.out.reads, phix_ref )
    ch_versions = ch_versions.mix(PHIX_DECONT.out.versions.first())

    // Creating channel for decontamination with human
    human_ref = Channel.fromPath("$params.reference_genomes_folder/hg38*", checkIfExists: true).collect().map { db_files ->
        [ [id: 'hg38'], db_files ]
    }
    HUMAN_DECONT ( PHIX_DECONT.out.decontaminated_reads, human_ref )
    ch_versions = ch_versions.mix(HUMAN_DECONT.out.versions.first())

    // Creating channel for decontamination with host when biome != human
    def host_name = params.biome.split('-')[0]
    if ('human' in params.biome) {
        decont_reads = HUMAN_DECONT.out.decontaminated_reads
    } else {
        host_ref = Channel.fromPath("$params.reference_genomes_folder/$host_name.*", checkIfExists: true).collect().map { db_files ->
        [ [id: host_name], db_files ]
        }
        HOST_DECONT( HUMAN_DECONT.out.decontaminated_reads, host_ref )
        decont_reads = HOST_DECONT.out.decontaminated_reads
        ch_versions = ch_versions.mix(HOST_DECONT.out.versions.first())
    }


    // ---- MAPPING READS with sourmash: sketch decont reads, mapping, and profiling ---- //
    // Sketching decontaminated reads and running mapping
    SOURMASH_SKETCH( decont_reads )
    ch_versions = ch_versions.mix(SOURMASH_SKETCH.out.versions.first())

    SOURMASH_GATHER( SOURMASH_SKETCH.out.signatures, params.sourmash_db, false, false, false, false )
    ch_versions = ch_versions.mix(SOURMASH_GATHER.out.versions.first())

    // Processing sourmash mapping output: generating taxonomic and functional profiles
    POSTPROC_SOURMASHTAXO( SOURMASH_GATHER.out.result, "$params.prefix_path/genomes-all_metadata.tsv" )
    ch_versions = ch_versions.mix(POSTPROC_SOURMASHTAXO.out.versions.first())    

    POSTPROC_FUNCTIONSPRED( POSTPROC_SOURMASHTAXO.out.sm_taxo, params.pangenome_db, 'sm' )
    ch_versions = ch_versions.mix(POSTPROC_FUNCTIONSPRED.out.versions.first())


    // ---- MAPPING READS with bwamem2: mapping, cleaning output, and profiling ---- //
    if (params.run_bwa) {
        genomes_ref = Channel.fromPath("$params.bwa_db*", checkIfExists: true).collect().map { db_files ->
        [ [id: host_name ], db_files ]
        }
        BWAMEM2_MEM( decont_reads, genomes_ref, true )        
        ch_versions = ch_versions.mix(BWAMEM2_MEM.out.versions.first())


    }


    // ---- Multiqc report ---- //

    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    workflow_summary    = WorkflowShallowmapping.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    methods_description    = WorkflowShallowmapping.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description, params)
    ch_methods_description = Channel.value(methods_description)

    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{it[1]}.ifEmpty([]))

    ch_multiqc_files = ch_multiqc_files.mix( FASTP.out.json )

    //MULTIQC (
    //    ch_multiqc_files.collect(),
    //    ch_multiqc_config.toList(),
    //    ch_multiqc_custom_config.toList(),
    //    ch_multiqc_logo.toList()
    //)
    //multiqc_report = MULTIQC.out.report.toList()

}

