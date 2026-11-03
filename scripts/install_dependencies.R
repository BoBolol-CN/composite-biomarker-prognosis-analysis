# Explicit opt-in installation; analysis never installs packages automatically.
args <- commandArgs(trailingOnly = TRUE)
packages <- c("survival", "ggplot2", "patchwork")
if ("--tests" %in% args) packages <- unique(c(packages, "mice", "glmnet", "ranger", "e1071", "pROC", "nnet", "rpart", "class", "cmprsk", "openxlsx"))
if ("--io" %in% args) packages <- c(packages, "readxl", "openxlsx", "officer")
missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) utils::install.packages(missing, repos = "https://cloud.r-project.org")
message("Requested dependencies available. XGBoost/LightGBM are separate optional integrations.")
