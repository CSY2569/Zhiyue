# 平台分支拆分计划

目标：让 `main` 只承载 Linux / Windows 桌面版，`android` 只承载 Android 版，
同时保持两条分支共享 `lib/` 与 `rust/` 的公共实现，避免长期分叉。

当前状态：两条分支都已建立并推送，但**内容相同**（`main` 上仍带着完整的
`android/` 工程与移动端 UI 分支）。本计划描述如何把差异真正落地。

---

## 一、现状盘点

| 项目 | 规模 | 归属 |
|---|---|---|
| `android/`（Gradle、Kotlin、资源） | 63 个文件 | 仅 Android |
| `scripts/build_android.sh`、`fetch_pdfium_android.sh`、`stage_android_models.sh` | 3 个脚本 | 仅 Android |
| 移动端专属 Dart | 9 个文件，约 1444 行 | 仅 Android |
| 桌面专属 Dart（RetainPDF 对照） | 12 个文件，约 2451 行 | 仅桌面 |
| 共享文件里的平台分支 | 15 个文件，30 处判断 | **冲突点** |
| Rust 移动端专属 | 2 个文件，约 1031 行 | 仅 Android |
| Rust 平台 `cfg` 分支 | 9 处（5 个文件） | **冲突点** |

关键结论：

- **桌面构建完全不依赖 `android/`**：`linux/CMakeLists.txt`、`scripts/build_packages.sh`、
  `pubspec.yaml` 均未引用 `android/`。移除它对桌面零影响。
- 项目目前**没有 `windows/` 目录**，Windows 支持要从零加。
- 冲突集中在 15 个共享文件（`reader_page.dart`、`library_page.dart`、`app.dart`、
  `main.dart`、`result_card.dart`、`floating_toolbar.dart`、`book_tile.dart` 等），
  其中 `reader_page.dart`（720 行、7 处判断）和 `main.dart`（5 处）最重。

---

## 二、必须解决的关键问题：删除会随 merge 传播

如果 `main` 直接删除 `android/`，则 `git merge main` 到 `android` 时，**这些文件
会在 `android` 上一起被删除**（`android` 未修改过它们时 git 静默删除，不报冲突）。
这是"main 干净化"方案最容易踩的坑，必须在计划里显式处理。

三种可行机制：

| 机制 | 做法 | 评价 |
|---|---|---|
| **A. manifest + 恢复脚本** | 维护 `.platform/android-owned.txt`；合并后把这些路径从合并前的 `android` 提交恢复 | **推荐**：语义清晰，冲突只出现在真正共同修改的文件 |
| B. 只 cherry-pick 共享提交 | 不做 merge，逐条 cherry-pick | 不推荐：跨平台提交会拆不开，历史难追溯 |
| C. main 保留占位 stub | Android 文件在 main 上留空实现 | 不推荐：stub 需要跟着接口演进，等于两边都改 |

采用 A。同步脚本（`scripts/sync-from-main.sh`）：

```bash
#!/usr/bin/env bash
# 把 main 的共享改动合入 android，保留 android 自己的平台文件。
set -euo pipefail
git switch android
ANDROID_TIP=$(git rev-parse HEAD)
git merge --no-commit --no-ff main || true
while IFS= read -r path; do
  git checkout "$ANDROID_TIP" -- "$path" 2>/dev/null || true
done < .platform/android-owned.txt
git add -A
git commit -m "merge: sync shared changes from main"
```

`git checkout <commit> -- <path>` 同时覆盖"恢复被删文件"和"保留 android 版本"
两种情况。manifest 由脚本生成并纳入版本控制：

```bash
# 列出 android 有、main 没有的路径（即 android 独占文件）
comm -23 <(git ls-tree -r --name-only android | sort) \
         <(git ls-tree -r --name-only main | sort)
```

manifest 只登记**整文件归属**。共享文件（如 `reader_page.dart`）不登记，
它们的分歧必须靠阶段 2 的适配层消除，而不是靠合并时选边。

---

## 三、目标结构

```
lib/
  core/                     # 共享：主题、度量、通用组件
  data/                     # 共享：repositories
  features/                 # 共享：library / reader / ai / annotation / search / settings
  platform/
    contract.dart           # 共享：平台能力接口（页面只依赖这里）
    desktop/                # 仅 main：桌面 chrome、RetainPDF 对照、窗口集成
    android/                # 仅 android：手机 chrome、文本级对照、系统栏/刷新率
  src/rust/                 # 共享：FRB 绑定（两端各自 regen）
rust/
  src/                      # 共享核心
  src/platform/android/     # 仅 android：文本级翻译管线（阶段 3）
android/                    # 仅 android
windows/  linux/            # 仅 main
```

