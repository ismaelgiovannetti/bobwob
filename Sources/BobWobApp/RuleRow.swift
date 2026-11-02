import AppKit
import BobWobCore
import SwiftUI

struct RuleRow: View {
    let rule: RuleReport
    let session: CleanupSession

    private var isScanning: Bool {
        session.scanningRuleIDs.contains(rule.metadata.id)
    }

    private var selectedCount: Int {
        rule.items.filter { session.selection.contains($0.id) }.count
    }

    var body: some View {
        if rule.items.isEmpty {
            label
        } else {
            DisclosureGroup {
                ForEach(rule.items) { item in
                    ItemRow(item: item, session: session)
                }
            } label: {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            selectionControl
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.metadata.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(rule.status == .completed ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var selectionControl: some View {
        if session.canSelectWholeRule(rule) {
            let bindings = session.cleanableItems(of: rule).map { item in
                Binding(
                    get: { session.selection.contains(item.id) },
                    set: { session.setSelected($0, item: item) }
                )
            }
            Toggle(sources: bindings, isOn: \.self) {
                Text(rule.metadata.name)
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
        } else {
            // Keeps names aligned when a rule has no global checkbox.
            Color.clear.frame(width: 14, height: 14).accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isScanning {
            ProgressView().controlSize(.small)
        } else if rule.status == .completed {
            let size = displayedSize
            Text(Format.size(size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(Format.sizeHelp(size))
        }
    }

    private var displayedSize: SizeEstimate {
        let information = rule.items.allSatisfy { !$0.isCleanable }
        guard information else { return rule.cleanableSize }
        return SizeEstimate.total(of: rule.items.map(\.size))
    }

    private var subtitle: String {
        switch rule.status {
        case .unavailable, .failed:
            return rule.statusMessage ?? "Indisponible"
        case .absent, .completed:
            if rule.metadata.risk == .dataLoss, selectedCount > 0 {
                return "\(selectedCount) élément(s) choisi(s). \(rule.metadata.recoveryNote)"
            }
            return rule.metadata.recoveryNote
        }
    }
}

private struct ItemRow: View {
    let item: ScanItem
    let session: CleanupSession

    private var isSelected: Binding<Bool> {
        Binding(
            get: { session.selection.contains(item.id) },
            set: { session.setSelected($0, item: item) }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            if item.isCleanable {
                Toggle(item.title, isOn: isSelected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Information, non nettoyable")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(item.path ?? item.title)
            Spacer(minLength: 8)
            Text(Format.size(item.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(Format.sizeHelp(item.size))
        }
        .contextMenu {
            if let path = item.path {
                Button("Afficher dans le Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button("Copier le chemin") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let date = item.lastActivity {
            let formatted = date.formatted(date: .abbreviated, time: .omitted)
            parts.append(item.lastActivityIsApproximate ? "Pas d'usage connu depuis \(formatted)" : "Utilisé le \(formatted)")
        }
        if let note = item.note, item.lastActivity == nil {
            parts.append(note)
        } else if item.lastActivity == nil, let path = item.path {
            parts.append((path as NSString).abbreviatingWithTildeInPath)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
