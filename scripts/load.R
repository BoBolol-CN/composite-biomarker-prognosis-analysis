# Source this file from an explicit root; never changes the working directory.
bp_load <- function(root) {
  for (file in c("core.R", "association.R", "prediction.R", "plots.R", "runner.R"))
    sys.source(file.path(root, "scripts", "R", file), envir = .GlobalEnv)
  invisible(TRUE)
}
