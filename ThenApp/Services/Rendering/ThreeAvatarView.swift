import SwiftUI
import UIKit
import WebKit

struct AvatarRenderConfiguration: Equatable {
  let sessionID: String
  let top: String
  let bottom: String
  let shoes: String
  let shoulderWidth: Double
  let torsoDepth: Double
  let yaw: Double
  let revision: Int
}

struct BundledAvatarImage: View {
  let name: String

  var body: some View {
    if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "AvatarStudio"),
       let image = UIImage(contentsOfFile: url.path) {
      Image(uiImage: image).resizable()
    } else {
      Image(systemName: "tshirt.fill")
        .resizable()
        .scaledToFit()
        .foregroundStyle(.secondary)
        .padding()
    }
  }
}

enum AvatarRendererState: Equatable {
  case loading
  case ready
  case failed(String)
}

struct ThreeAvatarView: UIViewRepresentable {
  let configuration: AvatarRenderConfiguration
  let onStateChange: (AvatarRendererState) -> Void
  let onYawChange: (Double) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onStateChange: onStateChange, onYawChange: onYawChange)
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.userContentController.add(context.coordinator, name: "avatarBridge")
    configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "avatar")
    configuration.preferences.isElementFullscreenEnabled = false

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    webView.navigationDelegate = context.coordinator
    context.coordinator.webView = webView
    context.coordinator.pendingConfiguration = self.configuration

    do {
      context.coordinator.validatedAssets = try AvatarAssetCatalog.load()
    } catch {
      onStateChange(.failed("nativeAssetValidation"))
      return webView
    }

    guard let rendererURL = URL(string: "avatar://local/avatar.html") else {
      onStateChange(.failed("invalidRendererURL"))
      return webView
    }
    webView.load(URLRequest(url: rendererURL))
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    context.coordinator.pendingConfiguration = configuration
    context.coordinator.applyIfReady()
  }

  static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "avatarBridge")
    coordinator.webView = nil
    coordinator.validatedAssets = nil
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
    weak var webView: WKWebView?
    var pendingConfiguration: AvatarRenderConfiguration?
    var validatedAssets: AvatarValidatedAssets?
    private var appliedConfiguration: AvatarRenderConfiguration?
    private var isReady = false
    private let onStateChange: (AvatarRendererState) -> Void
    private let onYawChange: (Double) -> Void

    init(
      onStateChange: @escaping (AvatarRendererState) -> Void,
      onYawChange: @escaping (Double) -> Void
    ) {
      self.onStateChange = onStateChange
      self.onYawChange = onYawChange
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.name == "avatarBridge", let body = message.body as? [String: Any], let type = body["type"] as? String else {
        return
      }
      switch type {
      case "ready":
        guard body["assetCount"] as? Int == 8 else {
          onStateChange(.failed("invalidAssetCount"))
          return
        }
        isReady = true
        onStateChange(.ready)
        applyIfReady()
      case "angle":
        guard messageMatchesPending(body), let yaw = body["yaw"] as? Double, yaw.isFinite else { return }
        onYawChange(yaw)
      case "applied":
        guard messageMatchesPending(body) else { return }
        onStateChange(.ready)
      case "failed":
        let code = body["code"] as? String ?? "unknown"
        print("Avatar renderer failed: \(code)")
        onStateChange(.failed(code))
      default:
        break
      }
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      guard navigationAction.request.url?.scheme == "avatar" else {
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
      print("Avatar renderer navigation failed: \(error.localizedDescription)")
      onStateChange(.failed("navigationFailed"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
      print("Avatar renderer provisional navigation failed: \(error.localizedDescription)")
      onStateChange(.failed("provisionalNavigationFailed"))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      isReady = false
      appliedConfiguration = nil
      onStateChange(.loading)
      webView.reloadFromOrigin()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
      guard let url = urlSchemeTask.request.url else {
        urlSchemeTask.didFailWithError(URLError(.badURL))
        return
      }
      if url.host == "local", url.pathComponents.dropFirst().first == "assets" {
        guard let data = validatedAssets?.resources[url.lastPathComponent] else {
          urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
          return
        }
        let response = URLResponse(
          url: url,
          mimeType: "model/gltf-binary",
          expectedContentLength: data.count,
          textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
        return
      }
      guard url.host == "local",
            let resource = Self.rendererResources[url.lastPathComponent],
            let fileURL = Bundle.main.url(
              forResource: resource.name,
              withExtension: resource.extension,
              subdirectory: resource.subdirectory
            ),
            let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
        print("Avatar renderer resource missing: \(url.lastPathComponent)")
        urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
        return
      }
      let response = URLResponse(
        url: url,
        mimeType: resource.mimeType,
        expectedContentLength: data.count,
        textEncodingName: resource.textEncoding
      )
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    func applyIfReady() {
      guard isReady,
            let pendingConfiguration,
            pendingConfiguration != appliedConfiguration,
            let webView else { return }
      let payload: [String: Any] = [
        "session": pendingConfiguration.sessionID,
        "top": pendingConfiguration.top,
        "bottom": pendingConfiguration.bottom,
        "shoes": pendingConfiguration.shoes,
        "shoulderWidth": pendingConfiguration.shoulderWidth,
        "torsoDepth": pendingConfiguration.torsoDepth,
        "yaw": pendingConfiguration.yaw,
        "revision": pendingConfiguration.revision,
      ]
      guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8) else {
        onStateChange(.failed("invalidNativePayload"))
        return
      }
      // Payload values come only from the closed built-in garment catalog.
      webView.evaluateJavaScript("window.ThenAvatar.apply(\(json))") { [weak self] _, error in
        guard error == nil else {
          self?.onStateChange(.failed("applyJavaScriptFailed"))
          return
        }
        self?.appliedConfiguration = pendingConfiguration
      }
    }

    private func messageMatchesPending(_ body: [String: Any]) -> Bool {
      guard let pendingConfiguration,
            body["session"] as? String == pendingConfiguration.sessionID,
            body["revision"] as? Int == pendingConfiguration.revision else {
        return false
      }
      return true
    }

    private static let rendererResources: [String: (
      name: String,
      extension: String,
      subdirectory: String,
      mimeType: String,
      textEncoding: String?
    )] = [
      "avatar.html": ("avatar", "html", "AvatarStudio/Renderer", "text/html", "utf-8"),
      "avatar.css": ("avatar", "css", "AvatarStudio/Renderer", "text/css", "utf-8"),
      "avatar.js": ("avatar", "js", "AvatarStudio/Renderer", "text/javascript", "utf-8"),
      "GLTFLoader.js": ("GLTFLoader", "js", "AvatarStudio/Renderer", "text/javascript", "utf-8"),
      "three.module.min.js": ("three.module.min", "js", "AvatarStudio/Renderer", "text/javascript", "utf-8"),
      "three.core.min.js": ("three.core.min", "js", "AvatarStudio/Renderer", "text/javascript", "utf-8"),
      "BufferGeometryUtils.js": ("BufferGeometryUtils", "js", "AvatarStudio/Renderer/utils", "text/javascript", "utf-8"),
      "SkeletonUtils.js": ("SkeletonUtils", "js", "AvatarStudio/Renderer/utils", "text/javascript", "utf-8"),
    ]
  }
}
