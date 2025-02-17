import groovy.json.JsonBuilder

process getVersions {
    label "wf_somatic_methyl"
    cpus 1
    output:
        path "versions.txt"
    script:
    """
    python --version | tr -s ' ' ',' | tr '[:upper:]' '[:lower:]' > versions.txt
    modkit --version | tr -s ' ' ',' >> versions.txt
    bgzip --version | awk 'NR==1 {print \$1","\$3}' >> versions.txt
    """
}


process rVersions {
    label "dss"
    cpus 1
    input:
        path "versions.txt"
    output:
        path "versions.txt"
    script:
    """
    R --version | awk 'NR==1 {print "R,"\$3}' >> versions.txt
    R -e "packageVersion('DSS')" | awk '\$1=="[1]" {print "DSS,"\$2}' >> versions.txt
    """
}


process getParams {
    cpus 1
    output:
        path "params.json"
    script:
        def paramsJSON = new JsonBuilder(params).toPrettyString()
    """
    # Output nextflow params object to JSON
    echo '$paramsJSON' > params.json
    """
}


process validate_modbam {
    label "wf_somatic_methyl"
    input:
        tuple path(alignment), 
            path(alignment_index), 
            val(meta), 
            path(reference), 
            path(reference_index), 
            path(reference_cache)
    output:
        tuple path(alignment), 
            path(alignment_index), 
            val(meta), 
            path(reference), 
            path(reference_index), 
            path(reference_cache),
            env(valid)

    script:
    """
    export REF_PATH="${reference_cache}/%2s/%2s/%s:"
    valid=0
    workflow-glue check_valid_modbam ${alignment} || valid=\$?

    # Allow EX_OK and EX_DATAERR, otherwise explode
    if [ \$valid -ne 0 ] && [ \$valid -ne 65 ]; then
        exit 1
    fi
    """
}


process modkit {
    label "wf_somatic_methyl"
    cpus params.modkit_threads
    input:
        tuple path(alignment), 
            path(alignment_index), 
            val(meta), 
            path(reference), 
            path(reference_index), 
            path(reference_cache),
            path(bed)
    output:
        tuple val(meta), 
            val('all'),
            path("${meta.sample}_${meta.type}.bed.gz"), 
            emit: full_output

    script:
    def ref_path = "${reference_cache}/%2s/%2s/%s:" + System.getenv("REF_PATH")
    def options = params.force_strand ? '':'--combine-strands --cpg'
    if (params.modkit_args){
        options = "${params.modkit_args}"
    }
    """
    export REF_PATH=${ref_path}
    modkit pileup \\
        ${alignment} \\
        ${meta.sample}_${meta.type}.bed \\
        --ref ${reference} \\
        --threads ${task.cpus} ${options}
    bgzip ${meta.sample}_${meta.type}.bed
    """
}


process bedmethyl_split {
    label "wf_somatic_methyl"
    cpus 1
    input:
        tuple val(meta), 
            val('all'),
            path(bed)
    output:
        tuple val(meta), 
            path("*.${meta.sample}_${meta.type}.bed.gz"), 
            emit: mod_outputs

    script:
    """
    workflow-glue mod_split ${bed}
    for i in `ls *.bed`; do
        bgzip \$i
    done
    """
}


process summary {
    label "wf_somatic_methyl"
    cpus 4
    input:
        tuple path(alignment), 
            path(alignment_index), 
            val(meta),
            path(reference), 
            path(reference_index), 
            path(reference_cache)
    output:
        tuple val(meta), 
            path("${meta.sample}.${meta.type}.mod_summary.tsv"), 
            emit: mod_summary

    script:
    def ref_path = "${reference_cache}/%2s/%2s/%s:" + System.getenv("REF_PATH")
    // Modkit summary prints out a progress bar that cannot be avoided
    """    
    export REF_PATH=${ref_path}
    modkit summary -t ${task.cpus} ${alignment} | \
        awk 'BEGIN{OFS="\t"}; {print \$1,\$2,\$3,\$4,\$5,\$6}' > ${meta.sample}.${meta.type}.mod_summary.tsv
    """
}

