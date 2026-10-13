import Foundation

@main
struct ActivityModelChecks {
    static func main() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var estimator = ProviderActivityEstimator(windowSeconds: 30)
        let idle = estimator.update(ProviderActivityReading(), at: start)
        precondition(idle.rotationDuration == nil && idle.tokensPerSecond == nil)
        var reading = ProviderActivityReading(runningSessionIDs: ["a"])
        let running = estimator.update(reading, at: start)
        precondition(running.runningTaskCount == 1 && running.tokensPerSecond == nil)
        precondition(running.rotationDuration == 12)
        reading.tokenDeltas = [ActivityTokenDelta(sessionID: "a", at: start, tokens: 300)]
        let measured = estimator.update(reading, at: start)
        precondition(measured.tokensPerSecond == 10)
        precondition(measured.rotationDuration! < running.rotationDuration!)
        precondition(estimator.update(reading, at: start).tokensPerSecond == 10, "Repeated delivery must not double count")
        reading.runningSessionIDs.insert("b")
        reading.tokenDeltas = [ActivityTokenDelta(sessionID: "b", at: start, tokens: 600)]
        let parallel = estimator.update(reading, at: start)
        precondition(parallel.runningTaskCount == 2 && parallel.tokensPerSecond == 30)
        precondition(parallel.rotationDuration! < measured.rotationDuration!)
        reading.tokenDeltas = [ActivityTokenDelta(sessionID: "b", at: start.addingTimeInterval(100), tokens: 900)]
        precondition(estimator.update(reading, at: start).tokensPerSecond == 30, "Future counters must be ignored")
        reading.tokenDeltas = []
        let stale = estimator.update(reading, at: start.addingTimeInterval(31))
        precondition(stale.tokensPerSecond == nil && stale.rotationDuration == 12, "Tool waits must not keep an old high speed")
        precondition(estimator.update(ProviderActivityReading(), at: start.addingTimeInterval(32)).rotationDuration == nil)
        precondition(estimator.update(reading, at: start.addingTimeInterval(33)).tokensPerSecond == nil)
        let maximum = ProviderActivityState(runningTaskCount: 1, tokensPerSecond: 1_000_000)
        precondition(maximum.rotationDuration == 2)
        precondition(ProviderActivityState(runningTaskCount: 0, tokensPerSecond: 50).rotationDuration == nil)
        let waiting = estimator.update(ProviderActivityReading(statusNote: "任务状态待更新"), at: start.addingTimeInterval(34))
        precondition(waiting.rotationDuration == nil && waiting.helpText == "任务状态待更新")
        estimator.reset()
        print("Activity model checks passed")
    }
}
