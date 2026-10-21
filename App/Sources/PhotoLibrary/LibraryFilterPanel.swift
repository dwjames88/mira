import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

/// The mono FILTER button at the trailing side of the grid header, with a lichen count badge.
struct FilterButton: View {
    let store: LibraryStore
    @State private var open = false

    var body: some View {
        let count = store.filter.activeCount
        Button { open.toggle() } label: {
            HStack(spacing: T.cells(1)) {
                Text("Filter")
                if count > 0 {
                    Text("\(count)")
                        .font(T.mono(9, weight: .semibold))
                        .foregroundStyle(T.ink)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(T.lichen))
                }
            }
        }
        .buttonStyle(.ff)
        .accessibilityLabel(count > 0 ? "Filter, \(count) active" : "Filter")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FilterPanel(store: store)
                .presentationBackground(T.inkSoft)
        }
        .onChange(of: open) { _, isOpen in store.setFilterPanelOpen(isOpen) }
    }
}

/// The filter popover: ink panel, mono labels, hairlines, no materials.
private struct FilterPanel: View {
    let store: LibraryStore
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: T.rows(0.5)) {
            FFSectionLabel("Scope")
            FFTabBar([(value: LibraryFilter.Scope.myLibrary, title: "MY LIBRARY"), (value: LibraryFilter.Scope.all, title: "ALL")],
                     selection: binding(\.scope))
            if store.filter.scope == .myLibrary {
                Text("Without iCloud Shared Library and shared albums").ffLabel(size: 9)
            }

            FFSectionLabel("Show only")
            FFToggle("RAW only", isOn: binding(\.rawOnly))
            FFToggle("Edited only", isOn: binding(\.editedOnly))
            FFToggle("Favorites only", isOn: binding(\.favoritesOnly))

            FFSectionLabel("Camera", trailing: store.filter.cameras.isEmpty ? nil : "\(store.filter.cameras.count)")
            FacetList(items: items(store.facets.cameras, selected: store.filter.cameras),
                      selected: store.filter.cameras, empty: emptyText) { name in
                store.updateFilter { toggle(name, in: &$0.cameras) }
            }

            FFSectionLabel("Lens", trailing: store.filter.lenses.isEmpty ? nil : "\(store.filter.lenses.count)")
            FacetList(items: items(store.facets.lenses, selected: store.filter.lenses),
                      selected: store.filter.lenses, empty: emptyText) { name in
                store.updateFilter { toggle(name, in: &$0.lenses) }
            }

            FFSectionLabel("Search")
            TextField("", text: $text, prompt: Text("FILENAME, CAMERA, LENS, DATE").font(T.mono(10)).foregroundColor(T.paperDim))
                .textFieldStyle(.plain)
                .font(T.mono(11))
                .foregroundStyle(T.paper)
                .padding(.horizontal, T.cells(1))
                .frame(height: T.rows(2))
                .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
                .onChange(of: text) { _, new in store.updateFilter { $0.search = new } }
                .accessibilityLabel("Search filter")
            Text("e.g. 2025, July 2025, 2025-07").ffLabel(size: 9)

            FFHairline().padding(.top, T.rows(0.5))
            HStack {
                if let line = store.indexProgress.line {
                    Text(line).ffLabel(size: 10, color: T.lichen)
                } else {
                    Text("INDEX \(store.metadataStore.count) PHOTOS").ffLabel(size: 10)
                }
                Spacer()
                Button("Reset") { store.resetFilter(); text = "" }
                    .buttonStyle(.ff)
                    .disabled(!store.filter.isActive)
            }
        }
        .padding(T.cells(2))
        .frame(width: T.cells(40))
        .ffPanel()
        .onAppear { text = store.filter.search }
        .onChange(of: store.filter.search) { _, new in if new != text { text = new } }
    }

    private var emptyText: String {
        store.indexProgress.finished || store.indexCoversCollection ? "NONE FOUND" : "WAITING FOR THE INDEX"
    }

    private func binding<V>(_ keyPath: WritableKeyPath<LibraryFilter, V>) -> Binding<V> {
        Binding(get: { store.filter[keyPath: keyPath] }, set: { new in store.updateFilter { $0[keyPath: keyPath] = new } })
    }

    private func toggle(_ name: String, in set: inout Set<String>) {
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
    }

    /// Facets plus any selected name the current collection does not have (shown with a zero count).
    private func items(_ facets: [FacetCount], selected: Set<String>) -> [FacetCount] {
        let known = Set(facets.map(\.name))
        return facets + selected.subtracting(known).sorted().map { FacetCount(name: $0, count: 0) }
    }
}

private struct FacetList: View {
    let items: [FacetCount]
    let selected: Set<String>
    let empty: String
    let toggle: (String) -> Void

    var body: some View {
        if items.isEmpty {
            Text(empty).ffLabel(size: 10).frame(height: T.rows(1), alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items, id: \.name) { item in
                        let on = selected.contains(item.name)
                        Button { toggle(item.name) } label: {
                            HStack(spacing: T.cells(1)) {
                                ZStack {
                                    Rectangle().strokeBorder(on ? T.lichen : T.paperDim, lineWidth: 1)
                                    if on { Rectangle().fill(T.lichen).padding(3) }
                                }
                                .frame(width: 10, height: 10)
                                Text(item.name).ffLabel(color: on ? T.paper : T.paperDim).lineLimit(1)
                                Spacer(minLength: T.cells(1))
                                Text("\(item.count)").ffLabel(size: 10)
                            }
                            .frame(height: T.rows(1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(on ? "On" : "Off")
                        .accessibilityAddTraits(.isToggle)
                    }
                }
            }
            .frame(height: min(CGFloat(items.count), 6) * T.rows(1))
        }
    }
}
