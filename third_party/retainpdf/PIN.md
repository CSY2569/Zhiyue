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

## 约定

- 本目录是上游代码的**只读副本**：升级 = 换提交、整体替换、更新本文件；不在此目录内做局部修改。
- 引擎构建（`scripts/build_retain_engine.sh`）从这里构建 wheel 并组装运行目录。
- 引擎另需的外部资产（Typst 二进制、Typst `@preview` 包）由构建脚本按其 CI 钉死的版本下载：
  Typst 0.15.1（`ops/deployment/docker/backend/Dockerfile.app`）、cmarker 0.1.10、mitex 0.2.7。