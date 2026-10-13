#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ -x /opt/anaconda3/bin/python ]]; then
  token_monitor_python=/opt/anaconda3/bin/python
elif command -v python3 >/dev/null 2>&1; then
  token_monitor_python="$(command -v python3)"
else
  print -u2 "Python 3 is required for bridge tests. Install Python or add python3 to PATH."
  exit 1
fi
mkdir -p .build/checks-cache
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/checks-cache \
  Sources/TokenMonitor/Models.swift Sources/TokenMonitor/ResetNewsService.swift \
  Sources/TokenMonitor/ClaudeAuthProbe.swift Sources/TokenMonitor/ClaudeUsageProbe.swift \
  Tests/QuotaChecks.swift Tests/ClaudeUsageChecks.swift -o .build/QuotaChecks
.build/QuotaChecks
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/checks-cache \
  Sources/TokenMonitor/Models.swift Sources/TokenMonitor/EdgeCountdownRefresh.swift \
  Tests/EdgeCountdownRefreshChecks.swift -o .build/EdgeCountdownRefreshChecks
.build/EdgeCountdownRefreshChecks
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/checks-cache \
  Sources/TokenMonitor/SingleInstanceLock.swift Tests/SingleInstanceChecks.swift -o .build/SingleInstanceChecks
.build/SingleInstanceChecks
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/checks-cache \
  Sources/TokenMonitor/HistoryModels.swift Sources/TokenMonitor/ResetHistoryArchive.swift Sources/TokenMonitor/UsageHistoryRecorder.swift \
  Tests/HistoryChecks.swift -o .build/HistoryChecks
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/checks-cache \
  Sources/TokenMonitor/Models.swift Sources/TokenMonitor/ResetNewsService.swift \
  Sources/TokenMonitor/HistoryModels.swift Sources/TokenMonitor/QuotaPacingGuide.swift \
  Tests/PacingGuideChecks.swift -o .build/PacingGuideChecks
.build/PacingGuideChecks
.build/HistoryChecks
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/checks-cache \
  Sources/TokenMonitor/HistoryModels.swift Sources/TokenMonitor/HistoryAnnualUsage.swift \
  Tests/AnnualUsageChecks.swift -o .build/AnnualUsageChecks
.build/AnnualUsageChecks
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/checks-cache \
  Sources/TokenMonitor/WindowClickSequence.swift Tests/WindowClickChecks.swift -o .build/WindowClickChecks
.build/WindowClickChecks
"$token_monitor_python" -m unittest discover -s tools -p 'test_*.py'
