#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(optparse))
suppressPackageStartupMessages(library(ggplot2))

option_list <- list(
  make_option(c("-o","--output"), type="character",
              help="output filename prefix [input.paf]", 
              dest="output_filename"),
  make_option(c("-p","--plot-size"), type="numeric", default=15,
              help="plot size X inches [%default]",
              dest="plot_size"),
  make_option(c("-f","--flip"), action="store_true", default=FALSE,
              help="flip query if most alignments are in reverse complement [%default]",
              dest="flip"),
  make_option(c("-q", "--min-query-length"), type="numeric", default=400000,
              help="filter queries with total alignments less than cutoff X bp [%default]",
              dest="min_query_aln"),
  make_option(c("-m", "--min-alignment-length"), type="numeric", default=10000,
              help="filter alignments less than cutoff X bp [%default]",
              dest="min_align"),
  make_option(c("-r", "--min-ref-len"), type="numeric", default=1000000,
              help="filter references with length less than cutoff X bp [%default]",
              dest="min_ref_len"),
  make_option(c("-i", "--reference-ids"), type="character", default=NULL,
              help="comma-separated list of reference IDs to keep and order [%default]",
              dest="refIDs")
)

options(error=traceback)
parser <- OptionParser(usage = "%prog [options] input.paf", option_list = option_list)
opts = parse_args(parser, positional_arguments = c(0, 1))
opt = opts$options
input_file = opts$args
if(length(input_file) <= 0){
  cat(sprintf("Error: missing input file: input.paf!\n\n"))
  print_help(parser)
  quit()
}else if (file.access(input_file, mode=4) == -1){
  cat(sprintf("Error: input file: %s does not exist or cannot be read!\n\n", input_file))
  print_help(parser)
  quit()
}
if(is.null(opt$output_filename)){
  opt$output_filename = input_file
}

# read in alignments
alignments = read.table(input_file, stringsAsFactors = F, fill = T)
alignments = alignments[, seq(1, 12)]
# set column names
# PAF IS ZERO-BASED - CHECK HOW CODE WORKS
colnames(alignments)[1:12] = c("queryID","queryLen","queryStart","queryEnd","strand","refID","refLen","refStart","refEnd","numResidueMatches","lenAln","mapQ")

# caculate similarity
alignments$percentID = alignments$numResidueMatches / alignments$lenAln
queryStartTemp = alignments$queryStart
# Flip starts, ends for negative strand alignments
alignments$queryStart[which(alignments$strand == "-")] = alignments$queryEnd[which(alignments$strand == "-")]
alignments$queryEnd[which(alignments$strand == "-")] = queryStartTemp[which(alignments$strand == "-")]
rm(queryStartTemp)

cat(paste0("\nNumber of alignments: ", nrow(alignments), "\n"))
cat(paste0("Number of query sequences: ", length(unique(alignments$queryID)), "\n"))

# sort by ref chromosome sizes, keep top X chromosomes OR keep specified IDs
if(is.null(opt$refIDs)){
  chromMax = tapply(alignments$refLen, alignments$refID, max)
  refIDsToKeepOrdered = names(sort(chromMax, decreasing = T))
}else{
  refIDsToKeepOrdered = unlist(strsplit(opt$refIDs, ","))
  alignments = alignments[which(alignments$refID %in% refIDsToKeepOrdered),]
}

# filter queries by alignment length, for now include overlapping intervals
queryLenAgg = tapply(alignments$lenAln, alignments$queryID, sum)
alignments = alignments[which(alignments$queryID %in% names(queryLenAgg)[which(queryLenAgg > opt$min_query_aln)]),]
# filter alignment by length
alignments = alignments[which(alignments$lenAln > opt$min_align),]
# filter alignment by ref length
alignments = alignments[which(alignments$refLen > opt$min_ref_len),]
# re-filter queries by alignment length, for now include overlapping intervals
queryLenAgg = tapply(alignments$lenAln, alignments$queryID, sum)
alignments = alignments[which(alignments$queryID %in% names(queryLenAgg)[which(queryLenAgg > opt$min_query_aln)]),]

cat(paste0("\nAfter filtering... Number of alignments: ", nrow(alignments),"\n"))
cat(paste0("After filtering... Number of query sequences: ", length(unique(alignments$queryID)),"\n\n"))
# sort df on ref
alignments$refID = factor(alignments$refID, levels = refIDsToKeepOrdered) # set order of refID
alignments = alignments[with(alignments,order(refID,refStart)),]
chromMax = tapply(alignments$refLen, alignments$refID, max)
# make new ref alignments for dot plot

alignments$refStart2 = alignments$refStart + sapply(as.character(alignments$refID), function(x) ifelse(x == names(chromMax)[1], 0, cumsum(as.numeric(chromMax))[match(x, names(chromMax)) - 1]) )
alignments$refEnd2 = alignments$refEnd + sapply(as.character(alignments$refID), function(x) ifelse(x == names(chromMax)[1], 0, cumsum(as.numeric(chromMax))[match(x, names(chromMax)) - 1]) )

