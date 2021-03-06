#' GRanges representing the breakend coordinates of
#' structural variants
#' #@export
#setClass("BreakpointGRanges", contains="GRanges")

#' Partner breakend for each breakend.
#'
#' @details
#' All breakends must have their partner breakend included
#' in the GRanges.
#'
#'@export
partner <- function(gr) {
	assertthat::assert_that(all(gr$partner %in% names(gr)))
	return(gr[gr$partner,])
}

#' Finds overlapping breakpoints by requiring that breakends on
#' boths sides overlap
#'
#' @details
#' See GenomicRanges::findOverlaps-methods for details of overlap calculation
#'
#' @param sizemargin error margin in allowable size to prevent matching of events
#' of different sizes such as a 200bp event matching a 1bp event when maxgap is
#' set to 200.
#' @param restrictMarginToSizeMultiple size restriction multiplier on event size.
#' The default value of 0.5 requires that the breakpoint positions can be off by
#' at maximum, half the event size. This ensures that small deletion do actually
#' overlap at least one base pair.
#'
#'@export
findBreakpointOverlaps <- function(query, subject, maxgap=0L, minoverlap=1L, ignore.strand=FALSE, sizemargin=0.25, restrictMarginToSizeMultiple=0.5) {
	hitdf <- as.data.frame(findOverlaps(query, subject, maxgap=maxgap, minoverlap=minoverlap, type="any", select="all", ignore.strand=ignore.strand), row.names=NULL)
	# instead of running findOverlaps(partner(query), partner(subject), ...
	# we can reduce our runtime cost by just performing partner index lookups
	# partner lookups
	subjectPartnerIndexLookup <- seq_along(names(subject))
	names(subjectPartnerIndexLookup) <- names(subject)
	queryPartnerIndexLookup <- seq_along(names(query))
	names(queryPartnerIndexLookup) <- names(query)
	phitdf <- data.frame(
		queryHits=queryPartnerIndexLookup[query$partner[hitdf$queryHits]],
		subjectHits=subjectPartnerIndexLookup[subject$partner[hitdf$subjectHits]])
	hits <- rbind(hitdf, phitdf, make.row.names=FALSE)
	# we now want to do:
	# hits <- hits[duplicated(hits),] # both breakends match
	# but for large hit sets (such as focal false positive loci) we run out of memory (>32GB)
	# instead, we sort then check that we match the previous record
	hits <- hits[base::order(hits$queryHits, hits$subjectHits), ]
	lg <- function(x) {
		if (length(x) == 0) {
			return(x)
		} else {
			return(c(-1, x[1:(length(x)-1)])) # -1 to ensure FALSE match instead of NA match
		}
	}
	isDup <- hits$queryHits == lg(hits$queryHits) & hits$subjectHits == lg(hits$subjectHits)
	hits <- hits[isDup,]
	if (!is.null(sizemargin) && !is.na(sizemargin)) {
		# take into account confidence intervals when calculating event size
		callwidth <- .distance(query, partner(query))
		truthwidth <- .distance(subject, partner(subject))
		callsize <- callwidth + (query$insLen %na% 0)
		truthsize <- truthwidth + (subject$insLen %na% 0)
		hits$sizeerror <- .distance(
			IRanges(start=callsize$min[hits$queryHits], end=callsize$max[hits$queryHits]),
			IRanges(start=truthsize$min[hits$subjectHits], end=truthsize$max[hits$subjectHits])
			)$min
		# event sizes must be within sizemargin
		hits <- hits[hits$sizeerror - 1 < sizemargin * pmin(callsize$max[hits$queryHits], truthsize$max[hits$subjectHits]),]
		# further restrict breakpoint positions for small events
		hits$localbperror <- .distance(query[hits$queryHits], subject[hits$subjectHits])$min
		hits$remotebperror <- .distance(partner(query)[hits$queryHits], partner(subject)[hits$subjectHits])$min
		if (!is.null(restrictMarginToSizeMultiple)) {
			allowablePositionError <- (pmin(callsize$max[hits$queryHits], truthsize$max[hits$subjectHits]) * restrictMarginToSizeMultiple + 1)
			hits <- hits[hits$localbperror <= allowablePositionError & hits$remotebperror <= allowablePositionError, ]
		}
	}
	return(hits)
}
.distance <- function(r1, r2) {
	return(data.frame(
		min=pmax(0, pmax(start(r1), start(r2)) - pmin(end(r1), end(r2))),
		max=pmax(end(r2) - start(r1), end(r1) - start(r2))))
}
#' Finds common breakpoints between the two breakpoint sets
#'
#' @details
#' See GenomicRanges::countOverlaps-methods
#'
#' @param countOnlyBest count each subject breakpoint as overlaping only the
#' best overlapping query breakpoint.
#'
#' @param breakpointScoreColumn query column defining a score for
#' determining which query breakpoint is considered the best when countOnlyBest=TRUE
#' @return an integer vector containing the tabulated query overlap hits
#' @export
countBreakpointOverlaps <- function(querygr, subjectgr, countOnlyBest=FALSE, breakpointScoreColumn = "QUAL", maxgap=0L, minoverlap=1L, ignore.strand=FALSE, sizemargin=0.25, restrictMarginToSizeMultiple=0.5) {
	hitscounts <- rep(0, length(querygr))
	hits <- findBreakpointOverlaps(querygr, subjectgr, maxgap, minoverlap, ignore.strand, sizemargin=sizemargin, restrictMarginToSizeMultiple=restrictMarginToSizeMultiple)
	if (!countOnlyBest) {
		hits <- hits %>%
	      dplyr::group_by(queryHits) %>%
	      dplyr::summarise(n=n())
	} else {
		# assign supporting evidence to the call with the highest QUAL
		hits$QUAL <- mcols(querygr)[[breakpointScoreColumn]][hits$queryHits]
	    hits <- hits %>%
	      dplyr::arrange(desc(QUAL), queryHits) %>%
	      dplyr::distinct(subjectHits, .keep_all=TRUE) %>%
	      dplyr::group_by(queryHits) %>%
	      dplyr::summarise(n=n())
	}
    hitscounts[hits$queryHits] <- hits$n
    return(hitscounts)
}

