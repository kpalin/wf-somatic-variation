#!/usr/bin/env python
"""Check BAM header and return genome build based on chromosome sizes."""

import argparse
import os
import sys


CHROMOSOME_SIZES = {
    'hg19': {
        'chr1': '249250621',
        'chr2': '243199373',
        'chr3': '198022430',
        'chr4': '191154276',
        'chr5': '180915260',
        'chr6': '171115067',
        'chr7': '159138663',
        'chr8': '146364022',
        'chr9': '141213431',
        'chr10': '135534747',
        'chr11': '135006516',
        'chr12': '133851895',
        'chr13': '115169878',
        'chr14': '107349540',
        'chr15': '102531392',
        'chr16': '90354753',
        'chr17': '81195210',
        'chr18': '78077248',
        'chr19': '59128983',
        'chr20': '63025520',
        'chr21': '48129895',
        'chr22': '51304566',
        'chrX': '155270560',
        'chrY': '59373566'},
    'hg38': {
        'chr1': '248956422',
        'chr2': '242193529',
        'chr3': '198295559',
        'chr4': '190214555',
        'chr5': '181538259',
        'chr6': '170805979',
        'chr7': '159345973',
        'chr8': '145138636',
        'chr9': '138394717',
        'chr10': '133797422',
        'chr11': '135086622',
        'chr12': '133275309',
        'chr13': '114364328',
        'chr14': '107043718',
        'chr15': '101991189',
        'chr16': '90338345',
        'chr17': '83257441',
        'chr18': '80373285',
        'chr19': '58617616',
        'chr20': '64444167',
        'chr21': '46709983',
        'chr22': '50818468',
        'chrX': '156040895',
        'chrY': '57227415'},
    'chm13v2': {
        "chr1": "248387328",
        "chr2": "242696752",
        "chr3": "201105948",
        "chr4": "193574945",
        "chr5": "182045439",
        "chr6": "172126628",
        "chr7": "160567428",
        "chr8": "146259331",
        "chr9": "150617247",
        "chr10": "134758134",
        "chr11": "135127769",
        "chr12": "133324548",
        "chr13": "113566686",
        "chr14": "101161492",
        "chr15": "99753195",
        "chr16": "96330374",
        "chr17": "84276897",
        "chr18": "80542538",
        "chr19": "61707364",
        "chr20": "66210255",
        "chr21": "45090682",
        "chr22": "51324926",
        "chrX": "154259566",
        "chrY": "62460029"}
}


ALLOWED_CHR = [
    "chr1", "chr2", "chr3", "chr4", "chr5", "chr6", "chr7", "chr8", "chr9",
    "chr10", "chr11", "chr12", "chr13", "chr14", "chr15", "chr16", "chr17",
    "chr18", "chr19", "chr20", "chr21", "chr22", "chrX", "chrY"
]


def chromosome_sizes(extracted_sizes):
    """Get dictionary of chromosomes and sizes from samtools index."""
    fasta_sizes = {}
    with open(extracted_sizes, 'r') as fa_idx:
        for line in fa_idx:
            line = line.rstrip()
            cols = line.split('\t')
            # prepend 'chr' if needed
            if not cols[0].startswith('chr'):
                cols[0] = "chr"+cols[0]
            if cols[0] in ALLOWED_CHR:
                fasta_sizes[cols[0]] = cols[1]

    return fasta_sizes


def get_genome(sizes):
    """Get genome based on chromosome sizes."""
    if not sizes:
        return ""
    for known_genome_build in CHROMOSOME_SIZES.keys():
        if sizes.items() <= CHROMOSOME_SIZES[known_genome_build].items():
            return known_genome_build
    return ""


def check_genome(genome_build, workflow):
    """Determine if genome is suitable for this workflow."""
    bad_genome = False
    extra_msg_context = ""
    if not genome_build:
        bad_genome = True
    elif workflow == "str" and genome_build != "hg38":
        bad_genome = True
        extra_msg_context = (
            f"Detected genome: {genome_build}, but STRs can only be genotyped "
            "when aligned to build 38.\n")
    return (bad_genome, extra_msg_context)


def main():
    """Run entry point."""
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--chr_counts', required=True, dest="chr_counts",
        help="Output from samtools faidx")
    parser.add_argument(
        '-o', '--output', required=True, dest="output",
        help="Output genome")
    parser.add_argument(
        '-w', '--workflow', dest="workflow",
        help="Subworkflow name")
    args = parser.parse_args()

    all_sizes = chromosome_sizes(args.chr_counts)

    genome_build = get_genome(all_sizes)
    bad_genome, extra_msg_context = check_genome(genome_build, args.workflow)

    # explode on bad genome
    if bad_genome:
        sys.stderr.write(
            "The genome build detected in the BAM is not compatible with "
            "this workflow.\n")
        sys.stderr.write(extra_msg_context)
        sys.exit(os.EX_DATAERR)

    # otherwise write out the genome name
    result = open(args.output, 'w')
    result.write(genome_build)


if __name__ == '__main__':
    main()