## queryID sorting step 1/2
# sort levels of factor 'queryID' based on longest alignment
alignments$queryID = factor(alignments$queryID, levels=unique(as.character(alignments$queryID)))
queryMaxAlnIndex = tapply(alignments$lenAln, alignments$queryID, which.max, simplify = F)
alignments$queryID = factor(alignments$queryID, levels = unique(as.character(alignments$queryID))[order(mapply(
  function(x, i)
    alignments$refStart2[which(i == alignments$queryID)][x],
  queryMaxAlnIndex,
  names(queryMaxAlnIndex)
))])

## queryID sorting step 2/2
## sort levels of factor 'queryID' based on longest aggregrate alignmentst to refID's
# per query ID, get aggregrate alignment length to each refID 
queryLenAggPerRef = sapply((levels(alignments$queryID)), function(x) tapply(alignments$lenAln[which(alignments$queryID == x)], alignments$refID[which(alignments$queryID == x)], sum) )
if(length(levels(alignments$refID)) > 1){
  queryID_Ref = apply(queryLenAggPerRef, 2, function(x) rownames(queryLenAggPerRef)[which.max(x)])
} else {
  queryID_Ref = sapply(queryLenAggPerRef, function(x) names(queryLenAggPerRef)[which.max(x)])
}
# set order for queryID
alignments$queryID = factor(alignments$queryID, levels = (levels(alignments$queryID))[order(match(queryID_Ref, levels(alignments$refID)))])
queryMax = tapply(alignments$queryLen, alignments$queryID, max)

if(opt$flip){
  #  flip query starts stops to forward if most align are in reverse complement
  queryRevComp = tapply(alignments$queryEnd - alignments$queryStart, alignments$queryID, function(x) sum(x)) < 0
  queryRevComp = names(queryRevComp)[which(queryRevComp)]
  alignments$queryStart[which(alignments$queryID %in% queryRevComp)] = queryMax[match(as.character(alignments$queryID[which(alignments$queryID %in% queryRevComp)]), names(queryMax))] - alignments$queryStart[which(alignments$queryID %in% queryRevComp)] + 1
  alignments$queryEnd[which(alignments$queryID %in% queryRevComp)] = queryMax[match(as.character(alignments$queryID[which(alignments$queryID %in% queryRevComp)]), names(queryMax))] - alignments$queryEnd[which(alignments$queryID %in% queryRevComp)] + 1
}
## make new query alignments for dot plot
alignments$queryStart2 = alignments$queryStart + sapply(as.character(alignments$queryID), function(x) ifelse(x == names(queryMax)[1], 0, cumsum(queryMax)[match(x, names(queryMax)) - 1]) )
alignments$queryEnd2 = alignments$queryEnd + sapply(as.character(alignments$queryID), function(x) ifelse(x == names(queryMax)[1], 0, cumsum(queryMax)[match(x, names(queryMax)) - 1]) )

# plot
options(warn = -1) # turn off warnings
gp = ggplot(alignments) +
  geom_point(mapping = aes(x = refStart2, y = queryStart2, color = percentID), size = 0.009) +
  geom_point(mapping = aes(x = refEnd2, y = queryEnd2, color = percentID), size = 0.009) +
  geom_segment(aes(x = refStart2, xend = refEnd2, y = queryStart2, yend = queryEnd2, color = percentID)) +
  scale_x_continuous(expand = c(0, 0), breaks = cumsum(as.numeric(chromMax)), labels = levels(alignments$refID)) +
  theme_bw() + 
  theme(
    text = element_text(size = 12),
    panel.grid.minor.y = element_blank(),
    panel.grid.minor.x = element_blank(),
    axis.text.y = element_text(angle = 15),
    axis.text.x = element_text(hjust = 1, angle = 45)
  ) +
  scale_y_continuous(expand = c(0, 0), breaks = cumsum(as.numeric(queryMax)), labels = substr(levels(alignments$queryID), start = 1, stop = 20)) +
  scale_color_distiller(palette = "Spectral") +
  labs(color = "Identity",
       title = paste0(paste0("Post-filtering number of alignments: ", nrow(alignments),"\t\t\t\t"),
                      paste0("minimum alignment length (-m): ", opt$min_align,"\n"),
                      paste0("Post-filtering number of queries: ", length(unique(alignments$queryID)),"\t\t\t\t\t\t\t\t"),
                      paste0("minimum query aggregate alignment length (-q): ", opt$min_query_aln)
       )) + xlab("Reference") + ylab("Query")
# gp
ggsave(filename = paste0(opt$output_filename, ".pdf"), width = opt$plot_size, height = opt$plot_size * 0.8, units = "in", dpi = 300, limitsize = F)
options(warn=0) # turn on warnings