//
//  FaceScanProgress.swift
//  PictureViewer
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class FaceScanProgress: ObservableObject {
    static let shared = FaceScanProgress()

    @Published var isActive: Bool = false
    @Published var title: String = ""
    @Published var status: String = ""
    @Published var completed: Int = 0
    @Published var total: Int = 0
    @Published var isCancelling: Bool = false

    private var cancelHook: (@Sendable () -> Void)?

    private init() {}

    /// Begin a new progress session. Replaces any in-flight session.
    func begin(title: String, total: Int, cancel: @escaping @Sendable () -> Void) {
        self.title = title
        self.total = max(0, total)
        self.completed = 0
        self.status = ""
        self.isCancelling = false
        self.cancelHook = cancel
        self.isActive = true
    }

    func update(completed: Int, total: Int? = nil, status: String? = nil) {
        self.completed = max(0, completed)
        if let total { self.total = max(self.completed, total) }
        if let status { self.status = status }
    }

    func setTotal(_ total: Int) {
        self.total = max(self.completed, total)
    }

    func cancel() {
        guard isActive, !isCancelling else { return }
        isCancelling = true
        status = "Cancelling…"
        cancelHook?()
    }

    /// End the session and clear state.
    func end() {
        isActive = false
        isCancelling = false
        cancelHook = nil
        completed = 0
        total = 0
        status = ""
        title = ""
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

/// Cross-window selection state for filtering the gallery to a single
/// person's photos. PeopleView writes; ContentView reads and re-filters its
/// thumbnail grid in response.
@MainActor
final class PersonFilterState: ObservableObject {
    static let shared = PersonFilterState()

    struct Active: Equatable {
        let personID: UUID
        let personName: String
    }

    @Published var active: Active? = nil

    private init() {}

    func set(personID: UUID, name: String?) {
        active = Active(personID: personID, personName: name ?? "Person")
    }

    func clear() {
        active = nil
    }
}

/// Tracks face-processing progress for the library scan path and publishes
/// updates to `FaceScanProgress.shared` on the main actor.
actor FaceScanCoordinator {
    private var total = 0
    private var completed = 0
    private var cancelled = false

    func addToTotal(_ n: Int) async {
        total += n
        await publish()
    }

    func recordCompletion() async {
        completed += 1
        await publish()
    }

    func markCancelled() {
        cancelled = true
    }

    func isCancelled() -> Bool { cancelled }

    private func publish() async {
        let c = completed
        let t = total
        await MainActor.run {
            let statusText = t > 0 ? "Detecting faces \(c)/\(t)" : "Preparing…"
            FaceScanProgress.shared.update(completed: c, total: t, status: statusText)
        }
    }
}

struct FaceScanProgressOverlay: View {
    @ObservedObject private var progress = FaceScanProgress.shared

    var body: some View {
        if progress.isActive {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.rectangle.stack")
                        .foregroundStyle(.secondary)
                    Text(progress.title)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 12)
                    Button("Cancel") {
                        progress.cancel()
                    }
                    .controlSize(.small)
                    .disabled(progress.isCancelling)
                }
                if progress.total > 0 {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                if !progress.status.isEmpty {
                    Text(progress.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(12)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
