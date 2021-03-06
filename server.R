library(shiny)
library(flexclust)
library(sROC)
library(ggplot2)
library(grid)
library(gridExtra)
library(reshape2)
library(seqLogo)
library(pdist)
library(RMySQL)
library(jsonlite)

addResourcePath("cluster_analysis.dir", sprintf("%s/%s", env$dir.root, env$dir.output))

instance.pid <- Sys.getpid()
instance.time <- as.integer(Sys.time())
next.session.id <- 0

renderRestoration <- function(expr, env = parent.frame(), quoted = F) {
	func <- exprToFunction(expr)
	function() {
		func() 
		# return the selected snapshot to the client side
		# Shiny will automatically wrap it into JSOn
	}
}

shinyServer(
	function(input, output, session) {
		# these help us create a unique session id for tracking
		session.id <- next.session.id
		next.session.id <<- next.session.id + 1
		session.counter <- 0
		likeButtonStates <- list()
		# this function checks for an existing conection and returns it
		# or else it makes a new connection (also handles timeout)
		db.con <- get.connection(env$mysql.database)
		# exchange object between observe and reactive output
		like.state <- list()

		# session log observer
		# trap any changes to the listed inputs and save the session state
		observe({
			# register a call on a change in any of the below
			input$k
			input$kLikeReasonModalClose

			input$cluster
			input$clusterDisplayMotif1GeneProfile
			input$clusterDisplayMotif2GeneProfile
			input$clusterDisplayMotif3GeneProfile
			input$clusterDisplayMotif4GeneProfile
			input$clusterProfilePlotTracks
			input$clusterProfilePlotSampleNames
			input$clusterSelectedRows
			input$clusterLikeReasonModalClose
			input$clusterMotif1LikeReasonModalClose
			input$clusterMotif2LikeReasonModalClose
			input$clusterMotif3LikeReasonModalClose
			input$clusterMotif4LikeReasonModalClose

			input$searchText

			input$myClusterGenesUpdateButton
			input$myClusterRecruitButton
			input$myClusterDisplayMotif1GeneProfile
			input$myClusterDisplayMotif2GeneProfile
			input$myClusterDisplayMotif3GeneProfile
			input$myClusterDisplayMotif4GeneProfile
			input$myClusterProfilePlotTracks
			input$myClusterProfilePlotSampleNames
			input$myClusterSelectedRows
			input$myClusterLikeReasonModalClose
			input$myClusterMotif1LikeReasonModalClose
			input$myClusterMotif2LikeReasonModalClose
			input$myClusterMotif3LikeReasonModalClose
			input$myClusterMotif4LikeReasonModalClose

			input$blastnDatabase		

			input$likesID

			# isolate this out so that only the above will trigger
			isolate(session.log())
		})
		# session log handler
		session.log <- function() {
			# convert the input to a single line data.frame and patch
			# 0. copy the reactive object
			input.tmp <- reactiveValuesToList(input)
			# 1. flatten lists
			if (is.null(input.tmp$clusterSelectedRows)) {
				input.tmp$clusterSelectedRows <- ""
			} else {
				input.tmp$clusterSelectedRows <- paste(input.tmp$clusterSelectedRows, collapse=",")
			}
			if (is.null(input.tmp$myClusterSelectedRows)) {
				input.tmp$myClusterSelectedRows <- ""
			} else {
				input.tmp$myClusterSelectedRows <- paste(input.tmp$myClusterSelectedRows, collapse=",")
			}
			# 2. make data frame
			input.state <- data.frame(lapply(input.tmp, function(x) t(data.frame(x))))
			# 3. drop some column names
			input.state <- input.state[,!(names(input.state) %in% grep("Modal", names(input.state), value = T))]
			input.state <- input.state[,!(names(input.state) %in% grep("Button", names(input.state), value = T))]
			# 4. add session specific data for tracing
			# add some session id info, combine all three for a unique session
			input.state$instance.pid <- c( instance.pid )
			input.state$instance.time <- c( instance.time )
			input.state$session.id <- c( session.id )
			input.state$session.counter <- c ( session.counter )
			session.counter <<- session.counter + 1
			# 5. handle dynamic ui inputs
			if (is.null(input.state$cluster)) {
				input.state$cluster <- c(NA)
				transform(input.state, cluster <- as.integer(input.state$cluster))
			}
			if (is.null(input.state$clusterSearchResultSelectedRow)) {
				# "" sets the type to text
				input.state$clusterSearchResultSelectedRow <- ""
			}
			if (is.null(input.state$myClusterGenes)) {
				# "" sets the type to text
				input.state$myClusterGenes <- ""
			}
			input.state$myClusterGenes <- as.character(input.state$myClusterGenes)
			# convert F/T to 0/1
			lapply(names(input.state), function(input.name) {
				if (identical(input.state[1, input.name], F)) {
					input.state[, input.name] <<- as.integer(input.state[,input.name])
				} else if (identical(input.state[1, input.name], T)) {
					input.state[, input.name] <<- as.integer(input.state[,input.name])
				}
			})

			# if the table exists, append, else create new and either way save
			# this is deprecated and soon to be removed as the table is created in init.sql
			if (dbExistsTable(db.con, env$mysql.log.table)) {
				dbWriteTable(db.con, env$mysql.log.table, input.state, append = T, row.names = F)
			} else {
				dbWriteTable(db.con, env$mysql.log.table, input.state, row.names = F)
			}
		}

		# universal observer for all like buttons
		observe({
			lapply(grep("LikeButton", names(input)),
				function(n) {
					btn <- names(input)[n]
					mdl <- sub("Button", "ReasonModal", btn)
					if (is.null(likeButtonStates[[btn]])) {
						likeButtonStates[[btn]] <<- 0
					}
					if (input[[btn]] != likeButtonStates[[btn]]) {
						toggleModal(session, mdl)
						likeButtonStates[[btn]] <<- input[[btn]]
					}
				}
			)
		})

		# all k tab
		kdsdf <- get.distsum()
		output$kDistSumPlot <- renderPlot({
			distsum.plot(kdsdf)
		})
		output$kDistSumDeltaPlot <- renderPlot({
			distsum.delta.plot(kdsdf)
		})

		# choose k tab
		kclust <- reactive({
			env$cluster.ensemble[[input$k]]
		})
		output$k <- renderText({
			input$k
		})
		output$clusterSizePlot <- renderPlot({
			cluster.size.plot(kclust())
		})
		output$clusterOverviewPlot <- renderPlot({
			plot(kclust(), project=env$samples$prcomp)
		})
		output$clusterProfileOverviewPlotArea <- renderUI ({
			plotOutput("clusterProfileOverviewPlot", height=paste((as.numeric(input$k)/3.) * 200.,"px", sep=""))
		})
		output$clusterProfileOverviewPlot <- renderPlot({
			profilePlots <- lapply(1:input$k,
				function(cluster) {
					clust <- clusts()[clusts() == cluster]
					profile.data <- env$samples$log.ratio[names(clust),]
					makeClusterProfilePlot(profile.data = profile.data, 
						title = cluster,
						y.range.adj = 1.5,
						simple = T
					)
				}
			)
			do.call(grid.arrange, c(profilePlots, list(ncol=3)))
		})

		# choose cluster tab
		clusts <- reactive({
			clusters(env$cluster.ensemble[[input$k]])
		})
		clust <- reactive({
			clusts()[clusts()==input$cluster]
		})
		output$cluster <- renderText({
			input$cluster
		})
		output$clusterSelection <- renderUI({
			# list of clusters
			clist <- 1:input$k
			# use a preselected cluster if available
			csr <- getClusterSearchResults(input$k, input$searchText)
			selectInput("cluster", "Choose cluster", clist, selected=csr[input$clusterSearchResultSelectedRow, "Cluster"])
		})
		output$clusterProfilePlot <- renderPlot({
			if (is.null(input$clusterSelectedRows)) {
				rowFocus <- F
			} else {
				rowFocus <- input$clusterSelectedRows
			}
			cl <- clust()
			if (!length(cl)) {
				return(NULL)
			}
			profile.data <- env$samples$log.ratio[names(cl),]
			if (input$clusterProfilePlotSampleNames == "Full") {
				sample.names <- env$samples$info[env$samples$ordering, "fancy.names"]
			} else if (input$clusterProfilePlotSampleNames == "Short") {
				sample.names <- env$samples$info[env$samples$ordering, "shortd"]
			} else {
				sample.names <- F
			}
			makeClusterProfilePlot(profile.data = profile.data,
				title = sprintf("K = %d : Cluster %d (%d genes)\nExpression profile",
					env$cluster.ensemble[[input$k]]@k, as.integer(input$cluster), length(names(cl))
				),
				focus = rowFocus,
				display.motif.gene.profile = c(1:env$meme.nmotifs)[
					c(
						input$clusterDisplayMotif1GeneProfile,
						input$clusterDisplayMotif2GeneProfile,
						input$clusterDisplayMotif3GeneProfile,
						input$clusterDisplayMotif4GeneProfile
					)
				],
				motifs = env$meme.data[[input$k]][[input$cluster]],
				motif.colors = env$motif.colors,
				display.tracks = input$clusterProfilePlotTracks,
				tracks = env$samples$tracks,
				alt.sample.names = sample.names
			)
		})
		motifs <- reactive({
			if (is.null(input$k) || is.null(input$cluster)) {
				return(NULL)
			}
			return(env$meme.data[[input$k]][[input$cluster]])
		})
		output$clusterMotif1Summary <- renderText({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 1) {
				return(NULL)
			}
			paste("E-value:", ms[[1]]$e.value, "- genes: ", length(ms[[1]]$positions$gene))
		})
		output$clusterMotif1Consensus <- renderText({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 1) {
				return(NULL)
			}
			paste("Consesus:", ms[[1]]$consensus);
		})
		output$clusterMotif1Plot <- renderPlot({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 1) {
				return(NULL)
			}
			seqLogo(t(ms[[1]]$pssm))
		})
		output$clusterMotif2Summary <- renderText({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 2) {
				return(NULL)
			}
			paste("E-value:", ms[[2]]$e.value, "- genes: ", length(ms[[2]]$positions$gene))
		})
		output$clusterMotif2Consensus <- renderText({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 2) {
				return(NULL)
			}
			paste("Consesus:", ms[[2]]$consensus);
		})
		output$clusterMotif2Plot <- renderPlot({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 2) {
				return(NULL)
			}
			seqLogo(t(ms[[2]]$pssm))
		})
		output$clusterMotif3Summary <- renderText({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 3) {
				return(NULL)
			}
			paste("E-value:", ms[[3]]$e.value, "- genes: ", length(ms[[3]]$positions$gene))
		})
		output$clusterMotif3Consensus <- renderText({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 3) {
				return(NULL)
			}
			paste("Consesus:", ms[[3]]$consensus);
		})
		output$clusterMotif3Plot <- renderPlot({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 3) {
				return(NULL)
			}
			seqLogo(t(ms[[3]]$pssm))
		})
		output$clusterMotif4Summary <- renderText({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 4) {
				return(NULL)
			}
			paste("E-value:", ms[[4]]$e.value, "- genes: ", length(ms[[4]]$positions$gene))
		})
		output$clusterMotif4Consensus <- renderText({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 4) {
				return(NULL)
			}
			paste("Consesus:", ms[[4]]$consensus);
		})
		output$clusterMotif4Plot <- renderPlot({
			ms <- motifs()
			if (is.null(ms) || length(ms) < 4) {
				return(NULL)
			}
			seqLogo(t(ms[[4]]$pssm))
		})
		output$clusterMembers <- renderDataTable({
			cl <- clust()
			if (!length(cl)) {
				return(NULL)
			}
			ns <- names(cl)

			# hierachical clustering of rows for row ordering
			# could this be precomputed?
			clustres <- env$samples$log.ratio[ns,]
			hclustres <- hclust(dist(clustres), method="complete")
			ns <- ns[hclustres$order]

			dir <- paste(
					dir.k.cluster(env$dir.output, env$cluster.ensemble[[input$k]]@k, input$cluster, make.dir = T),
					env$dir.motif.plots,
					sep = "/"
			)
			png.path = paste(dir, paste(ns, ".png", sep=""), sep="/")
			motif.img <- paste("<img src='", png.path, "' alt=''></img>", sep="")
			# get the list of sites
			msc <- env$meme.sites[[input$k]][[input$cluster]]
			# go through list and empty out image url for genes with no motif positions
			# if we need an image, check if it exists or set a flag to render all pngs
			render.pngs <- F
			for (n in 1:length(ns)) {
				if (dim(msc[msc$gene==ns[n], ])[1] == 0) {
					motif.img[n] <- ""
				} else if (identical(render.pngs, F) && !file.exists(png.path[n])) {
					render.pngs <- T
				}
			}
			# render the pngs if necessary
			if (identical(render.pngs, T)) {
				ms <- motifs()
				cat(sprintf("rendering %d pngs...", length(ns)))
				renderMotifPlots(dir,
					genes = ns,
					upstream.seqs = env$genes$upstream.seqs[ns,],
					upstream.start = env$upstream.start,
					upstream.end = env$upstream.end,
					motifs = ms,
					motif.colors = env$motif.colors,
					msc = msc
				)
				cat("done!\n")
			}
			data.frame("Locus tag" = ns, 
				"Product" = env$genes$annotations[ns, "product"],
				"Motif images" = motif.img,
				check.names = F
			)
		}, options = list(
				paging = F,
				columnDefs = list(list(targets = c(3) - 1, searchable = F))	# disable search on motif image
			),
			callback = "function(table) {
	  				table.on('click.dt', 'tr', function() {
						$(this).toggleClass('selected');
						var seldata = table.rows('.selected').indexes().toArray();
						var data = table.rows('.selected').data().data();
						var genes = [];
						for (sel in seldata) {
							genes.push(data[seldata[sel]][0])
						}
						console.log(genes);
						Shiny.onInputChange('clusterSelectedRows', genes);
					});
				}",
			escape = F
		)
		output$downloadClusterData <- downloadHandler(
			filename = function() { paste("k", input$k, "_cluster", input$cluster, ".xls", sep='') },
			content = function(file) {
				ns <- names(clust())
				write.table(
					data.frame(locus.tag = ns, 
						product = env$genes$annotations[ns, "product"],
						env$samples$rpkm[ns,],
						env$samples$log.ratio[ns,]
					),
					file, quote=F, sep='\t', row.names=F)
			}
		)

		# search cluster tab
		output$clusterSearchResults <- renderDataTable({
			getClusterSearchResults(input$k, input$searchText)
		}, options = list(
				paging = F
			),
			callback = "function(table) {
	  				table.on('click.dt', 'tr', function() {
						table.$('tr.selected').removeClass('selected');
						$(this).toggleClass('selected');
						var seldata = table.rows('.selected').indexes().toArray();
						var data = table.rows('.selected').data().data();
						var genes = [];
						for (sel in seldata) {
							genes.push(data[seldata[sel]][0])
						}
						console.log(genes);
						Shiny.onInputChange('clusterSearchResultSelectedRow', genes);
						Shiny.onInputChange('clusterSelectedRows', genes);

						 tabs = $('.nav li')
					 	 tabs.each(function() {
							$(this).removeClass('active')
					 	 })
						 $(tabs[2]).addClass('active')
						
						 tabsContents = $('.tab-content .tab-pane')
					 	 tabsContents.each(function() {
							$(this).removeClass('active')
					 	 })
						 $(tabsContents[2]).addClass('active')

						 $('#cluster').trigger('change').trigger('shown');
						 
					});
				}"
		)
		output$clusterSearchResultSelectedRows <- renderText({
			csr <- getClusterSearchResults(input$k, input$searchText)
			paste(c('Cluster:', csr[input$clusterSearchResultSelectedRow, "Cluster"]), collapse = ' ')
  		})
		# My cluster tab
		observe({
			if (input$myClusterRecruitButton != 0) {
				isolate({
					my.cluster.log.ratio <- env$samples$log.ratio[my.cluster.genes(),]
					other.log.ratio <- env$samples$log.ratio[!rownames(env$samples$log.ratio) %in% my.cluster.genes(),]
					switch(input$myClusterRecruitBy,
						min2centroid = {
								cmean<-apply(my.cluster.log.ratio, 2, mean)
								other.log.ratio$dist <- sqrt(rowSums(t(t(other.log.ratio)-cmean)^2))
								new.genes <- rownames(other.log.ratio[order(other.log.ratio$dist),])[1:input$myClusterRecruitN]
							},
						min2member = {
								pdm <- as.matrix(pdist(other.log.ratio, my.cluster.log.ratio))
								# find the minimum for each row (gene to each member)
								rmin <- t(sapply(seq(nrow(pdm)), function(i) {
									j <- which.min(pdm[i,])
									pdm[i,j]
								}))
								other.log.ratio$dist <- t(rmin)
								new.genes <- rownames(other.log.ratio[order(other.log.ratio$dist),])[1:input$myClusterRecruitN]
							},
						random = {
								rrow <- sample(nrow(other.log.ratio), input$myClusterRecruitN)
								new.genes <- rownames(other.log.ratio[rrow,])
							},
						{	# default case, report a warning
							warning(paste("unhandled input$myClusterRecruitBy case:", input$myClusterRecruitBy))
						}
					)
					# send a client side message about the update to the textarea 
					message <- list(
						value=paste(paste(my.cluster.genes(), collapse="\n"), paste(new.genes, collapse="\n"), sep="\n")
					)
					session$sendInputMessage("myClusterGenes", message)
				})
			}
		})
		my.cluster.genes <- reactive({
			if (input$myClusterGenesUpdateButton != 0) {

				isolate({
					print("my.cluster.genes")
					if (input$myClusterGenes == "" && !is.null(input$likesID)) {
						print(as.integer(input$likesID))
					} else if (!is.null(input$myClusterGenes)) {
						print(input$myClusterGenes)
						genes <- unlist(strsplit(input$myClusterGenes, "\n", fixed=T))
						valid.genes <- genes %in% rownames(env$samples$log.ratio)
						return(genes[valid.genes])
					}
					print("no default...")
					return(c())
				})
			}
		})
		my.cluster.motifs <- reactive({
			mcg <- my.cluster.genes()

			if (length(mcg) < 1) {
				return(NULL)
			}

			# setup the training set data frame to be validated in memeParse
			training.set <- data.frame(length=env$genes$upstream.seqs[mcg, "uplength"], row.names = mcg)
			# remove any NA (i.e. the gene had no upstream sequence because of an overlap)
			training.set <- training.set[!is.na(training.set$length),"length", drop = F]

			if (length(training.set$length) > 1) {
				clust.seqs.upstream <- env$genes$upstream.seqs[mcg,]
				dir <- dir.my.cluster(env$dir.output, env$dir.my.cluster, instance.pid, instance.time, session.id)
				dir.create(dir, recursive = T, showWarnings = F)
				fasta.file <- paste(dir, env$file.upstream.fa, sep="/")
				if (file.exists(fasta.file)) {
					   file.remove(fasta.file);
				}
				for (k in 1:length(rownames(clust.seqs.upstream))) {
						if (!is.na(clust.seqs.upstream$sequence[k])) {
								cat(paste(">", rownames(clust.seqs.upstream)[k], "\n", sep="") , file=fasta.file, append=T)
								cat(paste(clust.seqs.upstream$sequence[k], "\n", sep="") , file=fasta.file, append=T)
						}
				}

				meme.file <- paste(dir, env$file.meme.txt, sep="/")
				meme.cmd <- paste(env$path.to.meme, fasta.file, "-nmotifs", env$meme.nmotifs, env$meme.base.args, "-oc", dir, "-bfile", 
					env$file.meme.bfile,
					">&", 
					meme.file
				)
				print(meme.cmd)
				system(meme.cmd)

				# load the meme output file
				motifs <- memeParse(meme.file, training.set)
				cat(sprintf("rendering %d pngs...", length(mcg)))
				meme.sites <- renderMotifPlots(paste(dir, env$dir.motif.plots, sep="/"),
					genes = mcg,
					upstream.seqs = env$genes$upstream.seqs[mcg,],
					upstream.start = env$upstream.start,
					upstream.end = env$upstream.end,
					motifs = motifs,
					motif.colors = env$motif.colors
				)
				cat("done!\n")
				return(list("meme.data" = motifs, "meme.sites" = meme.sites))
			}
			return(NULL)
		})
		output$myClusterProfilePlot <- renderPlot({
			if (is.null(input$myClusterSelectedRows)) {
				rowFocus <- F
			} else {
				rowFocus <- input$myClusterSelectedRows
			}
			profile.data <- env$samples$log.ratio[my.cluster.genes(),]
			if (input$myClusterProfilePlotSampleNames == "Full") {
				sample.names <- env$samples$info[env$samples$ordering, "fancy.names"]
			} else if (input$myClusterProfilePlotSampleNames == "Short") {
				sample.names <- env$samples$info[env$samples$ordering, "shortd"]
			} else {
				sample.names <- F
			}
			makeClusterProfilePlot(profile.data = profile.data,
				title = "",
				y.range.adj = 1.5,
				simple = F,
				focus = rowFocus,
				display.motif.gene.profile = c(1:4)[
					c(
						input$myClusterDisplayMotif1GeneProfile,
						input$myClusterDisplayMotif2GeneProfile,
						input$myClusterDisplayMotif3GeneProfile,
						input$myClusterDisplayMotif4GeneProfile
					)
				],
				motifs = my.cluster.motifs()$meme.data,
				motif.colors = env$motif.colors,
				display.tracks = input$myClusterProfilePlotTracks,
				tracks = env$samples$tracks,
				alt.sample.names = sample.names
			)
		})
		output$myClusterMembers <- renderDataTable({
			ns <- my.cluster.genes()
			mcm <- my.cluster.motifs()
			# could this be precomputed?
			if (length(ns) > 1) {
				clustres <- env$samples$log.ratio[ns,]
				hclustres <- hclust(dist(clustres), method="complete")
				ns <- ns[hclustres$order]
			}

			# put together path of the motif image for each gene
			dir <- paste(dir.my.cluster(env$dir.output, env$dir.my.cluster, instance.pid, instance.time, session.id), env$dir.motif.plots, sep="/")
			# use runif to append a random number to prevent all caching here
			motif.img <- paste("<img src='", 
					paste(env$url.prefix, dir, paste(ns, ".png?", runif(1, min=0, max=10), sep=""), sep="/"),
					"' alt=''></img>", sep="")
			# for genes with no sites, empty out the image url
			ms <- mcm$meme.sites
			if (length(ms)) {
				for (n in 1:length(ns)) {
					if (dim(ms[ms$gene==ns[n],])[1] == 0) {
						motif.img[n] <- ""
					}
				}
			} else {
				motif.img <- rep("", length(motif.img))
			}
			data.frame("Locus tag" = ns, 
				"Product" = env$genes$annotations[ns, "product"],
				"Motif images" = motif.img,
				check.names = F
			)
		}, options = list(
				paging = F,
				columnDefs = list(list(targets = c(3) - 1, searchable = F))	# disable search on motif image
			),
			callback = "function(table) {
	  				table.on('click.dt', 'tr', function() {
						$(this).toggleClass('selected');
						var seldata = table.rows('.selected').indexes().toArray();
						var data = table.rows('.selected').data().data();
						var genes = [];
						for (sel in seldata) {
							genes.push(data[seldata[sel]][0])
						}
						console.log(genes);
						Shiny.onInputChange('myClusterSelectedRows', genes);
					});
				}",
			escape = F
		)

		output$myClusterMotif1Summary <- renderText({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 1) {
				return(NULL)
			}
			paste("E-value:", mcm$meme.data[[1]]$e.value, "- genes: ", length(mcm$meme.data[[1]]$positions$gene))
		})
		output$myClusterMotif1Consensus <- renderText({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 1) {
				return(NULL)
			}
			paste("Consesus:", mcm$meme.data[[1]]$consensus);
		})
		output$myClusterMotif1Plot <- renderPlot({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 1) {
				return(NULL)
			}
			seqLogo(t(mcm$meme.data[[1]]$pssm))
		})
		output$myClusterMotif2Summary <- renderText({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 2) {
				return(NULL)
			}
			paste("E-value:", mcm$meme.data[[2]]$e.value, "- genes: ", length(mcm$meme.data[[2]]$positions$gene))
		})
		output$myClusterMotif2Consensus <- renderText({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 2) {
				return(NULL)
			}
			paste("Consesus:", mcm$meme.data[[2]]$consensus);
		})
		output$myClusterMotif2Plot <- renderPlot({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 2) {
				return(NULL)
			}
			seqLogo(t(mcm$meme.data[[2]]$pssm))
		})
		output$myClusterMotif3Summary <- renderText({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 3) {
				return(NULL)
			}
			paste("E-value:", mcm$meme.data[[3]]$e.value, "- genes: ", length(mcm$meme.data[[3]]$positions$gene))
		})
		output$myClusterMotif3Consensus <- renderText({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 3) {
				return(NULL)
			}
			paste("Consesus:", mcm$meme.data[[3]]$consensus);
		})
		output$myClusterMotif3Plot <- renderPlot({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 3) {
				return(NULL)
			}
			seqLogo(t(mcm$meme.data[[3]]$pssm))
		})
		output$myClusterMotif4Summary <- renderText({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 4) {
				return(NULL)
			}
			paste("E-value:", mcm$meme.data[[4]]$e.value, "- genes: ", length(mcm$meme.data[[4]]$positions$gene))
		})
		output$myClusterMotif4Consensus <- renderText({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 4) {
				return(NULL)
			}
			paste("Consesus:", mcm$meme.data[[4]]$consensus);
		})
		output$myClusterMotif4Plot <- renderPlot({
			mcm <- my.cluster.motifs()
			if (is.null(mcm) || length(mcm$meme.data) < 4) {
				return(NULL)
			}
			seqLogo(t(mcm$meme.data[[4]]$pssm))
		})
		output$myClusterMemeLog <- renderText({
			# register reactivity with the gene list text area and update button
			my.cluster.genes()
			dir <- dir.my.cluster(env$dir.output, env$dir.my.cluster, instance.pid, instance.time, session.id)
			meme.file <- paste(dir, env$file.meme.txt, sep="/")
			if (file.exists(meme.file)) {
				return(paste(readLines(meme.file), "\n"))
			}
			return(NULL)
		})

		# blastn
		output$blastnResults <- renderDataTable({
			data.frame(BLASTn=c("disabled"), reason=c("insuffecient resources"))
		}, options = list(paging=F))

		# blastp
		output$blastpResults <- renderDataTable({
			data.frame(BLASTp=c("disabled"), reason=c("insuffecient resources"))
		}, options = list(paging=F))

		# likes
		output$inputContainer <- renderRestoration({
			if (!is.null(input$likesID)) {
				#return(list(k="20", cluster="2", clusterDisplayMotif1GeneProfile=T))
#				return(list(k="20", 
#						cluster="2", 
#						clusterDisplayMotif1GeneProfile=T, 
#						#myClusterGenes="MBURv2_160301\nMBURv2_160300\nMBURv2_160302",
#						myClusterRecruit=4
#					)
#				)
#				return(as.list(like.state))
				return(list(k=like.state$k[1]))
			}
			return(list())
		})
		observe({
			if (!is.null(input$likesID)) {
cat("pulling likes\n")
				like.state <<- dbGetQuery(db.con, sprintf("SELECT * FROM log WHERE id = %d;", as.integer(input$likesID)))
#updateTextInput(session, inputId = "myClusterGenes", value = like.state[1, "myClusterGenes"])
				
				tabNo <- 1
				tabControl <- "#k"
				update.my.cluster <- F
				lapply(names(like.state), function(input.name) {
					value <- NULL
					if (input.name %in% c("id", "instance.pid", "instance.time", "session.id", "session.counter", "likesID")) {
						return(NULL)
					} else if (input.name %in% c("clusterSelectedRows", "myClusterSelectedRows")) {
						value <- strsplit(like.state[1, input.name], ",", fixed = T)[[1]]
						#print(value)
					} else {
						value <- like.state[1, input.name]
					}
					if (length(grep("LikeReason", input.name)) > 0) {
						if (substr(input.name, 1, 1) == "k" && value != "") {
							tabNo <<- 1
							tabControl <<- "#k"
						} else if (substr(input.name, 1, 7) == "cluster" && value != "") {
							tabNo <<- 2
							tabControl <<- "#cluster"
						} else if (substr(input.name, 1, 9) == "myCluster" && value != "") {
							tabNo <<- 4
							tabControl <<- "#myClusterRecruitN"
							update.my.cluster <<- T
						}
						return(NULL)
					}
# temporary fix to force only restoration of myCluster
#					if (!is.na(pmatch("myCluster", input.name))) {
						print(c(input.name, value))
						session$sendInputMessage(input.name, list(value = value))
#					}
				})
				session$sendCustomMessage(type = 'setActiveTab', message = list(tabNo = tabNo, tabControl = tabControl))
			}
		})
		# like button monitor
		scan.like.buttons <- reactive({
			lapply(grep("LikeButton", names(input)),
				function(n) {
					btn <- names(input)[n]
					input[[btn]]
				}
			)
		})
		output$likesTable <- renderDataTable({
			# monitor like buttons to reload table
			scan.like.buttons()
			# reload table
			likes <- dbReadTable(db.con, env$mysql.log.like.view, row.names = "id");
			names(likes) <- c("ID", "Liked", "Reason")
			likes
		}, options = list(paging=F),
			callback = "function(table) {
	  				table.on('click.dt', 'tr', function() {
						table.$('tr.selected').removeClass('selected');
						$(this).toggleClass('selected');
						var seldata = table.rows('.selected').indexes().toArray();
						var id = table.rows('.selected').data().data()[seldata[0]][0];
						Shiny.onInputChange('likesID', id);
					});
				}"
		)
	}
)

getClusterSearchResults <- function(k, searchText) {
		row.select <- union(
				grep(searchText, rownames(env$genes$annotations), ignore.case=T),
				grep(searchText, env$genes$annotations$product, ignore.case=T)
			)
		gcsr.clusts <- clusters(env$cluster.ensemble[[k]])
		gcsr.clust <- gcsr.clusts[row.select]
		data.frame("Locus tag" = names(gcsr.clust), 
			"Product" = env$genes$annotations[names(gcsr.clust), "product"], 
			"Cluster" = gcsr.clust,
			check.names = F
		)
}
