//
// DiagnosticsView.swift
//
// Shows the in-app diagnostics log with a copy button, so the exact SDK error
// can be pasted from a sideloaded build.
//

import SwiftUI
import UIKit

struct DiagnosticsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var log = DiagnosticsLog.shared
  @State private var copied = false

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(log.lines.isEmpty ? "No events yet. Start a session, then tap Preview." : log.text)
          .font(.system(size: 11, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
          .textSelection(.enabled)
      }
      .navigationTitle("Diagnostics")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          HStack {
            Button("Clear") { log.clear() }
            Button(copied ? "Copied" : "Copy") {
              UIPasteboard.general.string = log.text
              copied = true
            }
          }
        }
      }
    }
  }
}
