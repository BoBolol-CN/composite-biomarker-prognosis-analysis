# Configuration, validation and data handling. No project-specific defaults.
`%||%` <- function(x, y) if (is.null(x)) y else x
need <- function(package) {
  if (!requireNamespace(package, quietly = TRUE))
    stop("Install the optional dependency: ", package, call. = FALSE)
}
slug <- function(x) gsub("[^A-Za-z0-9_-]", "_", x)
assert <- function(ok, message) if (!isTRUE(ok)) stop(message, call. = FALSE)
bind <- function(x) {
  x <- Filter(function(a) !is.null(a) && nrow(a) > 0L, x)
  if (!length(x)) return(data.frame())
  cols <- unique(unlist(lapply(x, names)))
  do.call(rbind, lapply(x, function(d) { d[setdiff(cols, names(d))] <- NA; d[, cols, drop = FALSE] }))
}
csv <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(x, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
}
warn_capture <- function(expr) {
  notes <- character()
  value <- withCallingHandlers(expr, warning = function(w) {
    notes <<- c(notes, conditionMessage(w)); invokeRestart("muffleWarning")
  })
  list(value = value, warnings = unique(notes))
}
load_table <- function(path) {
  assert(file.exists(path), paste("Input does not exist:", path))
  ext <- tolower(tools::file_ext(path))
  switch(ext,
    csv = utils::read.csv(path, check.names = FALSE, stringsAsFactors = FALSE),
    rds = as.data.frame(readRDS(path)),
    xlsx = { need("readxl"); as.data.frame(readxl::read_excel(path)) },
    stop("Supported input types: csv, rds, xlsx", call. = FALSE))
}
check_cfg <- function(cfg) {
  assert(is.list(cfg) && length(cfg$endpoints) > 0, "Define at least one endpoint.")
  assert(is.function(cfg$biomarker$compute), "biomarker$compute must be a function(data).")
  assert(length(cfg$biomarker$components) > 0, "Declare biomarker component columns.")
  ids <- vapply(cfg$endpoints, `[[`, "", "id")
  assert(!anyDuplicated(slug(ids)), "Endpoint identifiers must have unique filename-safe names.")
  allowed <- c("baseline", "cox", "spline", "km", "competing", "subgroup", "landmark", "center", "prediction")
  assert(all(cfg$modules %in% allowed), "Unknown module: use the documented module names.")
  assert(length(cfg$association$models) > 0 && !is.null(names(cfg$association$models)), "Name the adjustment models.")
  assert(is.finite(cfg$biomarker$scale %||% 1) && (cfg$biomarker$scale %||% 1) > 0, "Exposure scale must be positive.")
  invisible(cfg)
}
derive_index <- function(d, cfg) {
  assert(all(cfg$biomarker$components %in% names(d)), "Missing biomarker component columns.")
  x <- cfg$biomarker$compute(d)
  assert(is.numeric(x) && length(x) == nrow(d), "Biomarker computation must return one numeric value per row.")
  x[!is.finite(x)] <- NA_real_
  d$.bp_index <- x
  d$.bp_scaled <- x / (cfg$biomarker$scale %||% 1)
  d
}
prepare_data <- function(d, cfg) {
  assert(!anyDuplicated(names(d)), "Duplicate input column names.")
  assert(!any(grepl("^\\.bp_", names(d))), "Input columns starting .bp_ are reserved.")
  if (length(cfg$column_map)) for (canonical in names(cfg$column_map)) {
    source <- cfg$column_map[[canonical]]
    assert(source %in% names(d), paste("Missing source column:", source))
    assert(canonical == source || !canonical %in% names(d), paste("Mapping would overwrite:", canonical))
    names(d)[names(d) == source] <- canonical
  }
  numeric_cols <- unique(c(cfg$numeric_columns, cfg$biomarker$components))
  for (v in numeric_cols) {
    assert(v %in% names(d), paste("Missing numeric column:", v))
    raw <- as.character(d[[v]]); x <- suppressWarnings(as.numeric(raw))
    assert(!any(!is.na(raw) & nzchar(raw) & is.na(x)), paste("Non-numeric values in:", v))
    assert(all(is.finite(x) | is.na(x)), paste("Non-finite values in:", v))
    d[[v]] <- x
  }
  for (v in names(cfg$factors)) {
    assert(v %in% names(d), paste("Missing categorical column:", v))
    lev <- as.character(cfg$factors[[v]])
    raw <- as.character(d[[v]])
    assert(all(is.na(raw) | raw %in% lev), paste("Unmapped category in:", v))
    d[[v]] <- factor(raw, levels = lev)
  }
  if (!is.null(cfg$id_column)) {
    assert(cfg$id_column %in% names(d), "ID column not found.")
    assert(!anyNA(d[[cfg$id_column]]) && !anyDuplicated(d[[cfg$id_column]]),
           "This first-event runner requires one row per non-missing patient ID.")
  }
  for (ep in cfg$endpoints) {
    assert(ep$type %in% c("survival", "competing", "binary"), "Endpoint type must be survival, competing or binary.")
    assert(ep$status %in% names(d), paste("Missing endpoint status:", ep$status))
    raw <- as.character(d[[ep$status]]); s <- suppressWarnings(as.numeric(raw))
    codes <- if (ep$type == "competing") c(0, 1, 2) else c(0, 1)
    assert(all(is.na(raw) | (!is.na(s) & s %in% codes)), paste("Invalid status coding for:", ep$id))
    d[[ep$status]] <- s
    if (ep$type == "binary") {
      assert(isTRUE(ep$complete_horizon), "Binary outcomes require complete_horizon=TRUE; censored outcomes need survival methods.")
    } else {
      assert(ep$time %in% names(d), paste("Missing follow-up column:", ep$time))
      raw <- as.character(d[[ep$time]]); t <- suppressWarnings(as.numeric(raw))
      assert(all(is.na(raw) | (is.finite(t) & t > 0)), paste("Follow-up must be positive and numeric:", ep$id))
      d[[ep$time]] <- t
    }
  }
  d <- derive_index(d, cfg)
  # Group boundaries are learned once for descriptive/association use only.
  grouping <- cfg$biomarker$grouping
  if (!is.null(grouping)) {
    if (!is.null(grouping$breaks)) cuts <- grouping$breaks else {
      assert(all(grouping$probs > 0 & grouping$probs < 1), "Grouping probabilities must lie in (0,1).")
      cuts <- as.numeric(stats::quantile(d$.bp_index, grouping$probs, na.rm = TRUE))
    }
    assert(all(is.finite(cuts)) && !anyDuplicated(cuts) && !is.unsorted(cuts),
           "Repeated/invalid grouping cuts: use predefined breaks or fewer groups.")
    labs <- grouping$labels %||% paste0("G", seq_len(length(cuts) + 1))
    assert(length(labs) == length(cuts) + 1 && !anyDuplicated(labs), "Group labels do not match cuts.")
    d$.bp_group <- cut(d$.bp_index, c(-Inf, cuts, Inf), labels = labs, include.lowest = TRUE, right = TRUE)
    attr(d, "group_cuts") <- cuts
  }
  d
}
ep_data <- function(d, ep) {
  cols <- c(ep$status, if (ep$type != "binary") ep$time)
  d <- d[stats::complete.cases(d[, cols, drop = FALSE]), , drop = FALSE]
  d$.bp_event <- as.integer(d[[ep$status]] == (ep$cause %||% 1))
  if (ep$type != "binary") d$.bp_time <- d[[ep$time]]
  d
}
cox_formula <- function(exposure, covariates = character(), center = NULL, mode = NULL) {
  assert(all(make.names(covariates) == covariates), "Use syntactic canonical covariate names in column_map.")
  rhs <- c(exposure, covariates)
  if (!is.null(center)) rhs <- c(rhs, switch(mode, strata = paste0("strata(", center, ")"),
                                            fixed = paste0("factor(", center, ")"),
                                            cluster = paste0("cluster(", center, ")")))
  stats::as.formula(paste("survival::Surv(.bp_time, .bp_event) ~", paste(rhs, collapse = " + ")))
}
fit_cox <- function(d, formula) {
  need("survival")
  # survival specials resolve in the formula environment.
  strata <- survival::strata; cluster <- survival::cluster
  environment(formula) <- environment()
  fit <- survival::coxph(formula, data = d, ties = "efron", x = TRUE, y = TRUE, model = TRUE,
                         singular.ok = FALSE, na.action = stats::na.omit)
  assert(all(is.finite(stats::coef(fit))), "Non-finite Cox coefficients; inspect sparse data or separation.")
  fit
}
coef_table <- function(fit) {
  s <- summary(fit)
  data.frame(term = rownames(s$coefficients), estimate = s$coefficients[, "coef"],
             std_error = s$coefficients[, "se(coef)"], HR = s$conf.int[, "exp(coef)"],
             lower = s$conf.int[, "lower .95"], upper = s$conf.int[, "upper .95"],
             p = s$coefficients[, "Pr(>|z|)"], n = fit$n, events = fit$nevent, row.names = NULL)
}
run_baseline <- function(d, cfg, out) {
  vars <- unique(c(cfg$baseline_variables, cfg$biomarker$components, ".bp_index"))
  assert(all(vars %in% names(d)), "A baseline variable is absent.")
  groups <- list(Overall = rep(TRUE, nrow(d)))
  if (".bp_group" %in% names(d)) for (g in levels(d$.bp_group)) groups[[g]] <- !is.na(d$.bp_group) & d$.bp_group == g
  tab <- bind(lapply(names(groups), function(g) bind(lapply(vars, function(v) {
    x <- d[[v]][groups[[g]]]; n <- length(x); available <- sum(!is.na(x))
    if (is.numeric(x)) {
      q <- if (available) stats::quantile(x, c(.25, .5, .75), na.rm = TRUE) else rep(NA_real_, 3)
      data.frame(group = g, variable = v, level = "", n = n, observed = available,
                 missing = n - available, value = sprintf("%.2f [%.2f, %.2f]", q[2], q[1], q[3]))
    } else {
      tt <- table(x, useNA = "no")
      data.frame(group = g, variable = v, level = names(tt), n = n, observed = available,
                 missing = n - available, value = sprintf("%d (%.1f%%)", as.integer(tt), 100 * as.integer(tt) / available))
    }
  }))))
  csv(tab, file.path(out, "baseline.csv"))
  csv(data.frame(variable = names(d), missing = colSums(is.na(d)), n = nrow(d)), file.path(out, "missingness.csv"))
  tab
}
# Construct a first-event endpoint from actual event times, not final flags.
first_event <- function(target_time, competing_time, censor_time, tie = c("error", "target", "competing")) {
  tie <- match.arg(tie)
  assert(length(target_time) == length(censor_time) && length(competing_time) == length(censor_time), "Event-time lengths differ.")
  assert(all(is.finite(censor_time) & censor_time > 0), "Censor times must be known and positive.")
  assert(all(is.na(target_time) | (is.finite(target_time) & target_time > 0)) &&
           all(is.na(competing_time) | (is.finite(competing_time) & competing_time > 0)), "Invalid event time.")
  a <- ifelse(is.na(target_time), Inf, target_time); b <- ifelse(is.na(competing_time), Inf, competing_time)
  ties <- is.finite(a) & a == b & a <= censor_time
  if (tie == "error") assert(!any(ties), "Specify the rule for simultaneous target and competing events.")
  time <- pmin(a, b, censor_time)
  status <- ifelse(a <= censor_time & a < b, 1L, ifelse(b <= censor_time & b < a, 2L, 0L))
  status[ties] <- if (tie == "target") 1L else 2L
  data.frame(time = time, status = status)
}
