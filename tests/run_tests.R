if (.Platform$OS.type == "windows") invisible(Sys.setlocale("LC_CTYPE", ".UTF-8"))
self <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())][1])
root <- dirname(dirname(normalizePath(self, winslash = "/")))
source(file.path(root, "scripts", "load.R")); bp_load(root)
test_count <- 0L
test <- function(name, expression) {
  force(expression); test_count <<- test_count + 1L; cat("PASS ", name, "\n", sep = "")
}
throws <- function(expression, pattern = ".") {
  x <- tryCatch({ force(expression); NULL }, error = identity)
  stopifnot(inherits(x, "error"), grepl(pattern, conditionMessage(x)))
}
env <- new.env(); sys.source(file.path(root, "assets", "config.example.R"), env); cfg <- env$config
set.seed(191)
n <- 500
raw <- data.frame(patient_id = seq_len(n), age = stats::rnorm(n, 60, 10),
                   sex = sample(c("female", "male"), n, TRUE), center = sample(LETTERS[1:4], n, TRUE),
                   marker_a = stats::rlnorm(n, .5, .5), marker_b = stats::rlnorm(n, 0, .2))
death <- stats::rexp(n, .01 * exp(.03 * (raw$age - 60) + .3 * raw$marker_a / raw$marker_b))
censor <- stats::runif(n, 28, 55)
raw$followup <- pmin(death, censor); raw$event <- as.integer(death <= censor)
raw$age[1:15] <- NA_real_
d <- prepare_data(raw, cfg); ep <- cfg$endpoints[[1]]
test("duplicate patient IDs are rejected", {
  z <- raw; z$patient_id[2] <- z$patient_id[1]; throws(prepare_data(z, cfg), "one row")
})
test("invalid event and time values are rejected", {
  z <- raw; z$event[1] <- 4; throws(prepare_data(z, cfg), "coding")
  z <- raw; z$followup[1] <- -1; throws(prepare_data(z, cfg), "positive")
})
test("ratio denominator zero does not produce infinity", {
  z <- raw; z$marker_b[1] <- 0; stopifnot(is.na(prepare_data(z, cfg)$.bp_index[1]))
})
test("first-event chronology and simultaneous-event rule", {
  z <- first_event(c(10, 4, NA), c(3, 8, 15), c(20, 20, 12))
  stopifnot(identical(z$status, c(2L, 1L, 0L)), identical(z$time, c(3, 4, 12)))
  throws(first_event(3, 3, 5), "simultaneous")
})
test("tied quantile cuts cannot silently create wrong groups", {
  z <- raw; z$marker_a <- z$marker_b; throws(prepare_data(z, cfg), "grouping cuts")
})
test("training preprocessing is frozen and handles test-only missing values", {
  train <- d[20:300, ]; pp <- fit_preprocessor(train, c("age", "sex", ".bp_index"))
  testdata <- d[301:320, ]; testdata$age[1] <- NA_real_
  before <- serialize(pp, NULL); x <- apply_preprocessor(testdata, pp)
  stopifnot(!anyNA(x), identical(before, serialize(pp, NULL)))
  testdata$sex <- as.character(testdata$sex); testdata$sex[1] <- "new"
  throws(apply_preprocessor(testdata, pp), "Unseen")
})
test("one-hot coding has no redundant all-category columns", {
  pp <- fit_preprocessor(d, c("age", "sex")); x <- apply_preprocessor(d, pp)
  stopifnot(qr(cbind(1, x))$rank == ncol(x) + 1)
})
test("weighted AUC agrees with ordinary AUC when weights are one", {
  need("pROC"); set.seed(12); p <- stats::runif(n)
  expected <- as.numeric(pROC::roc(raw$event, p, levels = 0:1, direction = "<", quiet = TRUE)$auc)
  stopifnot(abs(weighted_auc(raw$event, p, rep(1, n)) - expected) < 1e-10)
  stopifnot(abs(weighted_auc(c(0, 1), c(.5, .5), c(1, 1)) - .5) < 1e-10)
})
test("no-censoring fixed-horizon weights reproduce binary labels", {
  z <- data.frame(time = c(3, 4, 8, 10), status = c(1, 1, 1, 1))
  o <- horizon_observations(z, list(type = "survival", time = "time", status = "status", horizon = 5))
  stopifnot(identical(o$y, c(1L, 1L, 0L, 0L)), all(o$w == 1))
})
test("unsupported prediction horizons fail explicitly", {
  bad <- ep; bad$horizon <- max(d$followup) + 1; throws(horizon_observations(d, bad), "support")
})
test("group split and folds do not share centers", {
  scfg <- cfg; scfg$prediction$split$group_column <- "center"; scfg$prediction$folds <- 2
  ids <- prediction_split(d, ep, scfg$prediction$split, cfg$seed)
  stopifnot(!length(intersect(d$center[ids], d$center[-ids])))
  fold <- development_folds(d[ids, ], ep, scfg)
  stopifnot(all(vapply(split(fold, d$center[ids], drop = TRUE), function(x) length(unique(x)) == 1, logical(1))))
})
temp <- tempfile("bp-tests-"); dir.create(temp)
test("Cox, diagnostics and spline run with renamed generic columns", {
  cc <- run_cox(d, cfg, ep, temp)
  sp <- run_spline(d, cfg, ep, temp)
  stopifnot(nrow(cc$table) > 0, all(sp$lower <= sp$HR & sp$HR <= sp$upper),
            all(is.finite(sp$p_nonlinear)), file.exists(file.path(temp, "mortality_ph.csv")))
})
test("MICE Cox pooling uses all imputations", {
  mc <- cfg; mc$modules <- "cox"; mc$association$exposures <- "continuous"
  mc$association$imputation <- list(variables = c("age", "sex"), m = 3, maxit = 3)
  ans <- run_mi_cox(d, mc, ep, temp)
  stopifnot(ans$imputation$m == 3, all(is.finite(ans$table$lower)), all(ans$table$lower <= ans$table$HR))
})
test("available binary adapters return valid frozen probabilities", {
  b <- d; b$binary <- as.integer(death <= 24)
  be <- list(id = "binary", type = "binary", status = "binary", horizon = 24, complete_horizon = TRUE, unit = "months")
  algorithms <- c("logistic", "ridge", "decision_tree", "random_forest", "svm", "knn", "neural_net")
  for (a in algorithms) {
    s <- list(algorithm = a, variables = c("age", "sex", ".bp_index"), lambda = .03, k = 15, num_trees = 50)
    fit <- fit_candidate(b[1:350, ], be, s, cfg)
    p <- predict_candidate(fit, b[351:500, ])
    stopifnot(length(p) == 150, all(is.finite(p) & p >= 0 & p <= 1))
  }
})
test("censored outcomes reject ordinary classification adapters", {
  throws(fit_candidate(d, ep, list(algorithm = "logistic", variables = "age"), cfg), "Censored")
})
test("Cox horizon predictions match survival::survfit", {
  fit <- fit_candidate(d[1:350, ], ep, list(algorithm = "cox", variables = c("age", "sex", ".bp_index")), cfg)
  z <- as.data.frame(apply_preprocessor(d[351:355, ], fit$recipe)); names(z) <- fit$model$columns
  sf <- survival::survfit(fit$model$fit, newdata = z)
  expected <- 1 - as.numeric(summary(sf, times = ep$horizon)$surv)
  stopifnot(max(abs(predict_candidate(fit, d[351:355, ]) - expected)) < 1e-8)
})
test("final model selection uses development loss and produces traceable output", {
  pc <- cfg; pc$prediction$bootstrap <- 20; pc$prediction$folds <- 3
  pr <- run_prediction(d, pc, temp)
  cv <- utils::read.csv(file.path(temp, "prediction_development_cv.csv"))
  stopifnot(pr$selected == cv$candidate[which.min(cv$loss)], pr$n_train + pr$n_test == n,
            all(pr$evaluations[[pr$selected]]$metrics$bootstrap_valid >= 16))
  frozen <- readRDS(file.path(temp, "frozen_prediction_models.rds"))
  unlabeled <- raw[1:5, setdiff(names(raw), c("event", "followup"))]
  unlabeled$center <- "Unseen external center"
  prepared <- prepare_data(unlabeled, frozen$data_config)
  stopifnot(length(predict_candidate(frozen$models[[frozen$selected]], prepared)) == 5)
})
test("leaking outcome features are rejected", {
  pc <- cfg; pc$prediction$candidates[[1]]$variables <- c("age", "event")
  throws(run_prediction(d, pc, temp), "cannot be prediction features")
})
cat(sprintf("\n%d meaningful checks passed. XGBoost/LightGBM require optional packages and are not exercised here.\n", test_count))
