import Foundation

enum AppLogLevel: String, CaseIterable, Identifiable, Sendable {
	case debug
	case info
	case error

	static let userDefaultsKey = "logLevel"
	static let defaultLevel: AppLogLevel = .info

	var id: String { rawValue }

	var title: String {
		switch self {
		case .debug: return "Debug"
		case .info: return "Info"
		case .error: return "Error"
		}
	}

	var rank: Int {
		switch self {
		case .debug: return 0
		case .info: return 1
		case .error: return 2
		}
	}

	func allows(_ level: AppLogLevel) -> Bool {
		level.rank >= rank
	}

	static var current: AppLogLevel {
		let value = UserDefaults.standard.string(forKey: userDefaultsKey) ?? defaultLevel.rawValue
		return AppLogLevel(rawValue: value) ?? defaultLevel
	}
}
