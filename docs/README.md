# 文档导航

智阅（ZhiYue / RBWA）的文档按用途分成三组。**先读 `PRODUCT.md` 搞清楚这东西能干什么**，再按角色往下走。

---

## 活文档（与代码同步维护）

| 文档 | 内容 | 适合谁 |
|---|---|---|
| [`OVERVIEW.md`](OVERVIEW.md) | **软件说明**：解决什么问题、给谁用、完整使用流程、明确做不到的事 | 所有人，尤其第一次接触的人 |
| [`PRODUCT.md`](PRODUCT.md) | **功能现状**：按用户可见功能组织，标注真实实现状态与明确未实现的项 | 所有人，尤其产品与测试 |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | 分层与职责边界、FRB 调用约定、数据流、错误处理 | 开发 |
| [`DATA_MODEL.md`](DATA_MODEL.md) | 13 张表 + FTS5、ER 关系、索引、迁移链、**`ai_config` 全字段说明** | 开发 |
| [`FFI_API.md`](FFI_API.md) | 81 个 FFI 命令的分组参考 + 「新增一个命令」五步 | 开发 |
| [`PLATFORMS.md`](PLATFORMS.md) | 三平台两条分支、`PlatformHost` 抽象、同步陷阱、Windows 待办 | 开发 / 发布 |
| [`DEVELOPMENT.md`](DEVELOPMENT.md) | 构建、测试、打包、扩展点速查、架构风险排序 | 开发 |
| [`ROADMAP.md`](ROADMAP.md) | **执行规划**：缺口清单、方案、验收标准与优先级（待审核） | 决策者 / 开发 |
| [`FEATURES.md`](FEATURES.md) | **需求规格**（130 条，P0/P1/P2）——是「应该有什么」，不是「现在有什么」 | 产品 |
| [`THIRD_PARTY.md`](THIRD_PARTY.md) | 第三方组件与许可证义务（GPL-3.0 / AGPL 隔离约定） | 法务 / 发布 |

---

## 推荐读法

**第一次接触这个项目**：
1. `PRODUCT.md` —— 明确边界：什么有、什么没有。
2. `ARCHITECTURE.md` —— 理解「重活在 Rust、界面在 Dart、只有 `api.rs` 跨边界」这一条铁律。
3. `DEVELOPMENT.md` §8 —— 把环境跑起来，注意「两套 cargo 目标目录」的坑。
4. `FFI_API.md` §5 —— 跟着五步加一个最小命令，把管道走通。

**要动数据库**：`DATA_MODEL.md`，特别是 §AI 设置——那份 JSON 是测试基准数据，不能丢。

**要动平台相关代码**：`PLATFORMS.md` §4 的硬规则（禁止写 `Platform.isAndroid`）。

**要改翻译**：先看 `PRODUCT.md` §3.8 的「不能做的」，再看 `DEVELOPMENT.md` §14 关于外部子进程契约的风险。
