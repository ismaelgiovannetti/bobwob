import AppKit
import BobWobCore
import SwiftUI

struct CleanupConfirmationView: View {
    let preview: CleanupPreview
    let onConfirm: (Bool) -> Void
    let onCancel: () -> Void

    @State private var acceptsDataLoss = false

    private var canConfirm: Bool {
        !preview.runnable.isEmpty && (!preview.includesDataLoss || acceptsDataLoss)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vérifie avant de nettoyer").font(.title2.weight(.semibold))
            Text("Gain estimé : \(Format.size(preview.expectedGain))")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            List {
                if !preview.runnable.isEmpty {
                    Section("Sera exécuté (\(preview.runnable.count))") {
                        ForEach(Array(preview.runnable.enumerated()), id: \.offset) { _, outcome in
                            OutcomeRow(outcome: outcome)
                        }
                    }
                }
                if !preview.blocked.isEmpty {
                    Section("Sera ignoré (\(preview.blocked.count))") {
                        ForEach(Array(preview.blocked.enumerated()), id: \.offset) { _, outcome in
                            OutcomeRow(outcome: outcome)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 240)

            if preview.includesTrash {
                Label("Les fichiers personnels vont à la corbeille : l'espace n'est libéré qu'une fois celle-ci vidée.", systemImage: "trash")
                    .font(.callout)
            }
            if preview.includesDataLoss {
                Toggle("Je comprends que certains de ces éléments peuvent contenir des données que je perdrai.", isOn: $acceptsDataLoss)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Annuler", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Nettoyer", role: .destructive) { onConfirm(acceptsDataLoss) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}

struct CleanupResultView: View {
    let report: CleanupReport
    let onDismiss: () -> Void

    private var problems: [StepOutcome] {
        report.outcomes.filter { $0.status == .failed || $0.status == .skipped }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nettoyage terminé").font(.title2.weight(.semibold))
            Text(summary).foregroundStyle(.secondary).monospacedDigit()
            if let gain = report.measuredGain {
                Text("Espace libre mesuré : +\(Format.bytes(gain))").font(.headline).monospacedDigit()
            }
            if !problems.isEmpty {
                List(Array(problems.enumerated()), id: \.offset) { _, outcome in
                    OutcomeRow(outcome: outcome)
                }
                .listStyle(.inset)
                .frame(minHeight: 180)
            }
            HStack {
                Button("Ouvrir le journal") {
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    NSWorkspace.shared.activateFileViewerSelecting([CleanupJournal(home: home).url])
                }
                Spacer()
                Button("Fermer", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var summary: String {
        "\(report.count(.succeeded)) réussi(s), \(report.count(.skipped)) ignoré(s), \(report.count(.failed)) échec(s)"
    }
}

private struct OutcomeRow: View {
    let outcome: StepOutcome

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayedSummary)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(outcome.summary)
                if let message = outcome.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(outcome.status == .failed ? Color.red : Color.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(Format.size(outcome.expectedGain))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var displayedSummary: String {
        outcome.summary.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
