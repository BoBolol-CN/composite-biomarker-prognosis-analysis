run_workflow <- function(cfg, data = NULL) {
  check_cfg(cfg); need("survival")
  out <- cfg$output_dir
  assert(is.character(out) && length(out) == 1 && nzchar(out), "Set an output directory.")
  output_path <- normalizePath(out, winslash = "/", mustWork = FALSE)
  for (input in Filter(Negate(is.null), list(cfg$input, cfg$prediction$external_input))) {
    input_path <- normalizePath(input, winslash = "/", mustWork = FALSE)
    assert(!startsWith(tolower(input_path), paste0(tolower(output_path), "/")), "Keep input files outside the output directory.")
  }
  assert(!dir.exists(out) || !length(list.files(out, all.files = TRUE, no.. = TRUE)) || isTRUE(cfg$overwrite),
         "Output directory is not empty; choose a new run directory or set overwrite=TRUE explicitly.")
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  raw <- data %||% load_table(cfg$input)
  d <- prepare_data(raw, cfg)
  metadata <- list(n_input = nrow(raw), n_missing_index = sum(is.na(d$.bp_index)),
                   group_cuts = attr(d, "group_cuts"), synthetic = isTRUE(cfg$synthetic),
                   seed = cfg$seed, modules = cfg$modules, timestamp = format(Sys.time(), tz = "UTC"))
  results <- list(metadata = metadata, endpoints = list(), prediction = NULL)
  csv(data.frame(n_input = nrow(raw), n_missing_index = sum(is.na(d$.bp_index))), file.path(out, "cohort_audit.csv"))
  csv(bind(lapply(cfg$endpoints, function(ep) {
    ed <- ep_data(d, ep)
    data.frame(endpoint = ep$id, n_input = nrow(d), n_observed_endpoint = nrow(ed),
               n_excluded_endpoint = nrow(d) - nrow(ed), target_events = sum(ed$.bp_event))
  })), file.path(out, "endpoint_audit.csv"))
  if ("baseline" %in% cfg$modules) results$baseline <- run_baseline(d, cfg, out)
  for (ep in cfg$endpoints) {
    obj <- list();
    if ("cox" %in% cfg$modules) obj$cox <- if ((cfg$association$missing %||% "complete_case") == "mice")
      run_mi_cox(d, cfg, ep, out) else {
        assert((cfg$association$missing %||% "complete_case") == "complete_case", "Unknown association missing-data method.")
        run_cox(d, cfg, ep, out)
      }
    if ("spline" %in% cfg$modules) obj$spline <- run_spline(d, cfg, ep, out)
    if ("km" %in% cfg$modules) obj$km <- run_km(d, cfg, ep, out)
    if ("competing" %in% cfg$modules) obj$competing <- run_competing(d, cfg, ep, out)
    if (any(c("subgroup", "landmark", "center") %in% cfg$modules)) obj$sensitivity <- run_sensitivity(d, cfg, ep, out)
    results$endpoints[[ep$id]] <- obj
  }
  if ("prediction" %in% cfg$modules) results$prediction <- run_prediction(d, cfg, out)
  rows <- list()
  for (ep in cfg$endpoints) {
    tab <- results$endpoints[[ep$id]]$cox$table
    if (!is.null(tab)) for (i in seq_len(nrow(tab))) {
      r <- tab[i, ]
      rows[[length(rows) + 1]] <- data.frame(result_id = paste(ep$id, r$model, r$form, r$term, sep = "__"),
        analysis = "Cox", status = "completed", population = cfg$population_label %||% "Study cohort",
        endpoint = ep$id, specification = paste(r$model, r$form, r$term), n = r$n, events = r$events,
        estimate = r$HR, lower = r$lower, upper = r$upper, p = r$p,
        source = paste0(slug(ep$id), "_cox.csv; row ", i), qualification = r$qualification)
    }
  }
  pr <- results$prediction
  if (!is.null(pr)) for (dataset in c("Test", if (!is.null(pr$external)) "External")) {
    ev <- if (dataset == "Test") pr$evaluations[[pr$selected]] else pr$external
    for (i in seq_len(nrow(ev$metrics))) {
      r <- ev$metrics[i, ]
      rows[[length(rows) + 1]] <- data.frame(result_id = paste("prediction", dataset, r$metric, sep = "__"),
        analysis = "Prediction", status = "completed", population = dataset, endpoint = pr$endpoint$id,
        specification = paste(pr$selected, "horizon", pr$endpoint$horizon, pr$endpoint$unit),
        n = r$n, events = r$events, estimate = r$estimate, lower = r$lower, upper = r$upper,
        source = if (dataset == "Test") "prediction_metrics.csv" else "external_metrics.csv", qualification = r$method)
    }
  }
  csv(bind(rows), file.path(out, "results_manifest.csv"))
  if (isTRUE(cfg$export_xlsx)) {
    need("openxlsx")
    files <- list.files(out, pattern = "\\.csv$", full.names = TRUE)
    sheets <- lapply(files, utils::read.csv, check.names = FALSE, stringsAsFactors = FALSE)
    names(sheets) <- make.unique(substr(tools::file_path_sans_ext(basename(files)), 1, 25))
    openxlsx::write.xlsx(sheets, file.path(out, "analysis_tables.xlsx"), overwrite = TRUE)
  }
  saveRDS(list(config = cfg, results = results), file.path(out, "analysis_bundle.rds"))
  writeLines(capture.output(sessionInfo()), file.path(out, "sessionInfo.txt"))
  if (isTRUE(cfg$plots$enabled)) make_gallery(results, cfg, file.path(out, "figures"))
  message("Completed: ", normalizePath(out, winslash = "/")); invisible(results)
}
