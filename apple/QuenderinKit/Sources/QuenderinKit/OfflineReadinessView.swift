#if canImport(SwiftUI)
import SwiftUI

/// "Are you ready to go offline?" — the one-glance reassurance screen for the
/// off-grid user, rendered from a `PreflightChecklist`.
public struct OfflineReadinessView: View {
    private let checklist: PreflightChecklist

    public init(checklist: PreflightChecklist) {
        self.checklist = checklist
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: checklist.isReadyForOffline ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(checklist.isReadyForOffline ? .green : .orange)
                    .accessibilityHidden(true)
                Text(checklist.isReadyForOffline ? "Ready to go offline" : "Not ready yet")
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Text(checklist.readiness.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !checklist.blockers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checklist.blockers, id: \.self) { blocker in
                        Label(blocker, systemImage: "arrow.right.circle")
                            .font(.caption)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("To get ready, resolve: " + checklist.blockers.joined(separator: ", "))
            }

            Divider()

            row("Storage", ok: checklist.storage.hasRoom, detail: checklist.storage.message)
            row("Model downloaded", ok: checklist.isReadyForOffline, detail: checklist.readiness.message)
        }
        .padding()
    }

    @ViewBuilder
    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(ok ? "Ready" : "Not ready")
        .accessibilityHint(detail)
    }
}
#endif
