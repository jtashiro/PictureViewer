//
//  SettingsView.swift
//  PictureViewer
//

import SwiftUI
import AppKit

enum PhotoDisplayMode: String, CaseIterable, Identifiable, Sendable {
	case fullScreen
	case windowMaximized
	case windowed

	var id: String { rawValue }

	var label: String {
		switch self {
		case .fullScreen: "Full Screen"
		case .windowMaximized: "Maximized Window"
		case .windowed: "Window"
		}
	}

	var description: String {
		switch self {
		case .fullScreen:
			"Take over the entire display, hiding the menu bar and Dock."
		case .windowMaximized:
			"Fill the visible screen area, but keep the menu bar and Dock visible."
		case .windowed:
			"Open photos in a regular resizable window."
		}
	}
}

struct SettingsView: View {
	@AppStorage("photoDisplayMode") private var displayMode: PhotoDisplayMode = .fullScreen
	@AppStorage("saveOpenWindows") private var saveOpenWindows: Bool = false
	@AppStorage("requirePasswordAtLaunch") private var requirePasswordAtLaunch: Bool = true
	@AppStorage("deferAtLaunchBackgroundWork") private var deferAtLaunchBackgroundWork: Bool = true
	@AppStorage(AppLogLevel.userDefaultsKey) private var logLevelRaw: String = AppLogLevel.defaultLevel.rawValue
	@AppStorage(SQLiteObjectStore.encryptBlobsKey) private var sqliteObjectStoreEncryptBlobs: Bool = false
	@AppStorage(SQLiteObjectStore.storeNameKey) private var sqliteObjectStoreName: String = SQLiteObjectStore.defaultStoreName

	var body: some View {
		TabView {
			generalTab
				.tabItem { Label("General", systemImage: "gearshape") }
			performanceTab
				.tabItem { Label("Performance", systemImage: "cpu") }
			storageTab
				.tabItem { Label("Storage", systemImage: "externaldrive") }
		}
		.frame(width: 560, height: 440)
	}

	private var generalTab: some View {
		Form {
			Section {
				Picker(selection: $displayMode) {
					ForEach(PhotoDisplayMode.allCases) { mode in
						Text(mode.label).tag(mode)
					}
				} label: {
					Text("Open photos in")
				}
				.pickerStyle(.radioGroup)

				Text(displayMode.description)
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Photo Display")
			}

			Section {
				Toggle("Save Open Windows and Reload at Start", isOn: $saveOpenWindows)
				Text("When enabled, the folder you're browsing and any open photo windows are remembered, and reopened the next time you launch Picture Viewer.")
					.font(.caption)
					.foregroundStyle(.secondary)
				Toggle("Password protection (require macOS credentials at launch)", isOn: $requirePasswordAtLaunch)
				Text("When enabled, Picture Viewer will require your macOS password or Touch ID at launch before showing any content.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Session")
			}
		}
		.formStyle(.grouped)
	}

	private var performanceTab: some View {
		Form {
			Section {
				LabeledContent("Logical CPU cores",
							   value: "\(ProcessInfo.processInfo.processorCount)")
				LabeledContent("Active cores",
							   value: "\(ProcessInfo.processInfo.activeProcessorCount)")
				LabeledContent("Scanner threads",
							   value: "\(PhotoLibrary.workerCount)")
				Toggle("Defer at-launch background work (use cached snapshot, skip re-scan)", isOn: $deferAtLaunchBackgroundWork)
				Text("When enabled, the app will populate the UI from the saved snapshot at launch but skip the potentially expensive background re-scan.")
					.font(.caption)
					.foregroundStyle(.secondary)

				Picker("Log level", selection: $logLevelRaw) {
					ForEach(AppLogLevel.allCases) { level in
						Text(level.title).tag(level.rawValue)
					}
				}
				Text("Default is Info. Set to Debug to show verbose thumbnail/cache diagnostics.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Detected at launch")
			} footer: {
				Text("Folder scans run in parallel across the listed worker threads to load large libraries quickly.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
	}

	private var storageTab: some View {
		Form {
			Section {
				TextField("Store name", text: $sqliteObjectStoreName)
					.textFieldStyle(.roundedBorder)
				Toggle("Encrypt BLOB content", isOn: $sqliteObjectStoreEncryptBlobs)
				Text("When disabled, BLOB content is stored in SQLite as original file bytes. When enabled, BLOB content is AES-GCM encrypted before it is written.")
					.font(.caption)
					.foregroundStyle(.secondary)

				LabeledContent("Database file", value: SQLiteObjectStore.configuredDatabaseFilename)
			} header: {
				Text("SQLite Object Store")
			} footer: {
				Text("SQLite stores are always available. Use File > New or File > Open to create or choose a store.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
	}

}
