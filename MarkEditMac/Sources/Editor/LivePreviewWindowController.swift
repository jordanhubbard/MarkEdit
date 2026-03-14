//
//  LivePreviewWindowController.swift
//  MarkEditMac
//

import OSLog
import WebKit

/**
 Injects a live-preview side panel into the editor's existing WKWebView.

 This deliberately avoids creating a second WKWebView, which triggers a fatal
 Swift 6 executor-check crash in macOS 26 (swift_task_isCurrentExecutorWithFlagsImpl
 via WebKit's RemoteLayerTreePropertyApplier).  Instead, we evaluate JavaScript
 directly on the editor page to build a side-by-side DOM panel.
 */
@MainActor
final class LivePreviewWindowController {
  private let webView: WKWebView
  nonisolated(unsafe) private var debounceTimer: Timer?

  private let logHandler = MKPLogHandler()
  fileprivate static let log = Logger(subsystem: "app.cyan.markedit", category: "LivePreview")

  init(webView: WKWebView) {
    self.webView = webView
    Self.log.info("[\(#function)] init — webView=\(String(describing: ObjectIdentifier(webView)))")
  }

  deinit {
    debounceTimer?.invalidate()
  }

  // MARK: - Public API

  /// Inject the preview panel and render initial content.
  func show(text: String, isMermaid: Bool) {
    Self.log.info("[\(#function)] injecting setup JS (text \(text.count) chars, isMermaid=\(isMermaid))")

    // Install JS→Swift console bridge before injecting the panel.
    installConsoleCapture()

    webView.evaluateJavaScript(setupJS) { [weak self] result, error in
      if let error {
        Self.log.error("[\(#function)] setupJS eval error: \(String(describing: error))")
      } else {
        Self.log.info("[\(#function)] setupJS eval OK, result=\(String(describing: result))")
      }
      // Defer to next run loop to avoid nested evaluateJavaScript calls,
      // which can cause completions to be silently dropped on macOS 26.
      DispatchQueue.main.async {
        self?.applyUpdate(text: text, isMermaid: isMermaid)
      }
    }
  }

  /// Remove the preview panel from the editor page.
  func close() {
    Self.log.info("[\(#function)]")
    debounceTimer?.invalidate()
    debounceTimer = nil
    webView.evaluateJavaScript("window.markEditPreview && window.markEditPreview.hide()")
  }

  /// Debounce rapid content changes (e.g. keystrokes) before re-rendering.
  func scheduleUpdate(text: String, isMermaid: Bool) {
    debounceTimer?.invalidate()
    debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
      Task { @MainActor in
        self?.applyUpdate(text: text, isMermaid: isMermaid)
      }
    }
  }
}

// MARK: - JS console message handler

/// Thin NSObject wrapper so we can conform to WKScriptMessageHandler without
/// making LivePreviewWindowController itself inherit NSObject.
private final class MKPLogHandler: NSObject, WKScriptMessageHandler {
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == "mkpLog" else { return }
    let body = message.body as? String ?? String(describing: message.body)
    LivePreviewWindowController.log.info("[JS] \(body)")
  }
}

// MARK: - Private

private extension LivePreviewWindowController {
  func applyUpdate(text: String, isMermaid: Bool) {
    Self.log.info("[\(#function)] text=\(text.prefix(80))… isMermaid=\(isMermaid)")

    guard let jsonData = try? JSONEncoder().encode(text),
          let jsonText = String(data: jsonData, encoding: .utf8) else {
      Self.log.error("[\(#function)] JSONEncoder failed")
      return
    }

    let type = isMermaid ? "'mermaid'" : "'markdown'"
    let js = "window.markEditPreview && window.markEditPreview.update(\(jsonText), \(type))"
    // Use callAsync: true (.page world) for reliable evaluation on macOS 26.
    webView.evaluateJavaScript(js, callAsync: true) { result, error in
      if let error {
        Self.log.error("[\(#function)] update eval error: \(String(describing: error))")
      } else {
        Self.log.info("[\(#function)] update eval OK result=\(String(describing: result))")
      }
    }
  }

