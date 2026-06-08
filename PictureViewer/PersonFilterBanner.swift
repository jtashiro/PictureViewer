//
//  PersonFilterBanner.swift
//  PictureViewer
//

import SwiftUI

struct PersonFilterBanner: View {
	@ObservedObject var personFilterState: PersonFilterState

	var body: some View {
		if let active = personFilterState.active {
			HStack(spacing: 8) {
				Image(systemName: "person.crop.circle.fill")
					.foregroundStyle(.tint)
				Text("Showing photos of ")
					.foregroundStyle(.secondary)
				+ Text(active.personName)
					.fontWeight(.semibold)
				Spacer()
				Button("Clear Filter") {
					personFilterState.clear()
				}
				.buttonStyle(.borderless)
				.controlSize(.small)
			}
			.font(.callout)
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			.background(.thinMaterial)
			.overlay(alignment: .bottom) {
				Divider()
			}
		}
	}
}
