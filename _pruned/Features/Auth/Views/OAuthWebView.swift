//
//  OAuthWebView.swift
//  contextgo
//
//  WebView for OAuth authentication flow with custom User-Agent
//

import SwiftUI
import WebKit

struct OAuthWebViewContainer: View {
    let url: URL
    let onSuccess: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            OAuthWebView(url: url, onSuccess: onSuccess)
                .navigationTitle("Sign In")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Cancel") {
                            onCancel()
                        }
                    }
                }
        }
    }
}

// MARK: - WKWebView Wrapper

struct OAuthWebView: UIViewRepresentable {
    let url: URL
    let onSuccess: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Set custom User-Agent with "contextgo" identifier
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        // Set custom User-Agent
        webView.customUserAgent = "ContextGo-iOS/1.0 (iPhone; iOS) Safari/604.1"

        // Load the OAuth URL
        let request = URLRequest(url: url)
        webView.load(request)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No update needed
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: OAuthWebView

        init(parent: OAuthWebView) {
            self.parent = parent
        }

        // Intercept navigation to detect the callback URL
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Check if this is our custom scheme callback (contextgo://)
            if url.scheme == "contextgo" {
                Task { @MainActor in
                    parent.onSuccess()
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        // Handle navigation errors
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[OAuth] Navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[OAuth] Provisional navigation failed: \(error.localizedDescription)")
        }
    }
}
