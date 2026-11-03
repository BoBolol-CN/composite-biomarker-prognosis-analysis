plot_theme <- function() {
  need("ggplot2")
  ggplot2::theme_minimal(base_size = 11, base_family = "sans") +
    ggplot2::theme(panel.grid.minor = ggplot2::element_blank(),
                   panel.grid.major.x = ggplot2::element_blank(),
                   plot.title = ggplot2::element_text(face = "bold", size = 14, colour = "#17324D"),
                   plot.subtitle = ggplot2::element_text(colour = "#526678", size = 10),
                   plot.caption = ggplot2::element_text(colour = "#526678", hjust = 0, size = 9),
                   legend.position = "top", legend.title = ggplot2::element_blank(),
                   plot.margin = ggplot2::margin(12, 16, 10, 12))
}
plot_palette <- function(n) rep(c("#0072B2", "#E69F00", "#CC79A7", "#009E73", "#56B4E9", "#D55E00", "#000000"), length.out = n)
plot_caption <- function(cfg) if (isTRUE(cfg$synthetic)) "SYNTHETIC DATA | Reproducible demonstration; no patient observations." else "See analysis tables for sample, model, diagnostic and missing-data details."
save_figure <- function(p, name, cfg, out, width = 12, height = 6) {
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  ggplot2::ggsave(file.path(out, paste0(name, ".png")), p, width = width, height = height, dpi = 300, bg = "white")
  ggplot2::ggsave(file.path(out, paste0(name, ".pdf")), p, width = width, height = height, device = grDevices::pdf, bg = "white")
}
make_gallery <- function(results, cfg, out) {
  need("ggplot2"); need("patchwork")
  g <- asNamespace("ggplot2")
  for (ep in cfg$endpoints) {
    obj <- results$endpoints[[ep$id]]
    if (!is.null(obj$km) && !is.null(obj$spline)) {
      km <- obj$km; z <- obj$spline; groups <- unique(km$curve$group)
      # Explicit origin for the survival step curves.
      group_order <- cfg$biomarker$grouping$labels %||% groups
      colours <- stats::setNames(rep(c("#0072B2", "#E69F00", "#CC79A7", "#009E73", "#56B4E9"), length.out = length(group_order)), group_order)
      curve <- rbind(data.frame(time = 0, survival = 1, lower = 1, upper = 1, group = groups), km$curve)
      curve$group <- factor(curve$group, levels = group_order)
      km$risk$group <- factor(km$risk$group, levels = rev(group_order))
      xmax <- max(curve$time)
      p1 <- ggplot2::ggplot(curve, ggplot2::aes(time, survival, colour = group, linetype = group)) +
        ggplot2::geom_ribbon(ggplot2::aes(ymin = lower, ymax = upper, fill = group), alpha = .08, colour = NA, show.legend = FALSE) +
        ggplot2::geom_step(linewidth = .9) + ggplot2::scale_colour_manual(values = colours) +
        ggplot2::scale_fill_manual(values = colours) +
        ggplot2::scale_x_continuous(limits = c(0, xmax), breaks = cfg$report_times) +
        ggplot2::scale_y_continuous(limits = c(0, 1), labels = function(x) paste0(100 * x, "%")) +
        ggplot2::labs(title = "A  Survival by biomarker group", subtitle = sprintf("%s | n = %d | Log-rank P = %.3g", ep$label, km$n, km$p),
                      x = paste0("Follow-up (", ep$unit, ")"), y = "Survival probability") + plot_theme()
      rt <- ggplot2::ggplot(km$risk, ggplot2::aes(time, group, label = n_risk, colour = group)) +
        ggplot2::geom_text(size = 3.3, show.legend = FALSE) +
        ggplot2::scale_colour_manual(values = colours) +
        ggplot2::scale_x_continuous(limits = c(0, xmax), breaks = cfg$report_times) +
        ggplot2::labs(title = "Number at risk", x = NULL, y = NULL) + plot_theme() +
        ggplot2::theme(panel.grid = ggplot2::element_blank(), axis.text.x = ggplot2::element_blank(), plot.title = ggplot2::element_text(size = 10))
      p2 <- ggplot2::ggplot(z, ggplot2::aes(index, HR)) +
        ggplot2::geom_hline(yintercept = 1, linetype = 2, colour = "#8D99A6") +
        ggplot2::geom_ribbon(ggplot2::aes(ymin = lower, ymax = upper), fill = "#0072B2", alpha = .13) +
        ggplot2::geom_line(linewidth = 1, colour = "#0072B2") +
        ggplot2::labs(title = "B  Adjusted exposure-response", subtitle = sprintf("Natural cubic spline | Nonlinear P = %.3g", z$p_nonlinear[1]),
                      x = cfg$biomarker$label, y = "Hazard ratio (pointwise 95% CI)") + plot_theme()
      left <- patchwork::wrap_plots(p1, rt, ncol = 1, heights = c(4, 1.15))
      p <- patchwork::wrap_plots(left, p2, ncol = 2) + patchwork::plot_annotation(caption = plot_caption(cfg))
      save_figure(p, paste0(slug(ep$id), "_survival_profile"), cfg, out, height = 6.5)
    }
    if (!is.null(obj$cox)) {
      tab <- obj$cox$table; tab <- tab[tab$term == ".bp_scaled" & is.finite(tab$lower) & tab$lower > 0, , drop = FALSE]
      if (nrow(tab)) {
        tab$model <- factor(tab$model, levels = rev(names(cfg$association$models)))
        p <- ggplot2::ggplot(tab, ggplot2::aes(HR, model)) +
          ggplot2::geom_vline(xintercept = 1, linetype = 2, colour = "#8D99A6") +
          ggplot2::geom_errorbar(ggplot2::aes(xmin = lower, xmax = upper), orientation = "y", width = .12, colour = "#0072B2", linewidth = .7) +
          ggplot2::geom_point(size = 3.2, colour = "#0072B2") + ggplot2::scale_x_log10() +
          ggplot2::labs(title = "Adjusted association estimates", subtitle = paste(ep$label, "| Prespecified adjustment sets"),
                        x = paste0("Hazard ratio per ", cfg$biomarker$scale %||% 1, " index unit(s), 95% CI"), y = NULL, caption = plot_caption(cfg)) + plot_theme()
        save_figure(p, paste0(slug(ep$id), "_effect_estimates"), cfg, out, width = 9, height = 4.5)
      }
    }
    if (!is.null(obj$competing)) {
      cr <- obj$competing$curve; ng <- length(unique(cr$group))
      if (!is.null(cfg$biomarker$grouping$labels)) cr$group <- factor(cr$group, levels = cfg$biomarker$grouping$labels)
      p <- ggplot2::ggplot(cr, ggplot2::aes(time, risk, colour = group, linetype = group)) +
        ggplot2::geom_step(linewidth = 1) + ggplot2::scale_colour_manual(values = plot_palette(ng)) +
        ggplot2::scale_y_continuous(labels = function(x) paste0(100 * x, "%"), limits = c(0, min(1, max(cr$upper) * 1.08))) +
        ggplot2::labs(title = "Cumulative incidence with competing events", subtitle = paste0(ep$label, " | n = ", obj$competing$n),
                      x = paste0("Follow-up (", ep$unit, ")"), y = "Target-event cumulative incidence", caption = paste(plot_caption(cfg), "CIF, not 1-KM.")) + plot_theme()
      save_figure(p, paste0(slug(ep$id), "_competing_risk"), cfg, out, width = 9, height = 5)
    }
  }
  pr <- results$prediction
  if (!is.null(pr)) {
    ev <- pr$evaluations[[pr$selected]]; frames <- list(Test = ev)
    if (!is.null(pr$external)) frames$External <- pr$external
    collect <- function(key) bind(lapply(names(frames), function(label) { z <- frames[[label]][[key]]; z$dataset <- label; z }))
    roc <- collect("roc"); bins <- collect("bins"); dca <- collect("dca"); metric <- collect("metrics")
    palette <- c(Test = "#0072B2", External = "#D55E00")
    rocplot <- ggplot2::ggplot(roc, ggplot2::aes(fpr, tpr, colour = dataset, linetype = dataset)) +
      ggplot2::geom_abline(slope = 1, intercept = 0, linetype = 3, colour = "#8D99A6") + ggplot2::geom_path(linewidth = .9) +
      ggplot2::labs(title = "A  Discrimination", x = "False-positive rate", y = "True-positive rate") + ggplot2::coord_equal() + plot_theme()
    calplot <- ggplot2::ggplot(bins, ggplot2::aes(predicted, observed, colour = dataset, shape = dataset)) +
      ggplot2::geom_abline(slope = 1, intercept = 0, linetype = 3, colour = "#8D99A6") +
      ggplot2::geom_line(linewidth = .7) + ggplot2::geom_point(size = 2.5) + ggplot2::coord_equal(xlim = c(0, 1), ylim = c(0, 1)) +
      ggplot2::labs(title = "B  Calibration", subtitle = "Quantile bins; descriptive diagnostic", x = "Predicted risk", y = "Observed risk (IPCW if censored)") + plot_theme()
    auc <- metric[metric$metric %in% c("AUC", "Brier"), ]
    aucplot <- ggplot2::ggplot(auc, ggplot2::aes(estimate, dataset, colour = dataset)) +
      ggplot2::geom_errorbar(ggplot2::aes(xmin = lower, xmax = upper), orientation = "y", width = .12) +
      ggplot2::geom_point(size = 3) + ggplot2::facet_wrap(~ metric, ncol = 1, scales = "free_x") +
      ggplot2::labs(title = "C  Performance with uncertainty", subtitle = "95% frozen-prediction bootstrap intervals", x = "Metric estimate", y = NULL) + plot_theme() + ggplot2::theme(legend.position = "none")
    dcaplot <- ggplot2::ggplot(dca, ggplot2::aes(threshold, net_benefit, colour = dataset, linetype = dataset)) +
      ggplot2::geom_hline(yintercept = 0, colour = "#8D99A6") + ggplot2::geom_line(linewidth = .9) +
      ggplot2::geom_line(ggplot2::aes(y = treat_all, group = dataset), colour = "#8D99A6", linetype = 3, linewidth = .5) +
      ggplot2::labs(title = "D  Decision curves", subtitle = "Dotted: treat all; horizontal: treat none", x = "Decision threshold", y = "Net benefit") + plot_theme()
    plots <- lapply(list(rocplot, calplot, aucplot, dcaplot), function(p) p + ggplot2::scale_colour_manual(values = palette))
    p <- patchwork::wrap_plots(plots, ncol = 2) + patchwork::plot_annotation(
      title = paste0("Frozen-model validation | ", pr$selected),
      subtitle = paste0("Selected using development CV only | Horizon: ", pr$endpoint$horizon, " ", pr$endpoint$unit),
      caption = paste(plot_caption(cfg), "No clinical claims follow from this demo."))
    save_figure(p, "prediction_performance", cfg, out, width = 11, height = 9)
  }
}
