#!/bin/zsh
# Double-click in Finder (or run with zsh): runs the offline checks, builds and
# installs Token Monitor, then the read-only Claude diagnostics. All output is
# also saved to dist/last-run.log so it can be reviewed afterwards.
cd "${0:A:h:h}" || exit 1
mkdir -p dist
log="dist/last-run.log"
{
  print "=== $(date '+%Y-%m-%d %H:%M:%S') Token Monitor tests, build, install and diagnostics"
  print "=== tests"
  zsh tools/test.sh || { print "TESTS FAILED"; exit 1; }
  print "=== build"
  zsh build.sh || { print "BUILD FAILED"; exit 1; }
  print "=== install"
  osascript -e 'if application "Token Monitor" is running then tell application "Token Monitor" to quit' || true
  sleep 2
  pkill -x TokenMonitor 2>/dev/null || true
  for i in {1..10}; do pgrep -x TokenMonitor >/dev/null || break; sleep 0.5; done
  pkill -9 -x TokenMonitor 2>/dev/null || true
  rm -rf "/Applications/Token Monitor.app" && cp -R "dist/Token Monitor.app" /Applications/ || { print "INSTALL FAILED"; exit 1; }
  open "/Applications/Token Monitor.app"
  print "installed version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '/Applications/Token Monitor.app/Contents/Info.plist')"
  T="/Applications/Token Monitor.app/Contents/MacOS/TokenMonitor"
  print "=== claude probe (twice)"
  "$T" --claude-probe; "$T" --claude-probe
  print "=== claude diagnostics"
  python3 tools/diagnose_claude_usage.py
  print "=== running app status"
  sleep 3
  "$T" --activity-status || print "running app did not answer"
  print "=== exit log"
  "$T" --exit-log
  print "=== done"
} 2>&1 | tee "$log"
print "\n结果已保存到 $log，可以关闭这个窗口。"
