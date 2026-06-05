import SwiftUI
import AppKit

struct PeopleView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var faces: [PublicFace] = []
    @State private var people: [Person] = []
    @State private var searchText: String = ""
    @State private var selectedPerson: Person? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchField

                if filteredPeople.isEmpty {
                    ContentUnavailableView(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No People Found" : "No Matching People",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Rescan faces to build the people list." : "Try a different name.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                            ForEach(filteredPeople) { person in
                                personButton(for: person)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        rescanFaces()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(FaceScanProgress.shared.isActive)
                    .help("Re-group all detected faces into people")
                }
            }
        }
        // Ensure the people window has a reasonable minimum size so the
        // NavigationView / split behavior doesn't produce unsatisfiable
        // layout constraints when the window is created small.
        .frame(minWidth: 420, minHeight: 360)
        .background(WindowAccessor { window in
            window?.title = "People"
        })
        .onAppear {
            Task.detached {
                let list = await FaceProcessor.shared.personsList()
                await MainActor.run { people = list }
            }
        }
        .overlay(alignment: .top) {
            FaceScanProgressOverlay()
        }
        .sheet(item: $selectedPerson) { person in
            PersonDetailView(person: person) {
                Task.detached {
                    // Refresh people list after possible mutations.
                    let list = await FaceProcessor.shared.personsList()
                    await MainActor.run { people = list }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search people", text: $searchText)
                .textFieldStyle(.roundedBorder)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var filteredPeople: [Person] {
        let sorted = people.sorted { lhs, rhs in
            let lhsName = displayName(for: lhs)
            let rhsName = displayName(for: rhs)
            let nameComparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return sorted
        }

        return sorted.filter { person in
            displayName(for: person).localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func personButton(for person: Person) -> some View {
        let isFiltered = PersonFilterState.shared.active?.personID == person.id
        Button {
            if isFiltered {
                PersonFilterState.shared.clear()
            } else {
                PersonFilterState.shared.set(personID: person.id, name: person.name)
            }
        } label: {
            VStack(spacing: 8) {
                RepresentativeImageView(url: person.representative)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: isFiltered ? 3 : 0)
                    )
                Text(displayName(for: person))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isFiltered ? Color.accentColor : .primary)
            }
        }
        .buttonStyle(.plain)
        .help(isFiltered ? "Click to clear filter" : "Click to filter the gallery to this person")
        .contextMenu {
            Button("Edit Person...") {
                selectedPerson = person
            }
            if isFiltered {
                Button("Clear Filter") {
                    PersonFilterState.shared.clear()
                }
            } else {
                Button("Filter Gallery") {
                    PersonFilterState.shared.set(personID: person.id, name: person.name)
                }
            }
        }
    }

    private func displayName(for person: Person) -> String {
        let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return name
        }
        return "Person - \(person.count)"
    }

    private func rescanFaces() {
        guard !FaceScanProgress.shared.isActive else { return }
        let clusterTask = Task.detached {
            _ = await FaceProcessor.shared.clusterFaces { completed, total, status in
                Task { @MainActor in
                    FaceScanProgress.shared.update(completed: completed, total: total, status: status)
                }
            }
            let list = await FaceProcessor.shared.allPeople()
            await MainActor.run {
                people = list
                FaceScanProgress.shared.end()
            }
        }
        FaceScanProgress.shared.begin(title: "Grouping faces", total: 1) {
            clusterTask.cancel()
        }
    }

    // Small helper that loads an image off the main thread and displays it.
    private struct RepresentativeImageView: View {
        let url: URL
        @State private var image: NSImage?

        var body: some View {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                }
            }
            .frame(width: 120, height: 120)
            .clipped()
            .cornerRadius(8)
            .task(id: url) {
                let loaded = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
                if Task.isCancelled { return }
                if let loaded { image = loaded }
            }
        }
    }
}

#Preview {
    PeopleView()
}
