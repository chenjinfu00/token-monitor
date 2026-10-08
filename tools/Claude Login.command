#!/bin/zsh
set -e
for token_monitor_cli in /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.local/bin/claude"; do
    if [[ -x "$token_monitor_cli" ]]; then
        "$token_monitor_cli" auth login --claudeai
        print "登录完成。主动查询模式会自动同步额度；状态栏模式需等待下一次正常回复。"
        print "可以关闭这个登录窗口。"
        exit 0
    fi
done
print "未找到 Claude Code。请先安装 Claude Code 后重新登录。"
read "token_monitor_ack?按回车关闭。"
