if (.Platform$OS.type == "windows") invisible(Sys.setlocale("LC_CTYPE", ".UTF-8"))
args <- commandArgs(trailingOnly = TRUE)
self <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())][1])
root <- dirname(dirname(normalizePath(self, winslash = "/")))
source(file.path(root, "scripts", "load.R")); bp_load(root)
target <- if (length(args)) normalizePath(args[1], mustWork = FALSE) else file.path(root, "outputs", "synthetic-demo")
dir.create(target, recursive = TRUE, showWarnings = FALSE)
make_synthetic <- function(n, seed, shift = 0) {
  set.seed(seed)
  age <- pmin(90, pmax(25, stats::rnorm(n, 62 + shift, 11)))
  sex <- sample(c("female", "male"), n, replace = TRUE)
  center <- sample(LETTERS[1:4], n, replace = TRUE)
  b <- stats::rlnorm(n, .2, .3); a <- b * stats::rlnorm(n, .35 + shift / 30, .55); index <- a / b
  lp <- .032 * (age - 60) + .22 * (sex == "male") + .7 * log(index) + .18 * log(index)^2
  death <- stats::rexp(n, rate = .009 * exp(lp))
  censor <- stats::runif(n, 28, 58); followup <- pmin(death, censor); event <- as.integer(death <= censor)
  target_event <- stats::rexp(n, .006 * exp(.5 * log(index) + .01 * (age - 60)))
  cr <- first_event(target_event, death, censor, tie = "error")
  age[stats::runif(n) < .04] <- NA_real_
  data.frame(patient_id = sprintf("SIM_%d_%04d", seed, seq_len(n)), age, sex, center,
             marker_a = a, marker_b = b, followup, event, target_time = cr$time, target_status = cr$status)
}
development <- make_synthetic(1000, 731)
external <- make_synthetic(650, 932, shift = 3)
csv(development, file.path(target, "synthetic_development.csv")); csv(external, file.path(target, "synthetic_external.csv"))
env <- new.env(); sys.source(file.path(root, "assets", "config.example.R"), env); cfg <- env$config
cfg$input <- file.path(target, "synthetic_development.csv")
cfg$output_dir <- file.path(target, "analysis"); cfg$synthetic <- TRUE; cfg$overwrite <- TRUE
cfg$population_label <- "Synthetic demonstration cohort"
cfg$export_xlsx <- TRUE
cfg$prediction$external_input <- file.path(target, "synthetic_external.csv")
cfg$prediction$bootstrap <- 150
cfg$endpoints[[2]] <- list(id = "target_event", label = "Synthetic nonfatal event", type = "competing", time = "target_time",
                          status = "target_status", cause = 1, unit = "months", horizon = 24)
cfg$modules <- c("baseline", "cox", "km", "spline", "competing", "subgroup", "landmark", "center", "prediction")
cfg$plots$diagnostics <- TRUE
res <- run_workflow(cfg)
if ("--gallery" %in% args) stop("Pass an output directory, not --gallery.")
message("Synthetic demo finished. Figures: ", file.path(cfg$output_dir, "figures"))
