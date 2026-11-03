# R工作流执行

在已有研究定义和可辩护分析计划下使用。先检查 [配置示例](../assets/config.example.R)，从实际数据字典填写字段，不能套用模拟研究的数值或结论。仓库 [README](../README.md) 给出运行方式和能力边界。

## 可用入口

- [run_analysis.R](../scripts/run_analysis.R)：读取研究配置后执行指定模块。
- [make_demo.R](../scripts/make_demo.R)：只生成模拟队列及演示结果；不会读取真实患者数据。
- [predict_external.R](../scripts/predict_external.R)：加载冻结模型及输入定义，对无需结局的新队列预测。
- [run_tests.R](../tests/run_tests.R)：验证主要数据、建模及交接约束，不代表临床可用性已验证。

## 配置与检查

`column_map` 使用“规范名=源列名”；调整集用规范列名，不接受需要求值的任意表达式。重编码、采样窗口、单位换算须先按数据定义完成。`biomarker$compute` 是研究者提供的可信R函数，不从数据文件执行代码。

指标字段 `.bp_index` 是原始派生指标，`.bp_scaled` 按预先声明的单位缩放；`.bp_group` 是关联/描述分组，不能放进预测特征。以 `.bp_` 开头的输入列被保留为内部名称，发现冲突时停止。预测样本要求一名患者一行；重复事件、多状态或时间依赖数据需专用实现。

分组可设 `probs` 或预设 `breaks`，标签与实际组数对应。并列值产生重复分位切点时停止，不偷偷丢掉组。关联子分析复用全队列的同一切点。预测预处理只在开发折学习，外部类别或列缺失时明确报错，不能通过悄悄删列来预测。

竞争终点状态为0删失、1目标事件、2竞争事件。源数据若是各自发生时间，可使用 `first_event(target_time, competing_time, censor_time)` 构造；同时发生需明确规则，不能用最终标志覆盖事件时序。`cause` 指定1或2中的目标事件。

## MICE Cox

设置 `association$missing="mice"`、`association$exposures="continuous"`，并提供 `association$imputation`，其中包含 `variables`、`m`、`maxit`，可选 `method` 与 `predictor_matrix`。参数按缺失信息、诊断和实体模型相容性决定，示例参数不构成推荐的固定方案。

该帮助函数对已知结局的基线变量插补，使用各份完成数据重算指标、逐份拟合并按Rubin规则合并。它保留原始插补对象以便检查收敛、分布与日志。未自动完成与非线性、交互、聚类或MNAR相容的所有插补设计；不能因运行成功而省去这些判断。当前不能同时运行需要MI合并的样条、亚组、界标、中心或Fine–Gray推断。描述表/KM若单独运行，来自观察到的数据，不是合并后MI推断。

依据：[mice的合并估计说明](https://amices.org/mice/reference/pool.html)。

## 预测与输出

生存预测目前使用Cox候选和明确时距，普通分类适配器只接收完整固定时距结局。配置多个候选相当于开发网格；`ridge`可设置 `alpha=1` 实现LASSO，或0到1之间的弹性网。lambda等值是待比较候选的设置，不复用旧项目最优值。

可选适配器为 `logistic`、`ridge`、`decision_tree`、`random_forest`、`svm`、`knn`、`neural_net`、`xgboost`、`lightgbm`。缺少包或拟合失败会写入开发CV表，不用常数预测冒充该模型完成。至少一个有效候选才继续。神经网络及其他优化器的警告保留在结果中；应检查收敛和敏感性，不能仅因代码返回就认为可靠。

最终模型按开发折外损失选择：完整二分类用log loss，生存风险用指定时距IPCW Brier。最终测试不参与调参。`split$group_column`隔离组；`split$time_column`按时间保留后段测试；开发CV目前为分组或分层折，真正需要滚动时间验证时需另行实现。外部数据只使用冻结处理与模型，不重新学习分箱或缩放。

边际IPCW适用于相应删失独立性假设，且需要时距仍有随访支持及权重稳定。校准分箱是描述性诊断，图上未提供其置信区间；效应样条为逐点区间。bootstrap可以按 `bootstrap_group_column`聚类重采样，结果报告有效/尝试次数；冻结预测重采样不包含开发不确定性。非零预测风险阈值仅作配置范围内净获益展示，不能凭模拟图设定临床决策值。

`results_manifest.csv`记录已实现的Cox与选定预测模型核心估计；CIF、Fine–Gray、亚组等详细表另有明确文件，交给写作时应把相关源表一起提供，不把缺少清单行理解为“未做”。

输出还包括队列和缺失概况、诊断、实际模型、配置及 `sessionInfo.txt`。这些内容可能包含研究数据和私人路径，应留在受控目录。脚本不删除旧输出；`overwrite=TRUE`只允许覆盖同名文件，换方案时应换新的空目录，避免混入旧结果。

## 结果解释

不要把样条参考值HR=1解释为临床阈值；不以PH非显著证明比例风险；设计矩阵逐列VIF不能代替多自由度GVIF；去中心后P值改变也不能单独证明偏倚。实际研究需根据事件数、参数自由度、临床定义与诊断调整方案。

参考：[survival::coxph](https://stat.ethz.ch/R-manual/R-devel/library/survival/html/coxph.html)、[竞争事件的风险解释](https://www.bmj.com/content/349/bmj.g5060.long)、[数据泄漏与预处理](https://scikit-learn.org/stable/common_pitfalls.html)。