  /// Register a lightweight `mkpLog` message handler so JS inside the panel
  /// can forward `console.log/warn/error` output to the unified log.
  func installConsoleCapture() {
    let ucc = webView.configuration.userContentController
    // Guard: don't double-install across multiple show() calls.
    ucc.removeScriptMessageHandler(forName: "mkpLog")
    ucc.add(logHandler, name: "mkpLog")
    Self.log.info("[\(#function)] mkpLog handler installed")
  }

  var setupJS: String {
    #"""
    (function () {
      if (window.markEditPreview) return;

      /* ── Console capture → Swift ── */
      (function () {
        var _orig = { log: console.log, warn: console.warn, error: console.error };
        function fwd(level, args) {
          var msg = '[' + level + '] ' + Array.prototype.slice.call(args).join(' ');
          try { window.webkit.messageHandlers.mkpLog.postMessage(msg); } catch(e) {}
          _orig[level].apply(console, args);
        }
        console.log   = function() { fwd('log',   arguments); };
        console.warn  = function() { fwd('warn',  arguments); };
        console.error = function() { fwd('error', arguments); };

        window.addEventListener('error', function(e) {
          fwd('error', ['UncaughtError: ' + e.message + ' @ ' + e.filename + ':' + e.lineno]);
        });
        window.addEventListener('unhandledrejection', function(e) {
          fwd('error', ['UnhandledRejection: ' + (e.reason && e.reason.message || e.reason)]);
        });
      })();

      /* ── Styles ── */
      var style = document.createElement('style');
      style.id = 'markedit-preview-style';
      style.textContent = [
        'body.has-mkpreview { display: flex !important; overflow: hidden !important; }',
        'body.has-mkpreview #editor { width: 50% !important; flex-shrink: 0 !important;',
        '  border-right: 1px solid rgba(128,128,128,0.25); box-sizing: border-box !important; }',
        '#markedit-preview {',
        '  width: 50%; height: 100vh; overflow-y: auto; box-sizing: border-box;',
        '  padding: 24px 40px;',
        '  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;',
        '  font-size: 15px; line-height: 1.65; word-wrap: break-word;',
        '}',
        '#markedit-preview h1, #markedit-preview h2 {',
        '  border-bottom: 1px solid rgba(128,128,128,0.3); padding-bottom: 0.3em; }',
        '#markedit-preview h1 { font-size: 2em; margin-top: 0; }',
        '#markedit-preview h2 { font-size: 1.5em; }',
        '#markedit-preview h3, #markedit-preview h4, #markedit-preview h5, #markedit-preview h6 {',
        '  font-weight: 600; line-height: 1.25; }',
        '#markedit-preview p { margin-top: 0; margin-bottom: 16px; }',
        '#markedit-preview pre {',
        '  background: rgba(128,128,128,0.1); padding: 16px; border-radius: 6px;',
        '  overflow: auto; font-size: 85%; margin-bottom: 16px; }',
        '#markedit-preview code {',
        '  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;',
        '  font-size: 85%; background: rgba(128,128,128,0.15);',
        '  padding: 0.2em 0.4em; border-radius: 6px; }',
        '#markedit-preview pre code { background: transparent; padding: 0; font-size: 100%; }',
        '#markedit-preview blockquote {',
        '  margin: 0 0 16px; padding: 0 1em;',
        '  color: rgba(128,128,128,0.9); border-left: 0.25em solid rgba(128,128,128,0.4); }',
        '#markedit-preview img { max-width: 100%; height: auto; }',
        '#markedit-preview table {',
        '  border-collapse: collapse; width: 100%; margin-bottom: 16px;',
        '  display: block; overflow: auto; }',
        '#markedit-preview th, #markedit-preview td {',
        '  border: 1px solid rgba(128,128,128,0.3); padding: 6px 13px; }',
        '#markedit-preview th { font-weight: 600; }',
        '#markedit-preview a { color: #0969da; text-decoration: none; }',
        '@media (prefers-color-scheme: dark) {',
        '  #markedit-preview a { color: #58a6ff; } }',
        '#markedit-preview hr {',
        '  border: none; border-top: 1px solid rgba(128,128,128,0.3); margin: 24px 0; }',
        '#markedit-preview ul, #markedit-preview ol { padding-left: 2em; margin-bottom: 16px; }',
        '#markedit-preview .mkp-mermaid { text-align: center; margin: 16px 0; }',
        '#markedit-preview .mkp-error {',
        '  color: #cf222e; font-family: ui-monospace, monospace; font-size: 13px;',
        '  background: rgba(207,34,46,0.08); padding: 12px 16px; border-radius: 6px; }',
      ].join(' ');
      document.head.appendChild(style);
      console.log('mkp: style injected');

      /* ── Panel ── */
      document.body.classList.add('has-mkpreview');
      var panel = document.createElement('div');
      panel.id = 'markedit-preview';
      document.body.appendChild(panel);
      console.log('mkp: panel appended, body classes=' + document.body.className);

      /* ── marked.js ── */
      var markedReady = false;
      var pendingUpdate = null;

      var script = document.createElement('script');
      script.src = 'https://cdn.jsdelivr.net/npm/marked@13/marked.min.js';
      script.onload = function () {
        markedReady = true;
        console.log('mkp: marked.js loaded OK');
        if (pendingUpdate) {
          var u = pendingUpdate; pendingUpdate = null;
          window.markEditPreview.update(u.text, u.type);
        }
      };
      script.onerror = function (e) {
        console.error('mkp: marked.js FAILED to load from CDN — ' + (e.message || 'network error'));
      };
      document.head.appendChild(script);
      console.log('mkp: marked.js script tag appended');

      /* ── mermaid lazy-loader ── */
      var mermaidPromise = null;
      function loadMermaid() {
        if (!mermaidPromise) {
          mermaidPromise = import('https://cdn.jsdelivr.net/npm/mermaid@11.12.3/dist/mermaid.esm.min.mjs')
            .then(function (mod) {
              var isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
              mod.default.initialize({ startOnLoad: false, theme: isDark ? 'dark' : 'default' });
              console.log('mkp: mermaid loaded OK');
              return mod.default;
            })
            .catch(function(e) {
              console.error('mkp: mermaid FAILED to load — ' + (e && e.message || e));
              throw e;
            });
        }
        return mermaidPromise;
      }

      function escHtml(s) {
        return String(s)
          .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      }

      function renderMermaidBlocks(container) {
        var blocks = container.querySelectorAll('pre > code.language-mermaid');
        if (!blocks.length) return;
        loadMermaid().then(function (mermaid) {
          blocks.forEach(function (block, i) {
            var code = block.textContent || '';
            mermaid.render('mkp-inline-' + i + '-' + Date.now(), code).then(function (r) {
              var w = document.createElement('div');
              w.className = 'mkp-mermaid'; w.innerHTML = r.svg;
              var pre = block.closest('pre');
              if (pre) pre.replaceWith(w);
            }).catch(function () {});
          });
        });
      }

      /* ── Public API ── */
      window.markEditPreview = {
        update: function (text, type) {
          console.log('mkp: update called type=' + type + ' len=' + text.length);
          var p = document.getElementById('markedit-preview');
          if (!p) { console.error('mkp: #markedit-preview panel not found'); return; }
          if (type === 'mermaid') {
            loadMermaid().then(function (mermaid) {
              mermaid.render('mkp-graph-' + Date.now(), text).then(function (r) {
                p.innerHTML = '<div class="mkp-mermaid">' + r.svg + '</div>';
                console.log('mkp: mermaid render OK');
              }).catch(function (e) {
                p.innerHTML = '<pre class="mkp-error">' + escHtml(String(e && e.message || e)) + '</pre>';
                console.error('mkp: mermaid render error ' + (e && e.message || e));
              });
            });
          } else {
            if (!markedReady) {
              console.log('mkp: marked not ready yet, queuing update');
              pendingUpdate = { text: text, type: type };
              return;
            }
            p.innerHTML = marked.parse(text);
            console.log('mkp: markdown rendered, html length=' + p.innerHTML.length);
            renderMermaidBlocks(p);
          }
        },
        hide: function () {
          console.log('mkp: hide called');
          var p = document.getElementById('markedit-preview');
          if (p) p.remove();
          var s = document.getElementById('markedit-preview-style');
          if (s) s.remove();
          var ed = document.getElementById('editor');
          if (ed) { ed.style.width = ''; ed.style.flexShrink = ''; ed.style.borderRight = ''; ed.style.boxSizing = ''; }
          document.body.classList.remove('has-mkpreview');
          window.markEditPreview = null;
        }
      };
      console.log('mkp: window.markEditPreview installed');
    })();
    """#
  }
}
