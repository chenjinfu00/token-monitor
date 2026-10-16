import Foundation
import Darwin

// Process-wide guards for a long-running monitor that keeps spawning CLI children.
enum ProcessSafety {
    static func configure() {
        // Writing a request to a CLI that already exited must fail with EPIPE
        // and be retried, never terminate the app. Unlike SIG_IGN, a no-op
        // handler is reset to the default action in exec'd children.
        signal(SIGPIPE) { _ in }
        // File watches, query pipes and network sockets share one descriptor
        // table, and GUI processes start with a soft limit of only 256.
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let target = min(limit.rlim_max, rlim_t(4096))
        if limit.rlim_cur < target {
            limit.rlim_cur = target
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
    }
}