`main` 上 `lib/platform/android/` 不存在；`android` 上 `lib/platform/desktop/`
可以保留（用于对照阅读的桌面引擎不可用时的降级）或删除，建议保留桌面实现
以便平板横屏复用，仅删除依赖 `window_manager` 的部分。

---

## 四、分阶段执行

### 阶段 0：分支与策略（已完成）

- `main` 快进到最新，`android` 从同一点建立并推送。
- `docs/BRANCHING.md` 写明职责、同步方向、版本与 tag 规则。

### 阶段 1：移除 Android 构建面（低风险，1–2 小时）

**做什么**

1. 在 `main` 删除：
   - `android/`（63 个文件）
   - `scripts/build_android.sh`、`scripts/fetch_pdfium_android.sh`、`scripts/stage_android_models.sh`
2. 新增 `.platform/android-owned.txt`（上述路径）与 `scripts/sync-from-main.sh`。
3. 新增 `.platform/README.md` 说明 manifest 的维护方式。
4. 更新 `README.md`：Android 构建说明标注"仅在 `android` 分支"。
5. `android` 分支执行一次反向同步，验证脚本可用。

**不做什么**：不动任何 Dart / Rust 代码。此时 `main` 仍保留移动端 UI 代码与
条件分支（过渡态），但**不能再构建 APK**。

**验证**

- `flutter analyze` 0、`flutter test` 全绿（当前 327 个）
- `cargo test` 通过（当前 144 个）
- `flutter build linux --release` 成功，AppImage 冒烟启动
- `android` 分支：`bash scripts/build_android.sh` 仍能产出 APK
- 在 `main` 上执行 `flutter build apk` 应明确失败（预期行为）

**回滚点**：`git revert` 单个提交即可。

### 阶段 2：引入平台适配层，移走移动端 UI（主要工作量，4–8 小时）

**为什么必须做**：只要共享页面里还有 `PlatformCapabilities.isMobile` 分支，
阶段 1 之后每次合并仍会在 `reader_page.dart` 等文件产生冲突，manifest 救不了。

**新增契约**（`lib/platform/contract.dart`，两端都存在的唯一平台入口）

```dart
/// 页面只通过这里拿平台差异，不直接判断 Platform。
abstract interface class PlatformUi {
  Widget readerChrome(ReaderChromeArgs args);
  Widget libraryScaffold(LibraryScaffoldArgs args);
  Widget bilingualPane(BilingualPaneArgs args);
  Widget resultCard(ResultCardArgs args, Widget content);
  Future<void> initPlatform(ProviderContainer container);
  void onReaderEnter();
  void onReaderExit();
}
```

参数对象（`ReaderChromeArgs` 等）也在契约文件里定义，保证两端签名一致。

**迁移清单**

| 从共享文件移除的分支 | 迁往 |
|---|---|
| `reader_page.dart` 的 `_isPhone` / `PhoneReaderChrome` / `MobilePanel` / 沉浸模式 / 音量键 | `lib/platform/android/reader.dart` |
| `library_page.dart` 的抽屉侧栏、多选栏、移动 FAB 逻辑 | `lib/platform/android/library.dart` |
| `app.dart` 的 `RefreshRateScope` | `lib/platform/android/refresh_rate.dart` |
| `main.dart` 的 `PlatformBridge` 初始化（数据目录、pdfium、模型安装、内存回调） | `lib/platform/android/bootstrap.dart`；桌面保留 `lib/platform/desktop/bootstrap.dart` |
| `result_card.dart` / `floating_toolbar.dart` / `mark_toolbar.dart` / `note_composer.dart` / `book_tile.dart` / `ai_conversations_page.dart` / `app_title_bar.dart` 的 `isMobile` / `isCompactWidth` 分支 | 各自的 `lib/platform/android/...` 实现，或保留 `isCompactWidth`（纯尺寸响应，与平台无关） |

**要点**

- `isCompactWidth`（宽度 < 700dp）是**响应式布局**，不是平台差异，可以保留在共享层；
  只把 `isMobile` / `isAndroid` 的判断移出去。
- `PlatformCapabilities` 与其 `BilingualMode` 保留在共享层，作为契约的一部分。
- 移动端文件移到 `lib/platform/android/` 后，`main` 删除整个目录；`android` 保留。
- 桌面专属的 RetainPDF 对照（`translated_pane.dart`、`book_translation_provider.dart` 等）
  移到 `lib/platform/desktop/`。