// Convert to DSS
process bed2dss {
    label "wf_somatic_methyl"
    cpus 1
    input:
        tuple val(meta), 
            val(mod),
            path("modified.bed.gz")

    output:
        tuple val(meta), 
            val(mod),
            path("*.${meta.sample}_${meta.type}.dss.tsv"), 
            emit: dss_outputs

    shell:
    '''
    zcat modified.bed.gz | awk -v OFS='\t' 'BEGIN{{print "chr","pos","N","X"}}{{print $1,$2,$10,$12}}' > !{mod}.!{meta.sample}_!{meta.type}.dss.tsv
    '''
}

// Run DSS to compute DMR/L
process dss {
    label "dss"
    cpus params.dss_threads
    input:
        tuple val(meta), 
            val(mod),
            path("normal.bed"),
            path("tumor.bed")

    output:
        tuple val(meta), 
            val(mod),
            path("${meta.sample}.${mod}.dml.tsv"), 
            emit: dml
        tuple val(meta), 
            val(mod),
            path("${meta.sample}.${mod}.dmr.tsv"), 
            emit: dmr

    script:
    """
    #!/usr/bin/env Rscript
    library(DSS)
    require(bsseq)
    require(data.table)
    # Disable scientific notation
    options(scipen=999)

    # Import data
    tumor = fread("tumor.bed", sep = '\t', header = T)
    normal = fread("normal.bed", sep = '\t', header = T)
    # Create BSobject
    BSobj = makeBSseqData( list(tumor, normal),
        c("Tumor", "Normal") )
    # DML testing
    dmlTest = DMLtest(BSobj, 
        group1=c("Tumor"), 
        group2=c("Normal"),
        equal.disp = FALSE,
        smoothing=TRUE,
        smoothing.span=500,
        ncores=${task.cpus})
    # Compute DMLs
    dmls = callDML(dmlTest,
        delta=0.25,
        p.threshold=0.001)
    # Compute DMRs
    dmrs = callDMR(dmlTest,
        delta=0.25,
        p.threshold=0.001,
        minlen=100,
        minCG=5,
        dis.merge=1500,
        pct.sig=0.5)
    # Write output files
    write.table(dmls, '${meta.sample}.${mod}.dml.tsv', sep='\\t', quote=F, col.names=T, row.names=F)
    write.table(dmrs, '${meta.sample}.${mod}.dmr.tsv', sep='\\t', quote=F, col.names=T, row.names=F)
    """
}


process makeModReport {
    input: 
        tuple val(meta), 
            path("normal_summary/*"),
            path("tumor_summary/*"),
            path("DML/*"),
            path("DMR/*"),
            path("ref.fa.fai"),
            path("versions.txt"),
            path("params.json")

    output:
        tuple val(meta), path("${meta.sample}.wf-somatic-mod-report.html")

    script:
        def genome = meta.genome_build ? "--genome ${meta.genome_build} " : ""
        """
        workflow-glue report_mod \\
            ${meta.sample}.wf-somatic-mod-report.html \\
            --normal_summary normal_summary/ \\
            --tumor_summary tumor_summary/ \\
            --dml DML/ \\
            --dmr DMR/ \\
            --reference_fai ref.fa.fai \\
            --sample_name ${meta.sample} \\
            --versions versions.txt \\
            --params params.json ${genome}
        """
}


process output_modbase {
    // publish inputs to output directory
    label "wf_somatic_methyl"
    publishDir (
        params.out_dir,
        mode: "copy",
        saveAs: { dirname ? "$dirname/$fname" : fname }
    )
    input:
        tuple path(fname), val(dirname)
    output:
        path fname
    """
    """
}

