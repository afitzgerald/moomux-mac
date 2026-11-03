import SwiftUI

/// The batch delete confirmation, both apps. A sheet, not an alert: it lists
/// every session with what is at stake beside it, and an alert's message is
/// neither scrollable nor known to re-render when a check lands.
///
/// One click, like the single delete — the information is the safeguard, so
/// Delete stays disabled until every session's check has answered.
public struct BatchDeleteSheet: View {
    let app: AppState
    let ids: [Session.ID]

    public init(app: AppState, ids: [Session.ID]) {
        self.app = app
        self.ids = ids
    }

    public var body: some View {
        let sessions = ids.compactMap { app.session(id: $0) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(sessions.count) sessions?").font(.headline)
            List(sessions) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.name).lineLimit(1)
                        Text(session.project).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let risk = app.batchRisk(for: session.id) {
                        Text(risk.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(risk.hasPrefix("⚠︎") ? SessionTheme.gitWarn(app.palette)
                                                                    : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            #if os(macOS)
            .listStyle(.bordered)
            #endif
            Text(app.batchWarning(ids)).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { app.dismissBatchDelete() }
                    .keyboardShortcut(.cancelAction)
                // No default action: Return must not delete.
                Button("Delete \(sessions.count) Sessions", role: .destructive) { app.deleteBatch(ids) }
                    .disabled(app.batchChecking(ids))
                    #if os(iOS)
                    .buttonStyle(.borderedProminent)
                    #endif
            }
        }
        .padding()
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 360, idealHeight: 420)
        #endif
    }
}
