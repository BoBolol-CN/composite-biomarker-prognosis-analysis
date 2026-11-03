# Composite Biomarker Prognosis Analysis

**复合指标预后分析 skill + 可运行的 R 工作流。** 用一份配置描述指标公式、数据列、终点、调整集和验证方案，生成可追溯的分析表、模型及图表。论文写作由独立的 writing skill 负责。

这套代码从具体项目工作流重构而来。研究数据、旧项目结果和私人路径均不在仓库内；下面所有展示图由固定种子的**模拟数据**实际运行生成，只展示分析能力和成品样式。

## 成品图预览

### 生存曲线、风险人数与调整后非线性关系

![Synthetic survival curves and adjusted spline](docs/gallery/survival_profile.png)

曲线含不确定性区间，风险表与生存图共用时间轴；样条报告相对参考值的 HR，不自动把弯折或 HR=1 称作临床阈值。

### 冻结模型的内部与外部评价

![Synthetic prediction validation dashboard](docs/gallery/prediction_performance.png)

模型按开发集交叉验证损失选择，再评价测试集和独立模拟队列。组合图包括 ROC、校准、AUC/Brier 的 bootstrap 区间及决策曲线；展示结果不构成临床效用证据。

### 竞争风险与效应估计

| 累积发生函数 | 预设调整模型的效应 |
| --- | --- |
| ![Synthetic competing-risk CIF](docs/gallery/competing_risk.png) | ![Synthetic adjusted effects](docs/gallery/effect_estimates.png) |

以上均为 **SYNTHETIC DATA**。模拟队列不来自真实患者；完整 PDF 可通过运行演示生成。

## 快速运行

需要 R 4.4 或更新版本。最小绘图依赖为 `survival`、`ggplot2`、`patchwork`；完整演示还使用 `cmprsk`。其他模型和插补按需加载，不会在分析过程中自动安装包。

```r
# 在仓库根目录执行；需要时显式安装测试及演示依赖。
Rscript scripts/install_dependencies.R --tests
Rscript scripts/make_demo.R
Rscript tests/run_tests.R
```

默认演示输出在 `outputs/synthetic-demo/`，包括模拟数据、CSV、Excel汇总工作簿、受控模型对象、PDF/PNG 和执行环境记录。研究配置用 `export_xlsx=TRUE` 开启Excel导出（需 `openxlsx`）。该目录被 Git 忽略。演示为加快运行使用150次 bootstrap，正式研究应根据精度要求增加次数，不能把演示配置当作研究方案。

## 换成自己的研究

1. 将 [配置示例](assets/config.example.R) 复制到研究目录，修改 `input` 和 `output_dir`。数据可用 CSV、RDS 或 XLSX（XLSX 需 `readxl`）。输入应留在输出目录之外。
2. 配置 `column_map`、数值类型、类别水平及指标公式，明确单位和采样窗口。对分母零值等异常显式处理，不猜测原始数据库编码。
3. 定义一个或多个终点及其时间单位：`survival` 为0/1右删失结局；`competing` 为已经按首次事件顺序构建的0/1/2状态；`binary` 仅用于完整可观测的固定时距结局。
4. 设置调整模型、暴露尺度、可选分组及所需模块。分组切点只用于关联/描述，不能进入预测特征；预测示例使用连续指标。
5. 运行并检查人数、事件数、模型诊断及结果清单，再决定研究结论。

```sh
Rscript scripts/run_analysis.R path/to/study-config.R
```

终点、指标和模型数量都由配置决定。路径相对于命令的工作目录；可使用绝对项目路径。代码不调用 `setwd()`，不依赖其他研究目录。

## 已实现的模块与边界

| 能力 | 配置/实现 | 边界 |
| --- | --- | --- |
| 缺失概况、描述表、指标与分组 | `baseline`、`biomarker` | 不默认删除高缺失变量或强制缩尾 |
| 连续/分组 Cox、PH、设计矩阵列VIF | `cox`、`association$models` | VIF不是多自由度GVIF；PH非显著不证明假设成立 |
| 多重插补后 Cox 合并 | `association$missing="mice"` | 当前只支持连续暴露 Cox；其他推断模块需单独方案，不拿单份完成数据冒充MI推断 |
| KM、固定时点风险表 | `km`、`report_times` | 普通生存终点；竞争事件不套用1−KM |
| 自然立方样条 | `spline` | 当前完整案例推断，不做自动“临床拐点”提取 |
| CIF、Gray检验、Fine–Gray | `competing` | 使用真实首次事件时间；CIF图的方差区间在输出表中提供 |
| 亚组交互、界标、中心敏感性 | `subgroup`、`landmark`、`center` | 分析选择需依据问题；不由P值决定是否做 |
| 生存预测 | `prediction` + `cox`候选 | 预设时距风险；评价使用边际IPCW，要求相应删失假设及随访支持 |
| 固定时距完整二分类预测 | logistic、ridge/elastic-net、树、RF、SVM、KNN、神经网络 | 同一开发折内拟合预处理；XGBoost/LightGBM另需安装，当前本地未测试这两个适配器 |
| 外部评价与独立预测 | `external_input`、`predict_external.R` | 冻结整个处理链；不能在外部调参后称原模型验证 |
| 结果交接 | `results_manifest.csv` | 与写作skill约定的语义字段兼容，不自动撰写论文 |

不直接迁移按结局做PSM、由SHAP排名确定中介、为画列线图重新拟合“同一”模型等旧规则。通用SHAP、列线图、复杂因果中介、重复事件和竞争风险预测尚未封装为自动模块；需要匹配研究设计的实现，不能用普通分类替代。[迁移说明](docs/migration.md) 逐项说明原流程的对应去向。

## 预测流程

```text
原始定义与确定性映射
        ↓
开发 / 最终测试划分（可按患者组或时间）
        ↓
开发折内部：插补 → 缩放/编码 → 候选模型拟合 → 折外预测
        ↓
按开发损失选择，重拟合开发数据，冻结模型与预处理
        ↓
最终测试 / 外部评价 → 区分度、校准、误差、决策曲线
```

交叉验证表用于选择，不作为无偏的最终性能宣称。bootstrap 默认按独立个体重采样冻结预测；有聚类时可设置 `bootstrap_group_column`。它估计评价不确定性，不纠正整个建模过程的乐观偏倚。边际IPCW假设不适合时，应另行实现条件删失模型。概率校准诊断不会因树模型而豁免。

```sh
# 单独对新数据生成冻结预测；不需要新队列结局。
Rscript scripts/predict_external.R outputs/study-run/frozen_prediction_models.rds private-data/new-cohort.csv outputs/new-predictions.csv
```

## 安装和使用 skill

本仓库根目录也是 skill 目录，入口是 [SKILL.md](SKILL.md)。将整个仓库目录放入所用工具支持的skills目录，保持 `scripts/`、`assets/` 与 `references/` 相对位置一致；也可以直接使用 R 脚本。

调用示例：

> 使用 `$composite-biomarker-prognosis-analysis`，先核对这份队列的数据字典和结局定义，再按配置分析该复合指标与预后的关联，并输出可交给写作流程的结果清单。

## 可复现与验证

本地在 R 4.4.3 上运行了完整模拟演示及18项行为检查，覆盖数据验证、事件先后、冻结预处理、分组隔离、AUC核对、插补合并、模型预测与选择边界；Cox时距预测还与 `survival::survfit` 核对。该验证不等于临床验证，也不证明所有可选软件版本均兼容。模型对象、原始数据和逐行预测均不随仓库分发。

方法依据与使用约束见 [R运行参考](references/r-execution.md) 和各领域参考文件。