#' Loads a breakpoint GRanges from a BEDPE file
#' @param file BEDPE file
#' @param placeholderName prefix to use to ensure ids are unique
#'
#' @return breakpoint GRanges object
#' @export
bedpe2breakpointgr <- function(file, placeholderName="bedpe") {
	return(pairs2breakpointgr(import(file), placeholderName))
}
#' Converts a BEDPE Pairs containing pairs of GRanges loaded using rtracklayer::import to a breakpointgr
#' @param pairs pairs object
#' @param placeholderName prefix to use to ensure ids are unique
#'
#' @return breakpoint GRanges object
#' @export
pairs2breakpointgr <- function(pairs, placeholderName="bedpe") {
	n <- names(pairs)
	if (is.null(n)) {
		# BEDPE uses the "name" field
		if ("name" %in% names(mcols(pairs))) {
			n <- mcols(pairs)$name
		} else {
			n <- rep(NA_character_, length(pairs))
		}
	}
	# ensure row names are unique
	n <- ifelse(is.na(n) | n == "" | n =="." | duplicated(n), paste0(placeholderName, seq_along(n)), n)
	#
	gr <- c(S4Vectors::first(pairs), S4Vectors::second(pairs))
	names(gr) <- c(paste0(n, "_1"), paste0(n, "_2"))
	gr$partner <- c(paste0(n, "_2"), paste0(n, "_1"))
	for (col in names(mcols(pairs))) {
		if (col %in% c("name")) {
			# drop columns we have processed
		} else {
			mcols(gr)[[col]] <- mcols(pairs)[[col]]
		}
	}
	return(gr)
}

