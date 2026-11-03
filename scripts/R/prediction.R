# All preprocessing and model selection are fitted within development folds.
fit_preprocessor <- function(d, variables) {
  assert(length(variables) > 0 && all(variables %in% names(d)), "Missing prediction feature.")
  recipe <- list(variables = variables, numeric = list(), categorical = list(), active = character())
  for (v in variables) {
    x <- d[[v]]
    if (is.numeric(x)) {
      assert(any(is.finite(x)), paste("Entirely missing numeric training feature:", v))
      med <- stats::median(x, na.rm = TRUE); x[is.na(x)] <- med
      mu <- mean(x); sd <- stats::sd(x)
      recipe$numeric[[v]] <- list(median = med, mean = mu, sd = sd)
      if (is.finite(sd) && sd > 0) recipe$active <- c(recipe$active, v)
    } else {
      tt <- table(as.character(x), useNA = "no")
      assert(length(tt) > 0, paste("Entirely missing categorical training feature:", v))
      lev <- sort(names(tt)); recipe$categorical[[v]] <- list(levels = lev, mode = names(which.max(tt)))
      if (length(lev) > 1) recipe$active <- c(recipe$active, v)
    }
  }
  assert(length(recipe$active) > 0, "No non-constant training features.")
  recipe$formula <- stats::reformulate(recipe$active, intercept = TRUE, env = baseenv())
  recipe$columns <- colnames(apply_preprocessor(d, recipe, check_columns = FALSE))
  recipe
}
apply_preprocessor <- function(d, recipe, check_columns = TRUE) {
  assert(all(recipe$variables %in% names(d)), "Required prediction columns are absent.")
  z <- d[, recipe$variables, drop = FALSE]
  for (v in names(recipe$numeric)) {
    p <- recipe$numeric[[v]]
    assert(is.numeric(z[[v]]) && all(is.finite(z[[v]]) | is.na(z[[v]])), paste("Numeric feature invalid:", v))
    z[[v]][is.na(z[[v]])] <- p$median
    z[[v]] <- if (is.finite(p$sd) && p$sd > 0) (z[[v]] - p$mean) / p$sd else 0
  }
  for (v in names(recipe$categorical)) {
    p <- recipe$categorical[[v]]; x <- as.character(z[[v]])
    assert(all(is.na(x) | x %in% p$levels), paste("Unseen category in frozen model:", v))
    x[is.na(x)] <- p$mode; z[[v]] <- factor(x, levels = p$levels)
  }
  X <- stats::model.matrix(recipe$formula, z)
  X <- X[, colnames(X) != "(Intercept)", drop = FALSE]
  if (check_columns) {
    assert(setequal(colnames(X), recipe$columns), "Prediction design-matrix columns changed.")
    X <- X[, recipe$columns, drop = FALSE]
  }
  X
}
fit_candidate <- function(d, ep, spec, cfg) {
  recipe <- fit_preprocessor(d, spec$variables); X <- apply_preprocessor(d, recipe); y <- d[[ep$status]]
  algorithm <- spec$algorithm
  if (ep$type != "binary") assert(algorithm == "cox", "Censored endpoints currently use Cox prediction; classifiers require complete fixed-horizon outcomes.")
  if (ep$type == "binary") assert(algorithm != "cox", "Use a binary candidate for a binary endpoint.")
  set.seed(cfg$seed)
  model <- switch(algorithm,
    cox = {
      z <- as.data.frame(X); names(z) <- paste0("x", seq_len(ncol(X)))
      z$.bp_time <- d[[ep$time]]; z$.bp_event <- y
      fit <- fit_cox(z, cox_formula(names(z)[seq_len(ncol(X))]))
      list(fit = fit, baseline = survival::basehaz(fit, centered = FALSE), columns = names(z)[seq_len(ncol(X))])
    },
    logistic = {
      fit <- stats::glm.fit(cbind(Intercept = 1, X), y, family = stats::binomial())
      assert(isTRUE(fit$converged) && all(is.finite(fit$coefficients)), "Logistic model failed or rank deficient.")
      fit
    },
    ridge = {
      need("glmnet"); assert(is.finite(spec$lambda) && spec$lambda > 0, "Specify a positive fixed lambda; tune via development candidate grid.")
      glmnet::glmnet(X, y, family = "binomial", alpha = spec$alpha %||% 0,
                     lambda = spec$lambda, standardize = FALSE)
    },
    decision_tree = {
      need("rpart"); z <- as.data.frame(X); z$outcome <- factor(y, levels = 0:1, labels = c("no", "yes"))
      rpart::rpart(outcome ~ ., z, method = "class", control = rpart::rpart.control(cp = spec$cp %||% .02,
                    minbucket = spec$minbucket %||% 15, xval = 0))
    },
    random_forest = {
      need("ranger"); z <- as.data.frame(X); z$outcome <- factor(y, levels = 0:1, labels = c("no", "yes"))
      ranger::ranger(outcome ~ ., z, probability = TRUE, num.trees = spec$num_trees %||% 300,
                     min.node.size = spec$min_node_size %||% 15,
                     mtry = min(ncol(X), spec$mtry %||% max(1, floor(sqrt(ncol(X))))), seed = cfg$seed, num.threads = 1)
    },
    svm = {
      need("e1071"); e1071::svm(X, factor(y, levels = 0:1, labels = c("no", "yes")),
                                kernel = "radial", scale = FALSE, probability = TRUE,
                                cost = spec$cost %||% 1, gamma = spec$gamma %||% (1 / ncol(X)))
    },
    knn = { need("class"); assert((spec$k %||% 15) <= nrow(X), "K exceeds training sample size."); list(X = X, y = factor(y, levels = 0:1), k = spec$k %||% 15) },
    neural_net = {
      need("nnet"); fit <- nnet::nnet(X, y, size = spec$size %||% 3, decay = spec$decay %||% .1,
                                    maxit = spec$maxit %||% 300, entropy = TRUE, trace = FALSE, MaxNWts = 10000)
      assert(fit$convergence == 0, "Neural-network optimizer did not converge."); fit
    },
    xgboost = {
      need("xgboost"); params <- utils::modifyList(list(objective = "binary:logistic", eval_metric = "logloss",
        max_depth = 2, eta = .03, nthread = 1, seed = cfg$seed), spec$params %||% list())
      xgboost::xgb.train(params = params, data = xgboost::xgb.DMatrix(X, label = y), nrounds = spec$nrounds %||% 100, verbose = 0)
    },
    lightgbm = {
      need("lightgbm"); params <- utils::modifyList(list(objective = "binary", metric = "binary_logloss",
        num_leaves = 7, learning_rate = .03, verbosity = -1, num_threads = 1, seed = cfg$seed), spec$params %||% list())
      lightgbm::lgb.train(params = params, data = lightgbm::lgb.Dataset(X, label = y), nrounds = spec$nrounds %||% 100)
    }, stop("Unknown candidate algorithm: ", algorithm, call. = FALSE))
  list(algorithm = algorithm, model = model, recipe = recipe, specification = spec,
       endpoint_type = ep$type, horizon = ep$horizon, package_versions = sessionInfo())
}
predict_candidate <- function(bundle, d) {
  X <- apply_preprocessor(d, bundle$recipe); m <- bundle$model
  p <- switch(bundle$algorithm,
    cox = {
      z <- as.data.frame(X); names(z) <- m$columns
      lp <- stats::predict(m$fit, z, type = "lp", reference = "zero")
      bh <- m$baseline$hazard[m$baseline$time <= bundle$horizon]
      h <- if (length(bh)) tail(bh, 1) else 0
      1 - exp(-h * exp(lp))
    },
    logistic = stats::plogis(as.vector(cbind(1, X) %*% m$coefficients)),
    ridge = as.numeric(stats::predict(m, X, s = bundle$specification$lambda, type = "response")),
    decision_tree = stats::predict(m, as.data.frame(X), type = "prob")[, "yes"],
    random_forest = stats::predict(m, as.data.frame(X))$predictions[, "yes"],
    svm = attr(stats::predict(m, X, probability = TRUE), "probabilities")[, "yes"],
    knn = { v <- class::knn(m$X, X, m$y, k = m$k, prob = TRUE); pr <- attr(v, "prob"); ifelse(v == "1", pr, 1 - pr) },
    neural_net = as.numeric(stats::predict(m, X, type = "raw")),
    xgboost = stats::predict(m, xgboost::xgb.DMatrix(X)),
    lightgbm = stats::predict(m, X))
  assert(length(p) == nrow(d) && all(is.finite(p) & p >= 0 & p <= 1), "Invalid predicted probabilities.")
  as.numeric(p)
}
horizon_observations <- function(d, ep) {
  y <- d[[ep$status]]
  if (ep$type == "binary") return(list(y = y, w = rep(1, length(y))))
  tau <- ep$horizon; t <- d[[ep$time]]
  assert(is.finite(tau) && tau > 0 && any(t > tau), "Prediction horizon lacks follow-up support.")
  gfit <- survival::survfit(survival::Surv(t, 1 - y) ~ 1)
  G <- function(at, left = FALSE) {
    idx <- findInterval(at, gfit$time, left.open = left)
    c(1, gfit$surv)[idx + 1L]
  }
  event <- y == 1 & t <= tau; control <- t > tau
  g <- rep(1, length(y)); g[event] <- G(t[event], left = TRUE); g[control] <- G(tau)
  assert(all(g[event | control] > .01), "Censoring weights unstable; use a supported horizon.")
  w <- ifelse(event | control, 1 / g, 0)
  list(y = as.integer(event), w = w)
}
weighted_auc <- function(y, p, w) {
  keep <- w > 0; y <- y[keep]; p <- p[keep]; w <- w[keep]
  assert(sum(w[y == 1]) > 0 && sum(w[y == 0]) > 0, "AUC requires weighted cases and controls.")
  o <- order(p); y <- y[o]; p <- p[o]; w <- w[o]
  pos <- rowsum(w * y, p, reorder = FALSE)[, 1]
  neg <- rowsum(w * (1 - y), p, reorder = FALSE)[, 1]
  sum(pos * (cumsum(neg) - .5 * neg)) / (sum(pos) * sum(neg))
}
score_prediction <- function(d, ep, p) {
  o <- horizon_observations(d, ep)
  p <- pmin(1 - 1e-8, pmax(1e-8, p))
  c(AUC = weighted_auc(o$y, p, o$w), Brier = mean(o$w * (o$y - p)^2),
    LogLoss = mean(o$w * (-o$y * log(p) - (1 - o$y) * log(1 - p))))
}
prediction_split <- function(d, ep, spec, seed) {
  set.seed(seed); frac <- spec$train_fraction %||% .75
  assert(frac > 0 && frac < 1, "Train fraction must be in (0,1).")
  if (!is.null(spec$group_column)) {
    g <- d[[spec$group_column]]; assert(!is.null(g) && !anyNA(g), "Missing split group.")
    groups <- sample(unique(g)); k <- max(1, min(length(groups) - 1, floor(frac * length(groups))))
    assert(length(groups) >= 2, "Need multiple split groups."); which(g %in% groups[seq_len(k)])
  } else if (!is.null(spec$time_column)) {
    t <- d[[spec$time_column]]; assert(!is.null(t) && !anyNA(t), "Missing split ordering time.")
    order(t)[seq_len(floor(frac * nrow(d)))]
  } else unlist(lapply(split(seq_len(nrow(d)), d[[ep$status]]), function(ids) {
    assert(length(ids) >= 4, "Too few patients in an outcome stratum to split.")
    sample(ids, max(1, min(length(ids) - 1, floor(length(ids) * frac))))
  }), use.names = FALSE)
}
development_folds <- function(d, ep, cfg) {
  k <- cfg$prediction$folds %||% 5; assert(k >= 2, "Need at least two development folds.")
  set.seed(cfg$seed + 1); fold <- integer(nrow(d)); grp <- cfg$prediction$split$group_column
  if (!is.null(grp)) {
    groups <- sample(unique(d[[grp]])); assert(length(groups) >= k, "Fewer development groups than folds.")
    fold <- rep_len(seq_len(k), length(groups))[match(d[[grp]], groups)]
  } else for (ids in split(seq_len(nrow(d)), d[[ep$status]])) {
    assert(length(ids) >= k, "Fewer observations in an outcome stratum than folds.")
    fold[ids] <- sample(rep_len(seq_len(k), length(ids)))
  }
  fold
}
evaluate_predictions <- function(d, ep, p, cfg, label) {
  score <- score_prediction(d, ep, p); B <- cfg$prediction$bootstrap %||% 200
  assert(B >= 20, "Use at least 20 bootstrap replicates; increase for final research.")
  set.seed(cfg$seed + 77)
  boot <- replicate(B, {
    group_column <- cfg$prediction$bootstrap_group_column
    ids <- if (is.null(group_column)) sample.int(nrow(d), replace = TRUE) else {
      group <- d[[group_column]]
      assert(!is.null(group) && !anyNA(group), "Missing bootstrap group column.")
      unlist(lapply(sample(unique(as.character(group)), replace = TRUE), function(g) which(as.character(group) == g)), use.names = FALSE)
    }
    tryCatch(score_prediction(d[ids, , drop = FALSE], ep, p[ids]), error = function(e) rep(NA_real_, 3))
  })
  valid <- colSums(is.finite(boot)) == 3
  assert(sum(valid) >= .8 * B, "Too many invalid bootstrap samples; evaluation is not reliable.")
  ci <- t(apply(boot[, valid, drop = FALSE], 1, stats::quantile, c(.025, .975)))
  o <- horizon_observations(d, ep); known <- o$w > 0
  lp <- stats::qlogis(pmin(1 - 1e-8, pmax(1e-8, p)))
  z <- data.frame(y = o$y[known], lp = lp[known], w = o$w[known])
  cal <- suppressWarnings(stats::glm(y ~ lp, z, weights = w, family = stats::binomial()))
  int <- suppressWarnings(stats::glm(y ~ 1 + offset(lp), z, weights = w, family = stats::binomial()))
  table <- data.frame(dataset = label, metric = names(score), estimate = as.numeric(score), lower = ci[, 1], upper = ci[, 2],
                      n = nrow(d), events = sum(o$y), horizon = ep$horizon, bootstrap_valid = sum(valid), bootstrap_attempted = B,
                      method = if (ep$type == "binary") "Frozen-prediction bootstrap" else "Marginal IPCW; frozen-prediction bootstrap")
  calibration <- data.frame(dataset = label, intercept = stats::coef(int)[1], slope = stats::coef(cal)[2],
                            method = "Diagnostic weighted logistic calibration; slope not exempt by algorithm")
  cuts <- unique(stats::quantile(p, seq(0, 1, length.out = 9)))
  bins <- if (length(cuts) > 1) cut(p, cuts, include.lowest = TRUE) else factor(rep("All", length(p)))
  bin_table <- bind(lapply(levels(bins), function(b) {
    ids <- which(bins == b); weight <- o$w[ids]
    if (!length(ids) || sum(weight) == 0) return(NULL)
    data.frame(predicted = mean(p[ids]), observed = sum(weight * o$y[ids]) / sum(weight), n = length(ids), events = sum(o$y[ids]))
  }))
  thresholds <- cfg$prediction$decision_thresholds %||% seq(.05, .5, by = .01)
  dca <- bind(lapply(thresholds, function(t) {
    assert(t > 0 && t < 1, "Decision thresholds must lie in (0,1).")
    positive <- p >= t
    data.frame(threshold = t, net_benefit = mean(o$w * (positive * o$y - positive * (1 - o$y) * t / (1 - t))),
               treat_all = mean(o$w * (o$y - (1 - o$y) * t / (1 - t))))
  }))
  # Weighted ROC with direction fixed: larger risk means greater event probability.
  thresholds <- c(Inf, sort(unique(p), decreasing = TRUE), -Inf)
  roc <- bind(lapply(thresholds, function(t) data.frame(
    fpr = sum(o$w * (1 - o$y) * (p >= t)) / sum(o$w * (1 - o$y)),
    tpr = sum(o$w * o$y * (p >= t)) / sum(o$w * o$y))))
  list(metrics = table, calibration = calibration, bins = bin_table, roc = roc, dca = dca)
}
run_prediction <- function(d, cfg, out) {
  ep <- Filter(function(e) e$id == cfg$prediction$endpoint, cfg$endpoints)
  assert(length(ep) == 1, "Prediction endpoint must identify exactly one configured endpoint."); ep <- ep[[1]]
  assert(ep$type != "competing", "Competing-risk prediction is not implemented; do not repurpose classifiers or ordinary survival risk.")
  assert(!is.null(ep$horizon) && ep$horizon > 0, "Define prediction horizon.")
  ed <- ep_data(d, ep); specs <- cfg$prediction$candidates
  assert(length(specs) > 0 && !is.null(names(specs)) && !anyDuplicated(slug(names(specs))), "Name prediction candidates uniquely.")
  forbidden <- unique(c(cfg$id_column, cfg$center_column, ".bp_group", unlist(lapply(cfg$endpoints, function(e) c(e$status, e$time)))))
  for (spec in specs) assert(!any(spec$variables %in% forbidden), "Identifiers, event statuses and follow-up times cannot be prediction features.")
  train_ids <- prediction_split(ed, ep, cfg$prediction$split, cfg$seed)
  train <- ed[train_ids, , drop = FALSE]; test <- ed[-train_ids, , drop = FALSE]
  fold <- development_folds(train, ep, cfg); scores <- list(); models <- list(); predictions <- list()
  for (id in names(specs)) {
    oof <- rep(NA_real_, nrow(train)); warning_log <- character()
    trial <- tryCatch({
      for (f in sort(unique(fold))) {
        cap <- warn_capture(fit_candidate(train[fold != f, , drop = FALSE], ep, specs[[id]], cfg))
        warning_log <- c(warning_log, cap$warnings)
        oof[fold == f] <- predict_candidate(cap$value, train[fold == f, , drop = FALSE])
      }
      score <- score_prediction(train, ep, oof)
      fit <- warn_capture(fit_candidate(train, ep, specs[[id]], cfg)); warning_log <- c(warning_log, fit$warnings)
      list(score = score, fit = fit$value)
    }, error = identity)
    if (inherits(trial, "error")) {
      scores[[id]] <- data.frame(candidate = id, status = "failed", loss = NA_real_, qualification = conditionMessage(trial))
    } else {
      loss <- if (ep$type == "binary") trial$score["LogLoss"] else trial$score["Brier"]
      scores[[id]] <- data.frame(candidate = id, status = "completed", loss = as.numeric(loss), qualification = paste(unique(warning_log), collapse = "; "))
      models[[id]] <- trial$fit; predictions[[id]] <- list(oof = oof)
    }
  }
  cv <- bind(scores); csv(cv, file.path(out, "prediction_development_cv.csv"))
  valid <- cv$status == "completed" & is.finite(cv$loss)
  assert(any(valid), "All candidates failed; see prediction_development_cv.csv.")
  selected <- cv$candidate[which.min(ifelse(valid, cv$loss, Inf))]
  # Selection is finalized BEFORE final test predictions/evaluation are requested.
  data_config <- cfg[c("id_column", "column_map", "numeric_columns", "factors", "biomarker")]
  data_config$biomarker$grouping <- NULL; data_config$endpoints <- list()
  required <- unique(c(models[[selected]]$specification$variables, cfg$biomarker$components, cfg$id_column))
  data_config$numeric_columns <- intersect(cfg$numeric_columns, required)
  data_config$factors <- cfg$factors[intersect(names(cfg$factors), required)]
  data_config$column_map <- cfg$column_map[intersect(names(cfg$column_map), required)]
  saveRDS(list(selected = selected, models = models, endpoint = ep, cfg = cfg$prediction, data_config = data_config,
               selection = cv, seed = cfg$seed, development_rows = train_ids, folds = fold), file.path(out, "frozen_prediction_models.rds"))
  evaluations <- list()
  for (id in names(models)) {
    p <- predict_candidate(models[[id]], test)
    ev <- evaluate_predictions(test, ep, p, cfg, "Test")
    ev$metrics$candidate <- id; ev$metrics$selected_by_development <- id == selected
    evaluations[[id]] <- ev; predictions[[id]]$test <- p
    csv(ev$metrics, file.path(out, paste0(slug(id), "_test_metrics.csv")))
    csv(ev$calibration, file.path(out, paste0(slug(id), "_test_calibration.csv")))
  }
  external <- NULL
  if (!is.null(cfg$prediction$external_input)) {
    raw <- load_table(cfg$prediction$external_input)
    external_cfg <- data_config; external_cfg$endpoints <- list(ep)
    ep_columns <- c(ep$status, ep$time)
    external_cfg$column_map <- c(external_cfg$column_map, cfg$column_map[intersect(names(cfg$column_map), ep_columns)])
    ext <- ep_data(prepare_data(raw, external_cfg), ep)
    external <- evaluate_predictions(ext, ep, predict_candidate(models[[selected]], ext), cfg, "External")
    csv(external$metrics, file.path(out, "external_metrics.csv"))
    csv(external$calibration, file.path(out, "external_calibration.csv"))
  }
  if (isTRUE(cfg$prediction$save_individual_predictions)) saveRDS(predictions, file.path(out, "individual_predictions.rds"))
  csv(bind(lapply(evaluations, `[[`, "metrics")), file.path(out, "prediction_metrics.csv"))
  list(selected = selected, evaluations = evaluations, external = external, models = models, endpoint = ep,
       n_train = nrow(train), n_test = nrow(test), folds = fold, development_rows = train_ids)
}
