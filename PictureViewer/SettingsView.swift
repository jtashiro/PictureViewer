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
	@AppStorage("useVLCForVideoPlayback") private var useVLCForVideoPlayback: Bool = false
	@AppStorage("saveOpenWindows") private var saveOpenWindows: Bool = false
	@AppStorage("requirePasswordAtLaunch") private var requirePasswordAtLaunch: Bool = true
	@AppStorage("deferAtLaunchBackgroundWork") private var deferAtLaunchBackgroundWork: Bool = true
	@AppStorage(AppLogLevel.userDefaultsKey) private var logLevelRaw: String = AppLogLevel.defaultLevel.rawValue
	@AppStorage(AppWorkingDirectory.directoryPathKey) private var appWorkingDirectoryPath: String = ""
	@AppStorage("ollamaSelectedModel") private var ollamaSelectedModel: String = OllamaRecognizer.defaultModel
@AppStorage("ollamaServerHost") private var ollamaServerHost: String = "localhost"
@AppStorage("ollamaNumCtx") private var ollamaNumCtx: Int = 4096
	@State private var workingDirectoryMessage: String?
	@State private var ollamaModels: [String] = []
	@State private var ollamaLoading: Bool = false
	@State private var ollamaStatus: String = "Click Reload to query Ollama for vision-capable models."

	var body: some View {
		TabView {
			generalTab
				.tabItem { Label("General", systemImage: "gearshape") }
			performanceTab
				.tabItem { Label("Performance", systemImage: "cpu") }
			storageTab
				.tabItem { Label("Storage", systemImage: "externaldrive") }
			ollamaTab
				.tabItem { Label("Ollama", systemImage: "eye") }
		}
		.frame(width: 620, height: 520)
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
				Toggle("Use VLC for video playback", isOn: $useVLCForVideoPlayback)
				Text(vlcStatusText)
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Video Playback")
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

	private var vlcStatusText: String {
		if EmbeddedVLCPlayerView.isAvailable {
			return "When enabled, videos play inside Picture Viewer using libVLC from VLC.app."
		}
		return "VLC.app or its libVLC runtime could not be found. QuickTime-supported videos will use the built-in player; .wmv requires embedded VLC playback."
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
				LabeledContent("Working directory", value: currentWorkingDirectoryDisplayPath)
				HStack {
					Button("Choose...") {
						chooseWorkingDirectory()
					}
					Button("Use Default") {
						AppWorkingDirectory.resetToDefault()
						appWorkingDirectoryPath = ""
						workingDirectoryMessage = "Using default working directory."
					}
					Button("Delete Existing") {
						deleteExistingWorkingDirectory()
					}
				}
				if let workingDirectoryMessage {
					Text(workingDirectoryMessage)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Application Working Directory")
			} footer: {
				Text("SQLite working copies, vault working copies, and temporary video thumbnail snapshots are written here. Delete existing working files after closing open media windows.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
	}

	private var ollamaTab: some View {
		Form {
			Section {
				HStack {
					Picker("Vision model", selection: $ollamaSelectedModel) {
						if !ollamaModels.contains(ollamaSelectedModel) {
							Text(ollamaSelectedModel.isEmpty ? "(none)" : "\(ollamaSelectedModel) (not loaded)")
								.tag(ollamaSelectedModel)
						}
						ForEach(ollamaModels, id: \.self) { name in
							Text(modelPickerLabel(for: name)).tag(name)
						}
					}
					.disabled(ollamaLoading)

					Button {
						Task { await reloadOllamaModels() }
					} label: {
						if ollamaLoading {
							ProgressView().controlSize(.small)
						} else {
							Image(systemName: "arrow.clockwise")
						}
					}
					.disabled(ollamaLoading)
					.help("Query Ollama for installed vision models")
				}

				Text(ollamaStatus)
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			} header: {
				Text("Image Recognition")
			}
			
			Section {
				TextField("Ollama Server Host", text: $ollamaServerHost)
					.help("Enter the hostname or IP address of your Ollama server (default: localhost)")
				
				Text("The app will connect to http://[host]:11434/api/tags and /api/generate")
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Ollama Server Configuration")
			}
			
			Section {
				TextField("Context Length (num_ctx)", value: $ollamaNumCtx, format: .number)
					.help("Set the context length for Ollama requests. Default is 65535.")
				
				Text("The num_ctx parameter controls how much context Ollama uses for responses. Higher values allow more context but use more memory.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Advanced Ollama Settings")
			}
		}
		.formStyle(.grouped)
		.task {
			if ollamaModels.isEmpty {
				await reloadOllamaModels()
			}
		}
	}

	private func modelPickerLabel(for name: String) -> String {
		OllamaRecognizer.isLikelyUncensored(name) ? "\(name) — uncensored" : name
	}

	@MainActor
	private func reloadOllamaModels() async {
		ollamaLoading = true
		ollamaStatus = "Querying Ollama…"
		do {
			let models = try await OllamaRecognizer.shared.availableVisionModels()
			ollamaModels = models
			if models.isEmpty {
				ollamaStatus = "Ollama responded, but no vision-capable models are installed. Run `ollama pull llava` (or another vision model) in Terminal."
			} else {
				ollamaStatus = "Found \(models.count) vision-capable model\(models.count == 1 ? "" : "s")."
				if !models.contains(ollamaSelectedModel), let first = models.first {
					ollamaSelectedModel = first
				}
			}
		} catch {
			ollamaStatus = "Could not reach Ollama: \(error.localizedDescription). Make sure `ollama serve` is running and that Outgoing Connections (Client) is enabled in the App Sandbox capabilities."
		}
		ollamaLoading = false
	}

	private var currentWorkingDirectoryDisplayPath: String {
		AppWorkingDirectory.baseURL.path
	}

	private func chooseWorkingDirectory() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = true
		panel.message = "Choose where Picture Viewer should write working files"
		panel.prompt = "Choose"
		if panel.runModal() == .OK, let url = panel.url {
			AppWorkingDirectory.setBaseURL(url)
			appWorkingDirectoryPath = url.path
			workingDirectoryMessage = "Working directory updated."
		}
	}

	private func deleteExistingWorkingDirectory() {
		do {
			try AppWorkingDirectory.deleteExistingWorkingDirectories()
			PhotoVault.clearWorkingCopiesOnDisk()
			SQLiteObjectStore.clearWorkingCopiesOnDisk()
			workingDirectoryMessage = "Existing working files deleted."
		} catch {
			workingDirectoryMessage = "Could not delete working files: \(error.localizedDescription)"
		}
	}

}