#' Extracts the breakpoint sequence.
#'
#' @details
#' The sequence is the sequenced traversed from the reference anchor bases
#' to the breakpoint. For backward (-) breakpoints, this corresponds to the
#' reverse compliment of the reference sequence bases.
#'
#' @param gr breakpoint GRanges
#' @param ref Reference BSgenome
#' @param anchoredBases Number of bases leading into breakpoint to extract
#' @param remoteBases Number of bases from other side of breakpoint to extract
#' @export
extractBreakpointSequence <- function(gr, ref, anchoredBases, remoteBases=anchoredBases) {
	localSeq <- extractReferenceSequence(gr, ref, anchoredBases, 0)
	insSeq <- ifelse(strand(gr) == "-",
		as.character(Biostrings::reverseComplement(DNAStringSet(gr$insSeq %na% ""))),
		gr$insSeq %na% "")
	remoteSeq <- as.character(Biostrings::reverseComplement(DNAStringSet(
		extractReferenceSequence(partner(gr), ref, remoteBases, 0))))
	return(paste0(localSeq, insSeq, remoteSeq))
}
#' Returns the reference sequence around the breakpoint position
#'
#' @details
#' The sequence is the sequenced traversed from the reference anchor bases
#' to the breakpoint. For backward (-) breakpoints, this corresponds to the
#' reverse compliment of the reference sequence bases.
#'
#' @param gr breakpoint GRanges
#' @param ref Reference BSgenome
#' @param anchoredBases Number of bases leading into breakpoint to extract
#' @param followingBases Number of reference bases past breakpoint to extract
#' @export
extractReferenceSequence <- function(gr, ref, anchoredBases, followingBases=anchoredBases) {
	assertthat::assert_that(is(gr, "GRanges"))
	assertthat::assert_that(is(ref, "BSgenome"))
	gr <- .constrict(gr)
	seqgr <- GRanges(seqnames=seqnames(gr), ranges=IRanges(
		start=start(gr) - ifelse(strand(gr) == "-", followingBases, anchoredBases - 1),
		end=end(gr) + ifelse(strand(gr) == "-", anchoredBases - 1, followingBases)))
	startPad <- pmax(0, 1 - start(seqgr))
	endPad <- pmax(0, end(seqgr) - seqlengths(ref)[as.character(seqnames(seqgr))])
	ranges(seqgr) <- IRanges(start=start(seqgr) + startPad, end=end(seqgr) - endPad)
	seq <- Biostrings::getSeq(ref, seqgr)
	seq <- paste0(stringr::str_pad("", startPad, pad="N"), as.character(seq), stringr::str_pad("", endPad, pad="N"))
	# DNAStringSet doesn't like out of bounds subsetting
	seq <- ifelse(strand(gr) == "-", as.character(Biostrings::reverseComplement(DNAStringSet(seq))), seq)
	return(seq)
}
#' constrict
.constrict <- function(gr, ref=NULL,position="middle") {
	isLower <- start(gr) < start(partner(gr))
	# Want to call a valid breakpoint
	#  123 456
	#
	#  =>   <= + -
	#  >   <== f f
	#
	#  =>  =>  + +
	#  >   ==> f c
	roundDown <- isLower | strand(gr) == "-"
	if (position == "middle") {
		pos <- (start(gr) + end(gr)) / 2
		ranges(gr) <- IRanges(
			start=ifelse(roundDown,floor(pos), ceiling(pos)),
			width=1, names=names(gr))

	} else {
		stop(paste("Unrecognised position", position))
	}
	if (!is.null(ref)) {
		ranges(gr) <- IRanges(start=pmin(pmax(1, start(gr)), seqlengths(ref)[as.character(seqnames(gr))]), width=1)
	}
	return(gr)
}

