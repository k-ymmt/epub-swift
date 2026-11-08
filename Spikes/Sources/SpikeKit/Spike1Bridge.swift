import Foundation
import WebKit

/// 1. allowsContentJavaScript = false + WKUserScript in a dedicated WKContentWorld,
///    callAsyncJavaScript and WKScriptMessageHandlerWithReply.
@MainActor
public func runSpike1(_ ctx: SpikeContext) async -> SpikeResult {
    var r = SpikeResult(id: 1, title: "allowsContentJavaScript = false と WKUserScript / callAsyncJavaScript / replyHandler")
    do {
        for allowContent in [false, true] {
            let host = WebHost(
                visibleSize: CGSize(width: 300, height: 400),
                allowsContentJavaScript: allowContent,
                userScripts: [
                    UserScriptSpec(Fixtures.readerStartScript, at: .atDocumentStart),
                    UserScriptSpec(Fixtures.readerUserScript, at: .atDocumentEnd),
                ]
            )
            host.replyProvider = { body in ["pong": true, "echoType": body["type"] ?? "?"] }
            host.serve("/bridge.xhtml", Fixtures.xhtmlMIME, Fixtures.bridgeXHTML)
            try await host.load("/bridge.xhtml")
            let ready = try await host.waitForMessage(type: "ready")
            let payload = ready["payload"] as? [String: Any] ?? [:]
            r.note("allowsContentJavaScript=\(allowContent): `ready` 受信 payload=\(payload)")

            let ping = try await host.jsDict("return window.__epubReader.ping(value)", args: ["value": 42])
            r.note("allowsContentJavaScript=\(allowContent): callAsyncJavaScript(reader world) → \(ping)")
            try await host.settle(200)
            let reply = try await host.js("return window.__epubReader.lastReply ?? window.__epubReader.lastError")
            r.note("allowsContentJavaScript=\(allowContent): postMessage の reply → \(reply ?? "nil")")

            let pageWorld = try await host.jsDict(
                "return { contentRan: window.__contentRan === true, readerVisibleInPageWorld: typeof window.__epubReader, title: document.title }",
                world: .page)
            r.note("allowsContentJavaScript=\(allowContent): page world → \(pageWorld)")

            if !allowContent {
                let contentBlocked = (ping["contentJS"] == nil || ping["contentJS"] is NSNull)
                    && (ping["inlineHandler"] == nil || ping["inlineHandler"] is NSNull)
                    && (pageWorld["contentRan"] as? Bool) == false
                    && (pageWorld["title"] as? String) == "bridge"
                let bridgeOK = (ping["ok"] as? Bool) == true && (ping["echo"] as? Int) == 42
                    && (reply as? [String: Any])?["pong"] as? Bool == true
                    && (pageWorld["readerVisibleInPageWorld"] as? String) == "undefined"
                r.verdict = (contentBlocked && bridgeOK) ? .pass : .fail
                r.note("判定根拠: contentBlocked=\(contentBlocked) bridgeOK=\(bridgeOK)")
            } else {
                let contentRan = (ping["contentJS"] as? String) == "ran" && (pageWorld["contentRan"] as? Bool) == true
                r.note("対照（content JS 有効）: コンテンツ JS が動いた=\(contentRan)（スイッチが効いている証拠）")
            }
        }
    } catch {
        r.error = "\(error)"; r.verdict = .fail
    }
    return r
}
