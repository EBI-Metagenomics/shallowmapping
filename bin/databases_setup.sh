#!/bin/bash

# Define the list of valid biomes
valid_biomes=('chicken-gut-v1-0-1' 'mouse-gut-v1-0' 'non-model-fish-gut-v2-0' 'human-vaginal-v1-0' 'honeybee-gut-v1-0-1' 
              'sheep-rumen-v1-0' 'marine-v2-0' 'zebrafish-fecal-v1-0' 'human-oral-v1-0-1' 'pig-gut-v1-0' 
              'cow-rumen-v1-0-1' 'human-gut-v2-0-2')

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --biome)
            BIOME="$2"
            # Check if the provided biome is in the valid biomes list
            if [[ ! " ${valid_biomes[@]} " =~ " ${BIOME} " ]]; then
                echo "The input $BIOME is not a valid biome, please use one of the following: ${valid_biomes[*]}"
                exit 1
            fi
            shift
            shift
            ;;                        
        --catalogue_dbs_path)
            CATALOGUE_DBS_PATH="$2"
            shift
            shift
            ;;
        --decont_refs_path)
            DECONT_REFS_PATH="$2"
            shift
            shift
            ;;
        --download_bwa)
            DOWNLOAD_BWA="$2"
            shift
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Create verbose log file
LOG_FILE="dbs_setup_$(date +'%Y%m%d_%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Change directory to decontamination references path
cd "$DECONT_REFS_PATH" || exit
if [ ! -d "reference_genomes" ]; then
    echo " ***  Creating the reference_genomes directory in $DECONT_REFS_PATH"
    mkdir reference_genomes && cd reference_genomes || exit
else
    echo " ***  The reference_genomes directory already exists in $DECONT_REFS_PATH"
    cd reference_genomes || exit
fi


# Check if human_phix.fa.* files exist
if ls human_phix.fa.* &>/dev/null; then
    echo " ***  The human and phiX reference genomes already exist. Skipping download"