workflow mod {
    take:
        alignment
        reference
    main:
        // Check for conflicting parameters
        if (params.force_strand && params.modkit_args){
            throw new Exception(colors.red + "You cannot use --force_strand with --modkit_args." + colors.reset)
        }
        if (params.modkit_args){
            log.warn "--modkit_args will override any preset we defined."
        }

        // Call modified bases
        alignment.combine( reference ) | validate_modbam

        // Warn of invalid bam files
        validate_modbam.out.branch{
            stdbam: it[-1] == '65'
            modbam: it[-1] == '0'
            }.set{validated_bam}
        validated_bam.stdbam.subscribe{
            it -> log.warn "Input ${it[1]} is not a modified bam file."
        }

        // Define input bed, if provided
        if (params.bed){
            bed = Channel.fromPath(params.bed)
        } else {
            bed = Channel.fromPath("$projectDir/data/OPTIONAL_FILE")
        }

        // Run modkit on the valid files.
        modkit(validated_bam.modbam.map{it[0..-2]}.combine(bed))

        // Split modkit, and use file to rename the outputs
        bedmethyl_split(modkit.out.full_output)
        // Each channel has a nested tuple. Transpose linearize it,
        // and then we extract the modification type with simpleName.
        modbed = bedmethyl_split.out.mod_outputs
            .transpose()
            .map{ meta, tsv -> 
                [meta, tsv.simpleName, tsv]
            }

        // Compute summary stats
        alignment.combine( reference ) | summary

        // Convert to DSS
        modbed | bed2dss
        
        // Combine the outputs to perform DMR analyses
        bed2dss.out.dss_outputs.branch{
            tumor: it[0].type == 'tumor'
            normal: it[0].type == 'normal'
        }.set{forked_mb}

        // Output methylation data
        forked_mb.normal
            .map{it -> [it[0].sample, it[1], it[2], it[0]]}
            .combine(
                forked_mb.tumor.map{it -> [it[0].sample, it[1], it[2], it[0]]}, 
                by:[0,1]
            )
            .map{sample, mod, norm_bed, norm_meta, tum_bed, tum_meta -> [tum_meta, mod, norm_bed, tum_bed ] }
            .set{ paired_beds }
        paired_beds | dss 

        // Get versions and params
        software_versions = getVersions() | rVersions
        workflow_params = getParams()

        // Make report
        summary.out.mod_summary.branch{
            tumor: it[0].type == 'tumor'
            normal: it[0].type == 'normal'
        }.set{forked_sum}
        forked_sum.normal
            .map{meta, summary -> [meta.sample, summary, meta]}
            .combine(
                forked_sum.tumor.map{meta, summary -> [meta.sample, summary, meta]}, 
                by:0
            )
            .map{sample, norm_summary, norm_meta, tum_summary, tum_meta -> [tum_meta, norm_summary, tum_summary ] }
            .set{combined_summaries}
        dss.out.dml
            .combine(dss.out.dmr, by: [0,1])
            .groupTuple(by:0)
            .combine(combined_summaries, by: 0)
            .combine(reference)
            .map{
                meta, mod, dms, dmr, sum_n, sum_t, ref, fai, cache -> 
                [meta, sum_n, sum_t, dms, dmr, fai]
            }
            .combine(software_versions)
            .combine(workflow_params)
            .set{ for_report }
        makeModReport(for_report)

        // Create output directory
        modbed.map{
            meta, mod, file -> [file, "${meta.sample}/mod/${mod}/bedMethyl/"]
        }.mix(
            modkit.out.full_output.map{
                meta, mod, file -> [file, "${meta.sample}/mod/raw/"]
            }
        ).mix(
            bed2dss.out.dss_outputs.map{
                meta, mod, file -> [file, "${meta.sample}/mod/${mod}/DSS/"]
            }
        ).mix(
            summary.out.mod_summary.map{
                meta, summary -> [summary, null]
            }
        ).mix(
            dss.out.dml.map{
                meta, mod, file -> [file, "${meta.sample}/mod/${mod}/DML"]
            }
        ).mix(
            dss.out.dmr.map{
                meta, mod, file -> [file, "${meta.sample}/mod/${mod}/DMR"]
            }
        ) 
        .mix(
            workflow_params.map{
                params -> [params, "info/mod/"]
            }
        ).mix(
            software_versions.map{
                versions -> [versions, "info/mod/"]
            }
        ).mix(
            makeModReport.out.map{
                meta, report -> [report, null]
            }
        ) | output_modbase

    emit:
        modbam2bed = bedmethyl_split.out.mod_outputs
        dss = bed2dss.out.dss_outputs
}
