# Copy into your study directory. Paths are relative to the command's working
# directory; use project-root paths or normalizePath() when portability matters.
config <- list(
  input = "private-data/cohort.csv", output_dir = "outputs/study-run", overwrite = FALSE,
  seed = 2026, synthetic = FALSE, export_xlsx = FALSE, population_label = "Defined study cohort",
  id_column = "patient_id", center_column = "center",
  column_map = list(), numeric_columns = c("age", "marker_a", "marker_b"),
  factors = list(sex = c("female", "male"), center = c("A", "B", "C", "D")),
  biomarker = list(label = "Composite index (a.u.)", components = c("marker_a", "marker_b"),
    compute = function(d) ifelse(d$marker_b > 0, d$marker_a / d$marker_b, NA_real_),
    scale = 1, grouping = list(probs = c(1 / 3, 2 / 3), labels = c("Low", "Middle", "High"))),
  endpoints = list(list(id = "mortality", label = "All-cause mortality", type = "survival",
                        time = "followup", status = "event", unit = "months", horizon = 24)),
  baseline_variables = c("age", "sex", "center"), report_times = c(0, 12, 24, 36),
  modules = c("baseline", "cox", "km", "spline"),
  association = list(models = list(Unadjusted = character(), Adjusted = c("age", "sex")),
    exposures = c("continuous", "grouped"), missing = "complete_case",
    spline_df = 3, spline_range = c(.02, .98), landmarks = c(1, 3),
    subgroups = "sex", center_methods = c("strata", "fixed")),
  prediction = list(endpoint = "mortality", split = list(train_fraction = .75), folds = 5,
    bootstrap = 200, save_individual_predictions = FALSE,
    decision_thresholds = seq(.05, .5, .01),
    candidates = list(
      Baseline_Cox = list(algorithm = "cox", variables = c("age", "sex")),
      Augmented_Cox = list(algorithm = "cox", variables = c("age", "sex", ".bp_index")))),
  plots = list(enabled = TRUE, diagnostics = TRUE))
# For a complete, observed fixed-horizon binary endpoint, set type="binary",
# complete_horizon=TRUE and choose logistic/ridge/decision_tree/random_forest/
# svm/knn/neural_net/xgboost/lightgbm candidates. Censoring cannot be ignored.
# For external validation add prediction$external_input; do not change the
# frozen encoding/scaling/imputation using external outcomes or performance.
