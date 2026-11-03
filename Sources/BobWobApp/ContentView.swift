import BobWobCore
import SwiftUI

struct ContentView: View {
    @Bindable var session: CleanupSession
    @State private var preview: CleanupPreview?
    @State private var isPreparing = false
    @State private var errorMessage: String?

    private var visibleRules: [RuleReport] {
        session.rules.filter { rule in
            switch rule.status {
            case .absent: false
            case .completed: !rule.items.isEmpty || session.scanningRuleIDs.contains(rule.metadata.id)
            case .unavailable, .failed: true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VolumeHeader(volume: session.volume, phase: session.phase, session: session)
            Divider()
            content
            Divider()
            footer
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if session.phase == .scanning || session.phase == .cleaning {
                    Button("Arrêter", systemImage: "stop.fill") { session.stop() }
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Scanner", systemImage: "magnifyingglass") { session.startScan() }
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .sheet(item: $preview) { current in
            CleanupConfirmationView(preview: current) { confirmedDataLoss in
                preview = nil
                session.startCleanup(current, confirmedDataLoss: confirmedDataLoss)
            } onCancel: {
                preview = nil
            }
        }
        .sheet(item: reportBinding) { report in
            CleanupResultView(report: report) { session.dismissReport() }
        }
        .alert("Préparation impossible", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.phase == .idle {
            ContentUnavailableView {
                Label("Rien d'analysé pour l'instant", systemImage: "internaldrive")
            } description: {
                Text("Le scan ne modifie rien. Tu choisis ensuite ce que tu veux nettoyer.")
            } actions: {
                Button("Lancer le scan") { session.startScan() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleRules.isEmpty, session.phase == .ready {
            ContentUnavailableView("Rien à nettoyer", systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(RiskLevel.allCases, id: \.self) { risk in
                    let rules = visibleRules.filter { $0.metadata.risk == risk }
                    if !rules.isEmpty {
                        Section {
                            ForEach(rules, id: \.metadata.id) { rule in
                                RuleRow(rule: rule, session: session)
                            }
                        } header: {
                            RiskHeader(risk: risk, rules: rules, session: session)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.selection.isEmpty ? "Aucune sélection" : "Sélection : \(Format.size(session.selectedSize))")
                    .font(.headline)
                    .monospacedDigit()
                Text("\(session.selectedItems.count) élément(s). Un aperçu s'affiche avant toute action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isPreparing {
                ProgressView().controlSize(.small)
            }
            Button("Nettoyer…") { prepare() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(session.phase != .ready || session.selection.isEmpty || isPreparing)
        }
        .padding(12)
        .background(.bar)
    }

    private func prepare() {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                preview = try await session.makePreview()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var reportBinding: Binding<CleanupReport?> {
        Binding(
            get: { session.phase == .cleaning ? nil : session.lastReport },
            set: { if $0 == nil { session.dismissReport() } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

extension CleanupPreview: Identifiable {
    public var id: String {
        report.outcomes.map(\.summary).joined(separator: "|")
    }
}

extension CleanupReport: Identifiable {
    public var id: String {
        "\(availableBytesBefore ?? 0)-\(outcomes.count)-\(outcomes.first?.summary ?? "")"
    }
}

private struct VolumeHeader: View {
    let volume: VolumeUsage?
    let phase: CleanupSession.Phase
    let session: CleanupSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium)).monospacedDigit()
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            progress
            if let unanalyzed = session.unanalyzedBytes {
                Text("Non analysé : \(Format.bytes(unanalyzed)) (macOS, apps, documents et données que BobWob ne couvre pas)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("Espace utilisé moins ce que les règles de BobWob ont mesuré. Une grande partie de cet espace est normale et ne doit pas être supprimée.")
            }
            if phase == .scanning {
                Text("Si le scan semble bloqué, macOS attend peut-être ta réponse pour accéder à un dossier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var title: String {
        guard let available = volume?.availableBytes, let total = volume?.totalBytes else {
            return "Disque"
        }
        return "\(Format.bytes(available)) libres sur \(Format.bytes(total))"
    }

    private var status: String {
        switch phase {
        case .idle: "En attente"
        case .scanning: scanningStatus
        case .ready: "Analyse terminée"
        case .cleaning: "Nettoyage \(session.completedSteps) sur \(session.totalSteps)…"
        }
    }

    private var scanningStatus: String {
        let names = session.rules
            .filter { session.scanningRuleIDs.contains($0.metadata.id) }
            .map(\.metadata.name)
        return names.isEmpty ? "Analyse en cours…" : "Analyse : " + names.joined(separator: ", ")
    }

    @ViewBuilder
    private var progress: some View {
        switch phase {
        case .scanning:
            ProgressView().progressViewStyle(.linear)
        case .cleaning:
            ProgressView(value: Double(session.completedSteps), total: Double(max(session.totalSteps, 1)))
                .progressViewStyle(.linear)
        case .idle, .ready:
            if let available = volume?.availableBytes, let total = volume?.totalBytes, total > 0 {
                ProgressView(value: Double(total - available), total: Double(total))
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Espace occupé")
            }
        }
    }
}

private struct RiskHeader: View {
    let risk: RiskLevel
    let rules: [RuleReport]
    let session: CleanupSession

    private var total: SizeEstimate {
        SizeEstimate.total(of: rules.map(\.cleanableSize))
    }

    var body: some View {
        HStack(spacing: 6) {
            selectAll
            Image(systemName: risk.symbol)
                .foregroundStyle(risk.tint)
                .accessibilityHidden(true)
            Text(risk.title).font(.headline)
            Text(risk.explanation).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(Format.size(total))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .help(Format.sizeHelp(total))
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var selectAll: some View {
        let bindings = session.cleanableItems(with: risk).map { item in
            Binding(
                get: { session.selection.contains(item.id) },
                set: { session.setSelected($0, item: item) }
            )
        }
        if !bindings.isEmpty {
            Toggle(sources: bindings, isOn: \.self) {
                Text("Tout cocher : \(risk.title)")
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help("Tout cocher ou décocher dans cette section")
        }
    }
}
