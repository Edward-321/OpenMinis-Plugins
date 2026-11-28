//
// AutoCompactTurnPolicy.swift
// Foundation-only policy; deliberately independent of chat bubbles and providers.
//

import Foundation

enum AutoCompactTurnPolicy {
    // Keep the existing capacity opt-in key: this is not a migration or opt-out.
    static let capacityEnabledKey = "autoCompactOnThreshold"
    static let enabledKey = "autoCompactByTurnsEnabled"
    static let thresholdKey = "autoCompactAssistantTurnThreshold"
    static let defaultThreshold = 80
    static let thresholdRange = 20...90

    static func normalizedThreshold(_ value: Int) -> Int {
        min(thresholdRange.upperBound, max(thresholdRange.lowerBound, value))
    }

    struct Settings: Equatable {
        let enabled: Bool
        let threshold: Int

        init(enabled: Bool, threshold: Int = AutoCompactTurnPolicy.defaultThreshold) {
            self.enabled = enabled
            self.threshold = AutoCompactTurnPolicy.normalizedThreshold(threshold)
        }
    }

    static func settings(defaults: UserDefaults = .standard) -> Settings {
        Settings(enabled: defaults.bool(forKey: enabledKey),
                 threshold: (defaults.object(forKey: thresholdKey) as? Int) ?? defaultThreshold)
    }

    /// One outbound assistant history entry is one turn, including a tool-use
    /// continuation. Multiple tools in that entry still count once. Call with
    /// effectiveAgentHistory(), AFTER summary injection, warm-up and trimming:
    /// retained warm-up assistants count; the user-role summary does not.
    /// This local count is not a claim about any upstream provider's turn limit.
    static func assistantTurnCount<History: Sequence>(
        in history: History, isAssistant: (History.Element) -> Bool
    ) -> Int {
        history.reduce(0) { count, entry in count + (isAssistant(entry) ? 1 : 0) }
    }

    struct Scope: Equatable {
        let sessionID: String
        let markerID: String?
    }

    struct Snapshot: Equatable {
        let scope: Scope
        let assistantTurns: Int

        init(sessionID: String, markerID: String?, assistantTurns: Int) {
            self.scope = Scope(sessionID: sessionID, markerID: markerID)
            self.assistantTurns = max(0, assistantTurns)
        }
    }

    /// Memory-only retry hysteresis, shared by pre-send and the agent loop.
    /// A failed/no-op attempt at N is not retried on every request: it needs a
    /// further threshold worth of effective assistant entries, or a new scope.
    /// A successful compaction rebases against its ACTUAL retained history. If
    /// warm-up alone is still at/above the threshold, it also requires another
    /// threshold worth of entries instead of summarizing the same tail again.
    struct Gate {
        private var scope: Scope?
        private var threshold: Int?
        private var nextAttemptAt = AutoCompactTurnPolicy.defaultThreshold

        mutating func shouldAttempt(settings: Settings, snapshot: Snapshot) -> Bool {
            guard settings.enabled else { return false }
            align(settings: settings, snapshot: snapshot)
            if snapshot.assistantTurns < settings.threshold {
                // Truncation/trim below the line re-arms the ordinary crossing.
                nextAttemptAt = settings.threshold
                return false
            }
            return snapshot.assistantTurns >= nextAttemptAt
        }

        mutating func recordAttempt(settings: Settings, snapshot: Snapshot) {
            guard settings.enabled else { return }
            align(settings: settings, snapshot: snapshot)
            guard snapshot.assistantTurns >= settings.threshold else { return }
            nextAttemptAt = addingWithoutOverflow(snapshot.assistantTurns, settings.threshold)
        }

        mutating func recordSuccess(settings: Settings, snapshot: Snapshot) {
            guard settings.enabled else { return }
            align(settings: settings, snapshot: snapshot)
            nextAttemptAt = snapshot.assistantTurns < settings.threshold
                ? settings.threshold
                : addingWithoutOverflow(snapshot.assistantTurns, settings.threshold)
        }

        private mutating func align(settings: Settings, snapshot: Snapshot) {
            guard scope != snapshot.scope || threshold != settings.threshold else { return }
            scope = snapshot.scope
            threshold = settings.threshold
            nextAttemptAt = settings.threshold
        }

        private func addingWithoutOverflow(_ count: Int, _ increment: Int) -> Int {
            let (sum, overflow) = count.addingReportingOverflow(increment)
            return overflow ? Int.max : sum
        }
    }
}
