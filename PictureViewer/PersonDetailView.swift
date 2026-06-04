import SwiftUI
import AppKit

struct PersonDetailView: View {
    let person: Person
    var onChange: (() -> Void)?

    @State private var name: String = ""
    @State private var members: [PublicFace] = []
    @State private var selectedForSplit: Set<UUID> = []
    @State private var others: [Person] = []
    @State private var mergeTarget: UUID? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AsyncLoadedImage(url: person.representative, width: 120, height: 120)
                VStack(alignment: .leading) {
                    TextField("Name", text: $name)
                        .font(.title2)
                    Text("\(members.count) faces")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            Text("Members")
                .font(.headline)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                    ForEach(members) { face in
                        VStack {
                            AsyncLoadedImage(url: face.thumbURL, width: 80, height: 80)
                            Toggle(isOn: Binding(get: {
                                selectedForSplit.contains(face.id)
                            }, set: { v in
                                if v { selectedForSplit.insert(face.id) } else { selectedForSplit.remove(face.id) }
                            })) {
                                Text("")
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)

            HStack {
                Button("Save Name") {
                    Task.detached {
                        await FaceProcessor.shared.renamePerson(personID: person.id, to: name)
                        await MainActor.run { onChange?() }
                    }
                }
                Spacer()
                Menu("Merge") {
                    ForEach(others) { o in
                        Button(o.name ?? "Person") {
                                Task.detached {
                                    await FaceProcessor.shared.mergePerson(source: person.id, into: o.id)
                                    await MainActor.run {
                                        onChange?()
                                        dismiss()
                                    }
                                }
                        }
                    }
                }
                Button("Split Selected") {
                        let toMove = Array(selectedForSplit)
                        Task.detached {
                            if !toMove.isEmpty {
                                _ = await FaceProcessor.shared.splitPerson(personID: person.id, faceIDsToMove: toMove)
                                let updated = await FaceProcessor.shared.facesForPerson(personID: person.id)
                                await MainActor.run {
                                    selectedForSplit.removeAll()
                                    members = updated
                                    onChange?()
                                }
                            }
                        }
                }
                .disabled(selectedForSplit.isEmpty)
            }
        }
        .padding(12)
        .onAppear {
            name = person.name ?? "Person"
            Task.detached {
                let mems = await FaceProcessor.shared.facesForPerson(personID: person.id)
                let all = (await FaceProcessor.shared.personsList()).filter { $0.id != person.id }
                await MainActor.run {
                    members = mems
                    others = all
                }
            }
        }
    }
}

// Simple async image loader used by people/person detail UI to avoid
// synchronous main-thread image decoding.
private struct AsyncLoadedImage: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .cornerRadius(6)
        .task(id: url) {
            let loaded = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
            if Task.isCancelled { return }
            if let loaded { image = loaded }
        }
    }
}

#Preview {
    PersonDetailView(person: Person(id: UUID(), representative: URL(fileURLWithPath: "/"), count: 1, sampleSource: nil, name: "Person"))
}
