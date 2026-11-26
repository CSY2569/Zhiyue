# 归档文档

这个目录里的内容**不再维护，也不保证与当前代码一致**。保留它们只为一个理由：记录设计取舍与踩坑过程。

看当前状况请去 [`../PRODUCT.md`](../PRODUCT.md) 与 [`../ARCHITECTURE.md`](../ARCHITECTURE.md)。

| 文件 | 是什么 | 为什么归档 |
|---|---|---|
| `IMPLEMENTATION_STATUS.md` | 107KB 的开发日志（§3.1–§3.39 按日期追加） | 信息量大但组织方式是时间线，查模块要全文搜索。当前状态改由 `PRODUCT.md` 承载；本文档文首有「按子系统索引」表，仍可用于追溯某次改动的来龙去脉 |
| `TECH_ROADMAP.md` | 立项期的技术路线规划 | 选型多已变更（如 async-openai 已弃用），保留为决策史 |
| `DIAGRAMS.md` | Mermaid 架构图与时序图 | 图仍有参考价值，但部分细节已滞后；分层以 `ARCHITECTURE.md` 为准 |
| `BILINGUAL_READING_PLAN.md` | 对照阅读自研管线方案 v4.2 | **自研管线已于 2026-09-18 整体移除**，现由 RetainPDF 承担。文首已标「历史归档」 |
| `bilingual_workflow.html` | 上文的可视化伴读 | 同上 |
| `BRANCH_SPLIT_PLAN.md` | main/android 拆分的执行计划 | 拆分已完成，结果写在 `PLATFORMS.md` |
| `FLUTTER_UI_MIGRATION.md` | UI 迁移说明 | 迁移已完成 |
| `BRANCHING.md` | 分支策略 | 已并入 `PLATFORMS.md` |
| `PLATFORM_DIFFERENCES.md` | 两端差异对照 | 已并入 `PLATFORMS.md` |
| `DEPENDENCIES.md` | 工具链依赖说明 | 已并入 `DEVELOPMENT.md`；且原文列了已弃用的包 |
| `LINUX_PACKAGES.md` | Linux 分发包说明 | 打包命令已并入 `DEVELOPMENT.md` |
| `plans/2026-10-08-reading-themes.md` | 内置阅读主题的实施计划（1309 行） | 计划已落地，阅读主题现已实现；保留为任务拆分的样例 |

> 需要查历史变更时，`IMPLEMENTATION_STATUS.md` 的「按子系统索引」表（文首 §0）是唯一高效的入口。
