# 贡献说明

欢迎报告问题、改进文档或提交 Pull Request。项目代码采用 [MIT License](LICENSE)。

## 报告问题

请说明 macOS 版本、Apple Silicon 或 Intel、Token Monitor 版本、对应官方 CLI 版本，以及可重复的步骤。界面截图和应用显示的简短错误即可；不要上传登录令牌、账户配置、对话、完整 CLI 调试日志或 `~/.claude` / `~/.codex` 文件。

## 本地开发

需要 macOS 13+、Swift 工具链和 Python 3，无第三方 Swift 或 Python 依赖。

```sh
zsh tools/test.sh
zsh build.sh
```

测试使用固定样例与临时目录，不登录真实账户、不查询服务、不修改真实 Claude 设置。手动使用 `--probe` 或 `--claude-probe` 会查询本机账户，只在需要实际同步验证时运行。

修改数据来源时，请保留未知值、到期值和失败状态，不把缺失额度解释为 0%。改变窗口交互时，请检查展开、缩略、拖动、屏幕边缘和单实例行为。提交前运行相关检查，并在 Pull Request 中说明行为变化与验证结果。

## 发布

在 `build.sh` 更新版本后运行 `zsh tools/package-release.sh`，生成通用 ZIP、DMG 和 `SHA256SUMS.txt`。应用包只收录构建脚本列出的项目文件，包含 MIT 许可证。下载包不附带官方 CLI、账号或个人配置。

将安装包放入 `downloads/v版本号/` 时，同步更新 README 的下载链接与发行说明；版本标签工作流也可生成 GitHub Releases。需要 Apple Developer ID 与公证的正式分发流程尚未配置。
