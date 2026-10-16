import Foundation

// Explicit, read-only request/reply. No periodic logging, disk writes or queries.
@MainActor
enum ActivityDiagnostics {
    private static let requestName = Notification.Name("local.tokenmonitor.activity-status.request")
    private static let responseName = Notification.Name("local.tokenmonitor.activity-status.response")

    static func readRunningApp(timeout: TimeInterval = 5) -> String? {
        let nonce = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        var received: String?
        let token = center.addObserver(forName: responseName, object: nonce, queue: .main) { note in
            guard note.object as? String == nonce,
                  let payload = note.userInfo?["payload"] as? String,
                  payload.utf8.count <= 32_768,
                  let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schemaVersion"] as? Int == 1 else { return }
            received = payload
        }
        defer { center.removeObserver(token) }
        center.postNotificationName(requestName, object: nonce, userInfo: nil, deliverImmediately: true)
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, min(10, timeout))
        while received == nil && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return received
    }

    static func installResponseHandler(_ snapshot: @escaping () -> [String: Any]) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: requestName, object: nil, queue: .main) { note in
            guard let nonce = note.object as? String, nonce.utf8.count == 36, UUID(uuidString: nonce) != nil else { return }
            Task { @MainActor in
                var object = snapshot()
                object["schemaVersion"] = 1
                object["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                object["observedAt"] = Date().timeIntervalSince1970
                guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                      data.count <= 32_768, let payload = String(data: data, encoding: .utf8) else { return }
                DistributedNotificationCenter.default().postNotificationName(responseName, object: nonce,
                    userInfo: ["payload": payload], deliverImmediately: true)
            }
        }
    }

    static func resetNewsSnapshot(_ state: ResetNewsState, at now: Date = Date()) -> [String: Any] {
        let reference: Any = state.reference.map {
            ["kind": $0.targetKind.rawValue, "confidence": $0.confidence.rawValue,
             "confidencePercent": $0.confidencePercent as Any? ?? NSNull(),
             "startAt": $0.startAt.timeIntervalSince1970,
             "targetAt": $0.referenceAt.timeIntervalSince1970,
             "remainingPercent": $0.remainingPercent(at: now)] as [String: Any]
        } ?? NSNull()
        return ["canShowReference": state.canShowReference(at: now), "reference": reference,
                "updatedAt": state.updatedAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull(),
                "isLoading": state.isLoading, "sourceIsStale": state.sourceIsStale,
                "hasError": !(state.message?.isEmpty ?? true)]
    }

    static func quotaSnapshot(_ state: ProviderState) -> [String: Any] {
        ["updatedAt": state.updatedAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull(),
         "isLoading": state.isLoading,
         "windows": state.windows.prefix(12).map { window -> [String: Any] in
             ["id": String(window.id.prefix(80)), "usedPercent": window.usedPercent as Any? ?? NSNull(),
              "remainingPercent": window.remainingPercent as Any? ?? NSNull(),
              "resetsAt": window.resetsAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull(),
              "durationSeconds": window.durationSeconds as Any? ?? NSNull()]
         }]
    }
}
