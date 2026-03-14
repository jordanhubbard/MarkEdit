//
//  EditorViewController+LivePreview.swift
//  MarkEditMac
//

import AppKit

extension EditorViewController {
  func toggleLivePreview() {
    if livePreviewController != nil {
      hideLivePreview()
    } else {
      showLivePreview()
    }
  }

  /// Called when the editor content changes or the document is reset.
  func refreshLivePreview(useDocumentValue: Bool = false) {
    guard let controller = livePreviewController else {
      return
    }

    let ext = document?.fileURL?.pathExtension.lowercased() ?? "md"
    let isMermaid = ext == "mmd"

    if useDocumentValue {
      controller.scheduleUpdate(text: document?.stringValue ?? "", isMermaid: isMermaid)
      return
    }

    Task {
      guard let text = await editorText else { return }
      controller.scheduleUpdate(text: text, isMermaid: isMermaid)
    }
  }
}

// MARK: - Private

extension EditorViewController {
  func showLivePreview() {
    let controller = LivePreviewWindowController(webView: webView)
    livePreviewController = controller

    let ext = document?.fileURL?.pathExtension.lowercased() ?? "md"
    let isMermaid = ext == "mmd"
    // Use stringValue for a synchronous first pass (may be empty for async-loaded docs),
    // then immediately schedule an async refresh to get the actual editor content.
    let text = document?.stringValue ?? ""
    controller.show(text: text, isMermaid: isMermaid)
    refreshLivePreview()
  }

  private func hideLivePreview() {
    livePreviewController?.close()
    livePreviewController = nil
  }
}
