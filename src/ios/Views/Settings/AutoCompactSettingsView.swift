//
// AutoCompactSettingsView.swift
// Normal settings entry; the parent settings navigation registers this view.
//

import SwiftUI

struct AutoCompactSettingsView: View {
    @AppStorage(AutoCompactTurnPolicy.capacityEnabledKey) private var capacityEnabled = false
    @AppStorage(AutoCompactTurnPolicy.enabledKey) private var turnsEnabled = false
    @AppStorage(AutoCompactTurnPolicy.thresholdKey) private var storedThreshold = AutoCompactTurnPolicy.defaultThreshold

    private var threshold: Binding<Int> {
        Binding(
            get: { AutoCompactTurnPolicy.normalizedThreshold(storedThreshold) },
            set: { storedThreshold = AutoCompactTurnPolicy.normalizedThreshold($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle(AppLocalized("Compact near context capacity"), isOn: $capacityEnabled)
            } header: {
                Text(AppLocalized("Context capacity"))
            } footer: {
                Text(AppLocalized("Uses the existing context-capacity policy. When off, its current confirmation and exhausted-context behavior are unchanged."))
            }

            Section {
                Toggle(AppLocalized("Compact by assistant turns"), isOn: $turnsEnabled)
                Stepper(value: threshold, in: AutoCompactTurnPolicy.thresholdRange) {
                    HStack {
                        Text(AppLocalized("Assistant turn threshold"))
                        Spacer()
                        Text("\(threshold.wrappedValue)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!turnsEnabled)
            } header: {
                Text(AppLocalized("Assistant turns"))
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalized("Independent of context-capacity auto-compaction. Default: 80; range: 20–90. Checked before sending and between completed tool iterations; never interrupts an in-flight tool."))
                    Text(AppLocalized("Each assistant entry in the effective request history counts once, including tool-use continuations. Chat bubbles and individual tools are not the counter. Retained warm-up assistants count; the user-role summary does not."))
                    Text(AppLocalized("After a failed attempt, or when retained warm-up still reaches the threshold, another threshold worth of effective assistant entries is required before retrying. A history reduced below the threshold re-arms the normal crossing. This local count may differ from a provider's turn limit."))
                }
            }
        }
        .navigationTitle(AppLocalized("Auto Compact"))
        .onAppear {
            let normalized = AutoCompactTurnPolicy.normalizedThreshold(storedThreshold)
            if storedThreshold != normalized { storedThreshold = normalized }
        }
    }
}
