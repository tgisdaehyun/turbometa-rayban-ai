//
// DiagnosticsLog.swift
//
// In-app log of SDK lifecycle events and errors, so a sideloaded build (no
// Xcode console) can still tell us exactly which DeviceSessionError /
// StreamError / PermissionError fired and in what order.
//

import Foundation
import Observation

@MainActor
@Observable
final class DiagnosticsLog {
  static let shared = DiagnosticsLog()

  private(set) var lines: [String] = []
  private let maxLines = 600
  private let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  var text: String { lines.joined(separator: "\n") }

  func add(_ message: String) {
    let line = "\(formatter.string(from: Date())) \(message)"
    lines.append(line)
    if lines.count > maxLines {
      lines.removeFirst(lines.count - maxLines)
    }
    NSLog("[MetaRec] %@", message)
  }

  func clear() {
    lines.removeAll()
  }

  /// Callable from any isolation; hops to the main actor.
  nonisolated static func log(_ message: String) {
    Task { @MainActor in shared.add(message) }
  }
}

/// Full detail for an error: the SDK's human-readable text plus the enum case
/// (and any associated value such as a device identifier), which is what we
/// actually need to diagnose a failure.
func describeError(_ error: any Error) -> String {
  let reflected = String(reflecting: error)
  let localized = error.localizedDescription
  if reflected.contains(localized) { return reflected }
  return "\(localized) [\(reflected)]"
}
