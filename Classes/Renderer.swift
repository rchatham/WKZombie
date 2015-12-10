//
// Renderer.swift
//
// Copyright (c) 2015 Mathias Koehnke (http://www.mathiaskoehnke.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import WebKit

internal enum PostActionType {
    case Wait
    case Validate
}

internal struct PostAction {
    var type : PostActionType
    var value : AnyObject
    
    init(type: PostActionType, script: String) {
        self.type = type
        self.value = script
    }
    
    init(type: PostActionType, wait: NSTimeInterval) {
        self.type = type
        self.value = wait
    }
}

internal class Renderer : NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    
    typealias Completion = (result : AnyObject?, response: NSURLResponse?, error: NSError?) -> Void
    
    var loadMediaContent : Bool = true
    
    private var renderCompletion : Completion?
    private var renderResponse : NSURLResponse?
    private var renderError : NSError?
    
    private var postAction: PostAction?
    private var webView : WKWebView!
    
    override init() {
        super.init()
        let doneLoadingWithoutMediaContentScript = "window.webkit.messageHandlers.doneLoading.postMessage(document.documentElement.outerHTML);"
        let userScript = WKUserScript(source: doneLoadingWithoutMediaContentScript, injectionTime: WKUserScriptInjectionTime.AtDocumentEnd, forMainFrameOnly: true)
        
        let contentController = WKUserContentController()
        contentController.addUserScript(userScript)
        contentController.addScriptMessageHandler(self, name: "doneLoading")
        
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        
        webView = WKWebView(frame: CGRectZero, configuration: config)
        webView.navigationDelegate = self
        webView.addObserver(self, forKeyPath: "loading", options: .New, context: nil)
    }
    
    deinit {
        webView.removeObserver(self, forKeyPath: "loading", context: nil)
    }
    
    //
    // MARK: Render Page
    //
    
    internal func renderPageWithRequest(request: NSURLRequest, postAction: PostAction? = nil, completionHandler: Completion) {
        if let _ = renderCompletion {
            NSLog("Rendering already in progress ...")
            return
        }
        self.postAction = postAction
        self.renderCompletion = completionHandler
        self.webView.loadRequest(request)
    }
    
    //
    // MARK: Execute Script
    //
    
    internal func executeScript(script: String, willLoadPage: Bool? = false, postAction: PostAction? = nil, completionHandler: Completion?) {
        if let _ = renderCompletion {
            NSLog("Rendering already in progress ...")
            return
        }
        if let willLoadPage = willLoadPage where willLoadPage == true {
            self.postAction = postAction
            self.renderCompletion = completionHandler
            self.webView.evaluateJavaScript(script, completionHandler: nil)
        } else {
            let javaScriptCompletionHandler = { (result : AnyObject?, error : NSError?) -> Void in
                completionHandler?(result: result, response: nil, error: error)
            }
            self.webView.evaluateJavaScript(script, completionHandler: javaScriptCompletionHandler)
        }
    }
    
    //
    // MARK: Delegates
    //
    
    func userContentController(userContentController: WKUserContentController, didReceiveScriptMessage message: WKScriptMessage) {
        //None of the content loaded after this point is necessary (images, videos, etc.)
        if message.name == "doneLoading" && loadMediaContent == false {
            if let url = webView.URL where renderResponse == nil {
                renderResponse = NSHTTPURLResponse(URL: url, statusCode: 200, HTTPVersion: nil, headerFields: nil)
            }
            webView.stopLoading()
        }
    }
    
    func webView(webView: WKWebView, decidePolicyForNavigationResponse navigationResponse: WKNavigationResponse, decisionHandler: (WKNavigationResponsePolicy) -> Void) {
        if let _ = renderCompletion {
            renderResponse = navigationResponse.response
        }
        decisionHandler(.Allow)
    }
    
    func webView(webView: WKWebView, didFailNavigation navigation: WKNavigation!, withError error: NSError) {
        if let renderResponse = renderResponse as? NSHTTPURLResponse, _ = renderCompletion {
            let successRange = 200..<300
            if !successRange.contains(renderResponse.statusCode) {
                renderError = error
                callRenderCompletion(nil)
            }
        }
    }
    
    private func callRenderCompletion(renderResult: String?) {
        let data = renderResult?.dataUsingEncoding(NSUTF8StringEncoding)
        let completion = renderCompletion
        renderCompletion = nil
        completion?(result: data, response: renderResponse, error: renderError)
        renderResponse = nil
        renderError = nil
    }
    
    func finishedLoading(webView: WKWebView) {
        webView.evaluateJavaScript("document.documentElement.outerHTML;") { [weak self] result, error in
            HLLog("\(result)")
            self?.callRenderCompletion(result as? String)
        }
    }
    
    func validate(condition: String, webView: WKWebView) {
        webView.evaluateJavaScript(condition) { [weak self] result, error in
            if let result = result as? Bool where result == true {
                self?.finishedLoading(webView)
            } else {
                delay(0.5, completion: {
                    self?.validate(condition, webView: webView)
                })
            }
        }
    }
    
    func waitAndFinish(time: NSTimeInterval, webView: WKWebView) {
        delay(time) {
            self.finishedLoading(webView)
        }
    }
    
    func handlePostAction(postAction: PostAction) {
        switch postAction.type {
        case .Validate: validate(postAction.value as! String, webView: webView)
        case .Wait: waitAndFinish(postAction.value as! NSTimeInterval, webView: webView)
        }
        self.postAction = nil
    }
    
    // MARK: KVO
    
    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        if keyPath == "loading" && webView.loading == false {
            if let postAction = postAction {
                handlePostAction(postAction)
            } else {
                finishedLoading(webView)
            }
        }
    }
}

// MARK: Helper

private func delay(time: NSTimeInterval, completion: () -> Void) {
    let delayTime = dispatch_time(DISPATCH_TIME_NOW, Int64(time * Double(NSEC_PER_SEC)))
    dispatch_after(delayTime, dispatch_get_main_queue()) {
        completion()
    }
}
