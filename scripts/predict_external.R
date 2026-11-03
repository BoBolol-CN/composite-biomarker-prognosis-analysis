if (.Platform$OS.type == "windows") invisible(Sys.setlocale("LC_CTYPE", ".UTF-8"))
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3) stop("Usage: Rscript scripts/predict_external.R frozen_prediction_models.rds cohort.csv predictions.csv", call. = FALSE)
self <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())][1])
root <- dirname(dirname(normalizePath(self, winslash = "/")))
source(file.path(root, "scripts", "load.R")); bp_load(root)
bundle <- readRDS(args[1]); assert(!is.null(bundle$data_config), "Bundle lacks frozen input definitions.")
assert(!file.exists(args[3]), "Prediction output already exists; choose a new path.")
d <- prepare_data(load_table(args[2]), bundle$data_config)
p <- predict_candidate(bundle$models[[bundle$selected]], d)
result <- data.frame(row = seq_len(nrow(d)), risk = p, horizon = bundle$endpoint$horizon,
                      time_unit = bundle$endpoint$unit, model = bundle$selected)
if (!is.null(bundle$data_config$id_column)) result$id <- d[[bundle$data_config$id_column]]
csv(result, args[3]); message("Frozen predictions saved; outcomes were not required or used.")
