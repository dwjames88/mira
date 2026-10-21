import SwiftUI

private typealias T = FieldFramesTheme

/// Which collapsible inspector groups are closed, kept in `UserDefaults` under `mira.inspector.collapsed`
/// as a comma-separated list of group ids.
enum InspectorCollapse {
    static let key = "mira.inspector.collapsed"

    static func ids(_ raw: String) -> Set<String> { Set(raw.split(separator: ",").map(String.init)) }
    static func raw(_ ids: Set<String>) -> String { ids.sorted().joined(separator: ",") }
}

/// A mono section header with a chevron; a click folds the group. The state is stored per group id.
struct InspectorGroup<Content: View>: View {
    let id: String
    let title: String
    let trailing: String?
    @AppStorage(InspectorCollapse.key) private var collapsedRaw = ""
    @ViewBuilder let content: Content

    init(_ id: String, title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.id = id
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    private var collapsed: Bool { InspectorCollapse.ids(collapsedRaw).contains(id) }

    private func toggle() {
        var ids = InspectorCollapse.ids(collapsedRaw)
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        collapsedRaw = InspectorCollapse.raw(ids)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: T.cells(1)) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(T.paperDim)
                        .frame(width: 10)
                    Text(title).ffLabel(color: T.paperDim)
                    FFHairline()
                    if let trailing { Text(trailing).ffLabel(color: T.paperDim) }
                }
                .frame(height: T.rows(1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, T.rows(1))
            .padding(.bottom, 4)
            .accessibilityLabel(title)
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            .accessibilityHint("Shows or hides this group")
            .accessibilityAddTraits(.isHeader)
            if !collapsed { content }
        }
    }
}