else
    # Downloading human+phiX reference genomes
    echo " ***  Downloading the human and phiX reference genomes to ${DECONT_REFS_PATH}reference_genomes"
    wget --continue https://ftp.ebi.ac.uk/pub/databases/metagenomics/pipelines/references/human_phiX/human_phix_ref_bwamem2.tar.gz
    echo " ***  Extracting human and phiX reference genomes"
    tar -xvf human_phix_ref_bwamem2.tar.gz
    mv bwamem2/* .
    rm -r bwamem2 human_phix_ref_bwamem2.tar.gz
fi

# Check if $HOST.* files exist
HOST=$(echo "$BIOME" | cut -d '-' -f1)
if ls ${HOST}.* &>/dev/null; then
    echo " ***  The $HOST reference genome already exist. Skipping download"
else
    # Downloading the host genome
    echo " ***  Downloading the $HOST reference genome to $DECONT_REFS_PATH/reference_genomes"
    wget --continue "https://ftp.ebi.ac.uk/pub/databases/metagenomics/pipelines/references/$HOST/${HOST}_ref_bwamem2.tar.gz"
    echo " ***  Extracting the $HOST reference genome"
    tar -xvf "${HOST}_ref_bwamem2.tar.gz"
    mv bwamem2/* .
    rm -r bwamem2 "${HOST}_ref_bwamem2.tar.gz"
fi

# Downloading the catalogue-related files
cd "$CATALOGUE_DBS_PATH" || exit
if [ -d "$BIOME" ]; then
    echo " ***  A directory for the catalogue $BIOME already exists. Please remove the current directory to re-download. Exiting..."
    exit 1
else
    echo " ***  Creating $BIOME directory in $CATALOGUE_DBS_PATH"
    mkdir "$BIOME" && cd "$BIOME" || exit
fi

NEW_BIOME=$(echo $BIOME | sed 's/-vaginal-/-tmp-/;s/-v/|/;s/-tmp-/-vaginal-/' )
PREFIX_BIOME=$(echo "$NEW_BIOME" | cut -d '|' -f1)
VERSION=$(echo "$NEW_BIOME" | cut -d '|' -f2)
CAT_VERSION=$(echo "v$VERSION" | sed 's/-/./g' )

echo " ***  Downloading catalogue related databases to ${CATALOGUE_DBS_PATH}/${BIOME}"

# Downloading the catalogue metadata file
wget --continue "https://ftp.ebi.ac.uk/pub/databases/metagenomics/mgnify_genomes/$PREFIX_BIOME/$CAT_VERSION/genomes-all_metadata.tsv"

# Setting up the files location in ftp
TABLES_DIR="https://ftp.ebi.ac.uk/pub/databases/metagenomics/pipelines/references/mgnify_genomes/${PREFIX_BIOME}_reps"
FUNCTIONS_DIR="$TABLES_DIR/${PREFIX_BIOME}_v${VERSION}_functions"
SOURMASH_DIR="$TABLES_DIR/${PREFIX_BIOME}_v${VERSION}_sourmash"
BWAMEM_DIR="$TABLES_DIR/${PREFIX_BIOME}_v${VERSION}_bwamem2.tar.gz"

# Downloading the pangenome function tables
wget --continue "$FUNCTIONS_DIR/functional_profiles.tar.gz"
tar -xvf functional_profiles.tar.gz
rm functional_profiles.tar.gz

wget --continue "$FUNCTIONS_DIR/kegg_completeness.tar.gz"
tar -xvf kegg_completeness.tar.gz
rm kegg_completeness.tar.gz

# Downloading the representative genomes indexed for sourmash
wget --continue "$SOURMASH_DIR/sourmash_species_representatives_k21.sbt.zip"

# Downloading bwamem2 db index if the option is set
if [ "$DOWNLOAD_BWA" = "true" ]; then
    echo " ***  Downloading bwamem2 indexed database for $BIOME to ${CATALOGUE_DBS_PATH}/${BIOME}"
    wget --continue "$BWAMEM_DIR"
    tar -xvf "${PREFIX_BIOME}_${VERSION}_bwamem2.tar.gz"
    mv "${PREFIX_BIOME}_${VERSION}_bwamem2"/* .
    rm -r "${PREFIX_BIOME}_${VERSION}_bwamem2" "${PREFIX_BIOME}_${VERSION}_bwamem2.tar.gz"
else
    echo " ***  Skipping download of bwamem2 indexed database for $BIOME"
    echo "      Note you will not be able to use --run_bwa true option on shallow-mapping pipeline for this biome"
fi

# Downloading external databases for dram visualization
cd "$CATALOGUE_DBS_PATH" || exit
if [ -d "external_dbs" ]; then
    echo " ***  Skipping external dbs downloading. The directory external_dbs already exists in $CATALOGUE_DBS_PATH"
else
    echo " ***  Downloading external dbs to $CATALOGUE_DBS_PATH/external_dbs/dram_distill_dbs"
    mkdir -p external_dbs/dram_distill_dbs && cd external_dbs/dram_distill_dbs || exit
    wget --continue "https://raw.githubusercontent.com/WrightonLabCSU/DRAM/v1.5.0/data/amg_database.tsv"
    wget --continue "https://raw.githubusercontent.com/WrightonLabCSU/DRAM/v1.5.0/data/etc_module_database.tsv"
    wget --continue "https://raw.githubusercontent.com/WrightonLabCSU/DRAM/v1.5.0/data/function_heatmap_form.tsv"
    wget --continue "https://raw.githubusercontent.com/WrightonLabCSU/DRAM/v1.5.0/data/genome_summary_form.tsv"
    wget --continue "https://raw.githubusercontent.com/WrightonLabCSU/DRAM/v1.5.0/data/module_step_form.tsv"
    wget --continue "https://ftp.ebi.ac.uk/pub/databases/Pfam/current_release/Pfam-A.hmm.dat.gz"
fi

# Creating the CONFIG file for DRAM distill
echo " ***  Creating the CONFIG file for DRAM distill"
echo '{"description_db": "None", "kegg": null, "kofam": null, "kofam_ko_list": null, "uniref": null, "pfam": null, "pfam_hmm_dat": null, "dbcan": null, "dbcan_fam_activities": null, "viral": null, "peptidase": null, "vogdb": null, "vog_annotations": null, "genome_summary_form": "/data/genome_summary_form.tsv", "module_step_form": "/data/module_step_form.tsv", "etc_module_database": "/data/etc_module_database.tsv", "function_heatmap_form": "/data/function_heatmap_form.tsv", "amg_database": "/data/amg_database.tsv"}' > CONFIG


echo " ***  Databases setting up finished successfully for $BIOME"
echo " ***  Use the following parameters to test the shallow-mapping pipeline from shallowmapping/test:"
echo "      nextflow run ../main.nf \\"
echo "          --biome $BIOME \\"
echo "          --input test_samplesheet.csv \\"
echo "          --outdir test_output \\"
echo "          --shallow_dbs_path $CATALOGUE_DBS_PATH \\"
echo "          --decont_reference_paths ${DECONT_REFS_PATH}reference_genomes"
