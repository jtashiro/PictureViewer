import SwiftUI
import AppKit

struct PeopleView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var faces: [PublicFace] = []
    @State private var people: [Person] = []
    @State private var selectedPerson: Person? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(people) { p in
                        Button {
                            selectedPerson = p
                        } label: {
                            VStack(spacing: 8) {
                                RepresentativeImageView(url: p.representative)
                                Text("Person — \(p.count)")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .navigationTitle("People")
        }
        // Ensure the people window has a reasonable minimum size so the
        // NavigationView / split behavior doesn't produce unsatisfiable
        // layout constraints when the window is created small.
        .frame(minWidth: 420, minHeight: 360)
        .onAppear {
            Task.detached {
                // Ensure faces are clustered before presenting people.
                await FaceProcessor.shared.clusterFaces()
                let list = await FaceProcessor.shared.allPeople()
                await MainActor.run { people = list }
            }
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
