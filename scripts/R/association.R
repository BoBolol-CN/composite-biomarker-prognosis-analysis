run_cox <- function(d, cfg, ep, out, suffix = "", center = NULL, center_mode = NULL) {
  if (ep$type == "binary") return(invisible(NULL))
  ed <- ep_data(d, ep); tables <- list(); fits <- list()
  forms <- cfg$association$exposures %||% "continuous"
  for (m in names(cfg$association$models)) for (form in forms) {
    covs <- cfg$association$models[[m]]
    exposure <- if (form == "continuous") ".bp_scaled" else ".bp_group"
    assert(form %in% c("continuous", "grouped") && exposure %in% names(ed), "Unknown/missing exposure form.")
    f <- cox_formula(exposure, covs, center, center_mode)
    captured <- warn_capture(fit_cox(ed, f)); fit <- captured$value
    tab <- coef_table(fit); tab$endpoint <- ep$id; tab$model <- m; tab$form <- form
    tab$qualification <- paste(c(if (ep$type == "competing") "Cause-specific HR" else "Cox HR", captured$warnings), collapse = "; ")
    tables[[paste(m, form)]] <- tab
    fits[[paste(m, form, sep = "__")]] <- fit
  }
  table <- bind(tables)
  prefix <- paste0(slug(ep$id), suffix)
  csv(table, file.path(out, paste0(prefix, "_cox.csv")))
  saveRDS(fits, file.path(out, paste0(prefix, "_cox_models.rds")))
  # Diagnostics on the prespecified final adjustment model and continuous effect.
  key <- paste(tail(names(cfg$association$models), 1), forms[1], sep = "__")
  fit <- fits[[key]]
  diag <- warn_capture(survival::cox.zph(fit))
  ph <- data.frame(term = rownames(diag$value$table), diag$value$table, row.names = NULL)
  csv(ph, file.path(out, paste0(prefix, "_ph.csv")))
  if (isTRUE(cfg$plots$diagnostics)) {
    grDevices::pdf(file.path(out, paste0(prefix, "_ph.pdf")), width = 8, height = 6)
    tryCatch(plot(diag$value), finally = grDevices::dev.off())
  }
  if (ncol(fit$x) > 1) {
    v <- tryCatch(diag(solve(stats::cor(fit$x))), error = function(e) rep(NA_real_, ncol(fit$x)))
    csv(data.frame(design_column = colnames(fit$x), VIF = as.numeric(v),
                   qualification = "Design-column VIF; not multi-df term GVIF"), file.path(out, paste0(prefix, "_vif.csv")))
  }
  invisible(list(table = table, fits = fits))
}
run_mi_cox <- function(d, cfg, ep, out) {
  need("mice")
  mi <- cfg$association$imputation
  assert(ep$type != "binary", "MI module currently supports Cox endpoints.")
  assert(identical(cfg$association$exposures, "continuous"), "MI pooling currently supports continuous exposure only; set exposures='continuous'.")
  assert(!any(c("spline", "subgroup", "landmark", "center", "competing") %in% cfg$modules),
         "MI pooling is implemented for Cox only. Run optional inference modules under a separately specified plan.")
  ed <- ep_data(d, ep)
  vars <- unique(c(mi$variables, cfg$biomarker$components, unlist(cfg$association$models), ep$time, ep$status))
  assert(all(vars %in% names(ed)), "MI variable missing.")
  assert(all(make.names(vars) == vars), "Use canonical syntactic column names for MI.")
  x <- ed[, vars, drop = FALSE]
  meth <- mice::make.method(x)
  meth[c(ep$time, ep$status)] <- ""  # Outcomes are observed; used as predictors, not imputed.
  if (!is.null(mi$method)) meth[names(mi$method)] <- mi$method
  assert(all(meth[c(ep$time, ep$status)] == ""), "Do not impute outcome columns in this baseline MI helper.")
  assert(is.numeric(mi$m) && mi$m >= 2, "Set at least two imputations with a study-specific rationale.")
  imp <- mice::mice(x, m = mi$m, maxit = mi$maxit %||% 20, method = meth,
                    predictorMatrix = mi$predictor_matrix %||% mice::make.predictorMatrix(x),
                    seed = cfg$seed, printFlag = FALSE)
  saveRDS(imp, file.path(out, paste0(slug(ep$id), "_imputations.rds")))
  completed <- lapply(seq_len(mi$m), function(i) derive_index(mice::complete(imp, i), cfg))
  results <- lapply(names(cfg$association$models), function(m) {
    f <- cox_formula(".bp_scaled", cfg$association$models[[m]])
    fits <- lapply(completed, function(z) fit_cox(ep_data(z, ep), f))
    pooled <- summary(mice::pool(mice::as.mira(fits)), conf.int = TRUE)
    data.frame(term = pooled$term, estimate = pooled$estimate, std_error = pooled$std.error,
               HR = exp(pooled$estimate), lower = exp(pooled$conf.low), upper = exp(pooled$conf.high),
               p = pooled$p.value, n = fits[[1]]$n, events = fits[[1]]$nevent,
               endpoint = ep$id, model = m, form = "continuous", qualification = "Rubin-pooled Cox; assess imputation diagnostics")
  })
  table <- bind(results); csv(table, file.path(out, paste0(slug(ep$id), "_cox.csv")))
  invisible(list(table = table, imputation = imp))
}
run_spline <- function(d, cfg, ep, out) {
  if (ep$type == "binary") return(NULL)
  ed <- ep_data(d, ep); covs <- tail(cfg$association$models, 1)[[1]]
  ed <- ed[stats::complete.cases(ed[, c(".bp_index", covs), drop = FALSE]), , drop = FALSE]
  assert(nrow(ed) > 0 && length(unique(ed$.bp_index)) > 6, "Insufficient unique exposure values for spline.")
  k <- cfg$association$spline_df %||% 3
  full <- fit_cox(ed, cox_formula(paste0("splines::ns(.bp_index, df = ", k, ")"), covs))
  linear <- fit_cox(ed, cox_formula(".bp_index", covs))
  null <- fit_cox(ed, cox_formula(if (length(covs)) covs[1] else "1", if (length(covs)) covs[-1] else character()))
  lrt <- function(a, b) {
    delta <- 2 * (as.numeric(logLik(b)) - as.numeric(logLik(a)))
    df <- attr(logLik(b), "df") - attr(logLik(a), "df")
    stats::pchisq(delta, df, lower.tail = FALSE)
  }
  ref <- cfg$association$spline_reference %||% stats::median(ed$.bp_index)
  grid <- as.numeric(stats::quantile(ed$.bp_index, cfg$association$spline_range %||% c(.02, .98)))
  g <- seq(grid[1], grid[2], length.out = 160)
  nd <- ed[rep(1, length(g)), , drop = FALSE]; nd$.bp_index <- g
  rd <- nd; rd$.bp_index <- ref
  delta <- stats::model.matrix(full, nd) - stats::model.matrix(full, rd)
  b <- stats::coef(full); se <- sqrt(pmax(0, rowSums((delta %*% stats::vcov(full)) * delta)))
  lp <- as.vector(delta %*% b)
  result <- data.frame(index = g, HR = exp(lp), lower = exp(lp - 1.96 * se), upper = exp(lp + 1.96 * se),
                       reference = ref, p_overall = lrt(null, full), p_nonlinear = lrt(linear, full), n = full$n, events = full$nevent)
  csv(result, file.path(out, paste0(slug(ep$id), "_spline.csv")))
  saveRDS(full, file.path(out, paste0(slug(ep$id), "_spline_model.rds")))
  result
}
run_km <- function(d, cfg, ep, out) {
  if (ep$type != "survival" || !".bp_group" %in% names(d)) return(NULL)
  ed <- ep_data(d, ep); ed <- ed[!is.na(ed$.bp_group), , drop = FALSE]
  fit <- survival::survfit(survival::Surv(.bp_time, .bp_event) ~ .bp_group, data = ed)
  s <- summary(fit)
  tab <- data.frame(time = s$time, survival = s$surv, lower = s$lower, upper = s$upper,
                    group = sub("^.*=", "", as.character(s$strata)))
  lr <- survival::survdiff(survival::Surv(.bp_time, .bp_event) ~ .bp_group, data = ed)
  attr(tab, "logrank_p") <- stats::pchisq(lr$chisq, length(lr$n) - 1, lower.tail = FALSE)
  times <- cfg$report_times %||% pretty(range(ed$.bp_time), 5)
  fixed <- summary(fit, times = times, extend = FALSE)
  risk <- data.frame(time = fixed$time, n_risk = fixed$n.risk, survival = fixed$surv,
                     cumulative_risk = 1 - fixed$surv, lower = 1 - fixed$upper, upper = 1 - fixed$lower,
                     group = sub("^.*=", "", as.character(fixed$strata)))
  csv(tab, file.path(out, paste0(slug(ep$id), "_km.csv")))
  csv(risk, file.path(out, paste0(slug(ep$id), "_risk_table.csv")))
  list(curve = tab, risk = risk, n = nrow(ed), p = attr(tab, "logrank_p"))
}
run_competing <- function(d, cfg, ep, out) {
  if (ep$type != "competing") return(NULL)
  need("cmprsk"); ed <- ep_data(d, ep)
  assert(".bp_group" %in% names(ed), "CIF display requires configured groups.")
  ed <- ed[!is.na(ed$.bp_group), , drop = FALSE]
  ci <- cmprsk::cuminc(ed$.bp_time, ed[[ep$status]], group = ed$.bp_group, cencode = 0)
  curves <- bind(lapply(setdiff(names(ci), "Tests"), function(key) {
    # Last token is cause; labels may contain spaces.
    cause <- sub("^.* ", "", key)
    if (cause != as.character(ep$cause %||% 1)) return(NULL)
    obj <- ci[[key]]
    data.frame(time = obj$time, risk = obj$est, lower = pmax(0, obj$est - 1.96 * sqrt(obj$var)),
               upper = pmin(1, obj$est + 1.96 * sqrt(obj$var)), group = sub(" [^ ]+$", "", key))
  }))
  csv(curves, file.path(out, paste0(slug(ep$id), "_cif.csv")))
  if (!is.null(ci$Tests)) csv(data.frame(cause = rownames(ci$Tests), ci$Tests), file.path(out, paste0(slug(ep$id), "_gray_tests.csv")))
  covs <- tail(cfg$association$models, 1)[[1]]
  cc <- ed[stats::complete.cases(ed[, c(".bp_scaled", covs), drop = FALSE]), , drop = FALSE]
  mat <- stats::model.matrix(stats::reformulate(c(".bp_scaled", covs)), cc)[, -1, drop = FALSE]
  cap <- warn_capture(cmprsk::crr(cc$.bp_time, cc[[ep$status]], mat, failcode = ep$cause %||% 1, cencode = 0))
  fg <- cap$value; assert(isTRUE(fg$converged), "Fine-Gray did not converge.")
  se <- sqrt(diag(fg$var)); b <- fg$coef
  tab <- data.frame(term = names(b), SHR = exp(b), lower = exp(b - 1.96 * se), upper = exp(b + 1.96 * se),
                     p = 2 * stats::pnorm(-abs(b / se)), n = nrow(cc), events = sum(cc[[ep$status]] == (ep$cause %||% 1)), warnings = paste(cap$warnings, collapse = "; "))
  csv(tab, file.path(out, paste0(slug(ep$id), "_fine_gray.csv")))
  list(curve = curves, n = nrow(ed), model = fg)
}
run_sensitivity <- function(d, cfg, ep, out) {
  if (ep$type == "binary") return(NULL)
  ed <- ep_data(d, ep); covs <- tail(cfg$association$models, 1)[[1]]
  rows <- list()
  fit_one <- function(z, label, adjust = covs, center = NULL, mode = NULL) {
    cap <- tryCatch(warn_capture(fit_cox(z, cox_formula(".bp_scaled", adjust, center, mode))), error = identity)
    if (inherits(cap, "error")) return(data.frame(analysis = label, status = "failed", qualification = conditionMessage(cap)))
    tab <- coef_table(cap$value); tab <- tab[tab$term == ".bp_scaled", , drop = FALSE]
    tab$analysis <- label; tab$status <- "completed"; tab$qualification <- paste(cap$warnings, collapse = "; "); tab
  }
  if ("landmark" %in% cfg$modules) for (lm in cfg$association$landmarks) {
    z <- ed[ed$.bp_time > lm, , drop = FALSE]; z$.bp_time <- z$.bp_time - lm
    rows[[paste0("landmark_", lm)]] <- fit_one(z, paste("landmark", lm, ep$unit))
  }
  if ("subgroup" %in% cfg$modules) for (v in cfg$association$subgroups) {
    assert(v %in% names(ed) && is.factor(ed[[v]]), "Subgroups must be predeclared factors; define clinical cuts explicitly.")
    p <- tryCatch({
      f0 <- fit_cox(ed, cox_formula(".bp_scaled", unique(c(covs, v))))
      f1 <- fit_cox(ed, cox_formula(paste0(".bp_scaled * ", v), setdiff(covs, v)))
      stats::pchisq(2 * (as.numeric(logLik(f1)) - as.numeric(logLik(f0))), attr(logLik(f1), "df") - attr(logLik(f0), "df"), lower.tail = FALSE)
    }, error = function(e) NA_real_)
    for (lev in levels(ed[[v]])) {
      z <- ed[!is.na(ed[[v]]) & ed[[v]] == lev, , drop = FALSE]
      tab <- fit_one(z, paste(v, lev, sep = ": "), setdiff(covs, v)); tab$p_interaction <- p
      rows[[paste(v, lev)]] <- tab
    }
  }
  if ("center" %in% cfg$modules && !is.null(cfg$center_column)) {
    center <- cfg$center_column; assert(center %in% names(ed) && make.names(center) == center, "Invalid center column.")
    for (mode in cfg$association$center_methods %||% c("strata", "fixed")) {
      if (mode == "leave_one_out") for (lev in unique(ed[[center]])) {
        z <- ed[!is.na(ed[[center]]) & ed[[center]] != lev, , drop = FALSE]
        rows[[paste("omit", lev)]] <- fit_one(z, paste("omit center", lev))
      } else {
        assert(mode %in% c("cluster", "strata", "fixed"), "Unknown center sensitivity method.")
        rows[[mode]] <- fit_one(ed, paste("center", mode), setdiff(covs, center), center, mode)
      }
    }
  }
  tab <- bind(rows); csv(tab, file.path(out, paste0(slug(ep$id), "_sensitivity.csv"))); tab
}