**验证**

- 两端 `flutter analyze` / `flutter test` 全绿
- `main`：搜索 `lib/` 不再命中 `phone_reader_chrome|mobile_panel|translated_text_column`
- `android`：真机/模拟器回归（选词、翻页、对照、AI 卡片拖动、OCR）
- `main`：桌面回归（阅读器返回、缩略图、对照、导出、AI 面板）

**回滚点**：阶段 2 建议拆成 5–6 个提交（契约 → 阅读器 → 书库 → AI/标注 → 启动 → 清理），
每个提交都可单独回滚。

### 阶段 3：Rust 侧隔离（可选，2–4 小时）

移动端专属：`translate/text_translate.rs`（772 行）、`db/repository/text_translation.rs`（259 行）、
`api.rs` 里 4 个导出（`translate_page_text` 等）。

两种做法：

| 做法 | 说明 | 代价 |
|---|---|---|
| **Cargo feature** `mobile-text` | 用 `#[cfg(feature = "mobile-text")]` 包住模块与导出；android 构建脚本加 `--features mobile-text` | 每次改 API 要重跑 FRB codegen，且两端 FRB 输出会不同 |
| **目录分层** | 移到 `rust/src/platform/android/`，`mod.rs` 用 `#[cfg(target_os = "android")]` | 不引入 feature 组合，codegen 稳定 |

**建议**：先保持现状（`cfg!(target_os)` 已在运行时隔离，桌面只是多编译 1031 行死代码），
等移动端逻辑再增长时再拆。阶段 3 列为可选项。

### 阶段 4：Windows 支持（独立工作，1–2 天）

`main` 要负责 Windows，但目前没有 `windows/` runner：

1. `flutter create --platforms=windows .` 生成 runner（注意：不要让 Flutter
   改写 `pubspec.yaml` / `linux/`）。
2. pdfium Windows 预编译二进制 + `fetch_pdfium_windows.sh`。
3. `window_manager` 在 Windows 的标题栏分支（现有 frameless 逻辑已平台无关）。
4. OCR 模型随包分发路径（Windows 用 exe 同级 `models/`）。
5. 打包脚本（zip 或 Inno Setup）。
6. CI 增加 windows-latest 构建。

---

## 五、验证门禁

每次合并 / 发版前：

| 分支 | 门禁 |
|---|---|
| `main` | `flutter analyze` 0、`flutter test` 全绿、`cargo test`、`clippy -D warnings`、`flutter build linux --release`、守卫测试（`lib/` 不含 android 专属 import） |
| `android` | 同上 + `bash scripts/build_android.sh` 产出 APK、`aapt2 dump badging` 校验包名/版本/图标 |
| 合并后 | `scripts/sync-from-main.sh` 执行后 manifest 路径完整；`git diff main android -- lib rust` 只剩预期差异 |

守卫测试（阶段 2 后加入 `test/platform_boundary_test.dart`）：

```dart
test('main tree has no android-only imports', () {
  final offenders = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => f.readAsStringSync().contains('platform/android/'))
      .toList();
  // 仅 lib/platform/android 自身除外（该目录在 main 上不存在）
  expect(offenders, isEmpty);
});
```

---

## 六、风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| 合并时 android 专属文件被删除 | 分支被打断、APK 构建失败 | manifest + 同步脚本；`build_android.sh` 在 CI 中跑 |
| 共享文件冲突频繁 | 每次合并都要手工解冲突 | 阶段 2 的适配层把分支点集中到 1 个契约文件 |
| FRB 两端不同步 | 生成的绑定与 Rust 不符，运行时崩溃 | 改 `api.rs` 后两端都执行 `flutter_rust_bridge_codegen generate` 并一起提交 |
| 版本/tag 冲突 | 发布混淆 | 两端独立 `version`，tag 加 `-linux` / `-android` 后缀 |
| 移动端回归缺失 | 阶段 2 改坏手机布局 | 阶段 2 完成后在真机跑一遍 P0 用例（选词、翻页、对照、OCR、AI） |

---

## 七、待确认

1. **拆分深度**：只做阶段 1（移除构建面），还是做到阶段 2（连移动端 UI 代码一起移走）？
2. **Windows**：现在就加 `windows/` runner，还是留到桌面功能稳定后？
3. **旧分支** `feat/android-v1-and-runtime-polish`：其内容已被两条新分支包含，是否删除？
4. **Android 文档与移动端测试**：是否也移到 `android` 分支（`main` 的 README 需相应调整）？