#' Calculates the length of inexact homology between the breakpoint sequence
#' and the reference
#'
#' @param gr breakpoint GRanges
#' @param ref Reference BSgenome
#' @param anchorLength Number of bases to consider for homology
#' @param margin Number of additional reference bases include. This allows
#'		for inexact homology to be detected even in the presence of indels.
#' @param match alignment
#' @param mismatch see Biostrings::pairwiseAlignment
#' @param gapOpening see Biostrings::pairwiseAlignment
#' @param gapExtension see Biostrings::pairwiseAlignment
#' @param match see Biostrings::pairwiseAlignment
#'
#'@export
calculateReferenceHomology <- function(gr, ref,
		anchorLength=300,
		margin=5,
		match=2, mismatch=-6, gapOpening=5, gapExtension=3 # bwa
		#match = 1, mismatch = -4, gapOpening = 6, gapExtension = 1, # bowtie2
		) {
	# shrink anchor for small events to prevent spanning alignment
	aLength <- pmin(anchorLength, abs(gr$svLen) + 1) %na% anchorLength
	anchorSeq <- extractReferenceSequence(gr, ref, aLength, 0)
	anchorSeq <- sub(".*N", "", anchorSeq)
	# shrink anchor with Ns
	aLength <- nchar(anchorSeq)
	varseq <- extractBreakpointSequence(gr, ref, aLength)
	varseq <- sub("N.*", "", varseq)
	bpLength <- nchar(varseq) - aLength
	nonbpseq <- extractReferenceSequence(gr, ref, 0, bpLength + margin)
	nonbpseq <- sub("N.*", "", nonbpseq)
	refseq <- paste0(anchorSeq, nonbpseq)

	partnerIndex <- match(gr$partner, names(gr))

	if (all(refseq=="") && all(varseq=="")) {
		# Workaround of Biostrings::pairwiseAlignment bug
		return(data.frame(
			exacthomlen=rep(NA, length(gr)),
			inexacthomlen=rep(NA, length(gr)),
			inexactscore=rep(NA, length(gr))))
	}

	aln <- Biostrings::pairwiseAlignment(varseq, refseq, type="local",
 		substitutionMatrix=nucleotideSubstitutionMatrix(match, mismatch, FALSE, "DNA"),
 		gapOpening=gapOpening, gapExtension=gapExtension, scoreOnly=FALSE)
	ihomlen <- Biostrings::nchar(aln) - aLength - deletion(nindel(aln))[,2] - insertion(nindel(aln))[,2]
	ibphomlen <- ihomlen + ihomlen[partnerIndex]
	ibpscore <- score(aln) + score(aln)[partnerIndex] - 2 * aLength * match

	# TODO: replace this with an efficient longest common substring function
	# instead of S/W with a massive mismatch/gap penalty
	penalty <- anchorLength * match
	matchLength <- Biostrings::pairwiseAlignment(varseq, refseq, type="local",
 		substitutionMatrix=nucleotideSubstitutionMatrix(match, -penalty, FALSE, "DNA"),
 		gapOpening=penalty, gapExtension=0, scoreOnly=TRUE) / match
	ehomlen <- matchLength - aLength
	ebphomlen <- ehomlen + ehomlen[partnerIndex]

	ebphomlen[aLength == 0] <- NA
	ibphomlen[aLength == 0] <- NA
	ibpscore[aLength == 0] <- NA
	return(data.frame(
		exacthomlen=ebphomlen,
		inexacthomlen=ibphomlen,
		inexactscore=ibpscore))
}

#' Identifies breakpoint sequences with signficant homology to BLAST database
#' sequences. Apparent breakpoints containing such sequence are better explained
#' by the sequence from the BLAST database such as by alternate assemblies.
#'
#' @details
#' See https://github.com/mhahsler/rBLAST for rBLAST package installation
#' instructions
#' Download and install the package from AppVeyor or install via install_github("mhahsler/rBLAST") (requires the R package devtools)
calculateBlastHomology <- function(gr, ref, db, anchorLength=150) {
	requireNamespace("rBLAST", quietly=FALSE)
	blastseq <- DNAStringSet(breakpointSequence(gr, ref, anchorLength))
	bl <- rBLAST::blast(db=db)
	cl <- predict(bl, blastseq)
	cl$index <- as.integer(substring(cl$QueryID, 7))
	cl$leftOverlap <- anchorLength - cl$Q.start + 1
	cl$rightOverlap <- cl$Q.end - (nchar(blastseq) - anchorLength)
	cl$minOverlap <- pmin(cl$leftOverlap, cl$rightOverlap)
	return(cl)
}

