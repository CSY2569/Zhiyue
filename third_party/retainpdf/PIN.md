# RetainPDF pipeline — vendored 记录（勿改此目录内上游代码）

- 上游仓库：https://github.com/wxyhgk/retain-pdf
- 上游提交：d365ed866f3e9561003cdd8292b81ba097e6d389（2026-10-06）
- 管线版本：retainpdf-pipeline 4.2.6（pyproject.toml）
- 许可：MIT（见 ./LICENSE）

## 收录内容

| 路径 | 来源 |
|---|---|
| `pipeline/` | `backend/pipeline/{retainpdf_pipeline, pyproject.toml, README.md}` |
| `fonts/` | `resources/fonts/`（Source Han Serif SC，OFL-1.1） |

## 本地补丁（vendored ≠ 原样）

补丁文件在 `patches/`，升级（整体替换）后需重新应用并复核。

| 补丁 | 文件 | 原因 |
|---|---|---|
| `0001-truncation-item-scope.patch` | `translate/llm/validation/quality.py` | 评审的截断检查（源≥200 字符且译文<15%）拿**单元合并源文**（`unit_source_text`）比对**条目自身译文**：跨页续接单元的小成员（如 887 字符单元里的 86 字符片段，比值 0.097）被系统性误判 `truncated_translation`，而门禁 `enforce_no_blocking_review_errors` 全有或全无 —— 一个误判就让整本任务在全部批次完成后报错作废（用户实跑：10 页文档 6 处、88 页论文 4 处，均为 `continuation_group_members`；极端案例源文 28 字符/译文 56 字符也被判截断）。补丁改为用**条目级源文**（`protected_source_text`/`source_text`）做截断参照，缺省回退调用方口径；其余检查（占位符/公式/上下文泄漏）保持不变。 |

## 约定

- 本目录是上游代码的副本：升级 = 换提交、整体替换、重新应用 `patches/`、更新本文件。
- 引擎构建（`scripts/build_retain_engine.sh`）从这里构建 wheel 并组装运行目录。
- 引擎另需的外部资产（Typst 二进制、Typst `@preview` 包）由构建脚本按其 CI 钉死的版本下载：
  Typst 0.15.1（`ops/deployment/docker/backend/Dockerfile.app`）、cmarker 0.1.10、mitex 0.2.7。