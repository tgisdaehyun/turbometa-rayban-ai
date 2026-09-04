//
// ListenerTokenBag.swift
//
// Minimal stand-in for MWDATCore.ListenerTokenBag (added in SDK 0.9.0) so the
// 0.9.0 sample code builds unchanged against SDK 0.8.0, which this app pins to
// in order to keep the Device Access Toolkit App Model (DAM) switched off.
//

import Foundation
import MWDATCore

final class ListenerTokenBag: @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [any AnyListenerToken] = []

  func add(_ token: any AnyListenerToken) {
    lock.lock()
    tokens.append(token)
    lock.unlock()
  }

  /// Drops every stored token and cancels its listener.
  func clear() {
    lock.lock()
    let old = tokens
    tokens.removeAll()
    lock.unlock()
    guard !old.isEmpty else { return }
    Task {
      for token in old {
        await token.cancel()
      }
    }
  }
}

extension AnyListenerToken {
  func store(in bag: ListenerTokenBag) {
    bag.add(self)
  }
}
