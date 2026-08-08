//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumInternal
import ReadiumShared
import UIKit
import WebKit

/// A view rendering a spread of resources with a reflowable layout.
final class EPUBReflowableSpreadView: EPUBSpreadView {
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!

    private static let reflowableScript = loadScript(named: "readium-reflowable")

    required init(
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread,
        scripts: [WKUserScript],
        animatedLoad: Bool
    ) {
        super.init(
            viewModel: viewModel,
            spread: spread,
            scripts: [
                WKUserScript(source: Self.reflowableScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            ],
            animatedLoad: animatedLoad
        )
    }

    override func clear() {
        super.clear()

        // Clean up go to continuations.
        for continuation in goToContinuations {
            continuation.resume()
        }
        goToContinuations.removeAll()

        scrollDidEnd()
    }

    override func setupWebView() {
        super.setupWebView()

        scrollView.bounces = false
        // Since iOS 16, the default value of alwaysBounceX seems to be true
        // for web views.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false

        scrollView.isPagingEnabled = !viewModel.scroll

        // Connects: pinch-zoom breaks CSS multi-column pagination (pages smear together).
        // Use A± for font size instead. Fixed-layout spreads keep zoom elsewhere.
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1
        scrollView.zoomScale = 1
        for gesture in scrollView.gestureRecognizers ?? [] where gesture is UIPinchGestureRecognizer {
            gesture.isEnabled = false
        }

        webView.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = webView.topAnchor.constraint(equalTo: topAnchor)
        topConstraint.priority = .defaultHigh
        bottomConstraint = webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topConstraint, bottomConstraint,
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateContentInset()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateContentInset()
    }

    override func loadSpread() {
        guard spread.readingOrderIndices.count == 1 else {
            log(.error, "Only one document at a time can be displayed in a reflowable spread")
            return
        }
        let url = viewModel.url(to: spread.first.link)
        webView.load(URLRequest(url: url.url))
    }

    override func applySettings() {
        super.applySettings()

        // Disables paginated mode if scroll is on.
        scrollView.isPagingEnabled = !viewModel.scroll

        updateContentInset()
    }

    private func updateContentInset() {
        let contentInset = delegate?.spreadViewContentInset(self) ?? .zero

        if viewModel.scroll {
            topConstraint.constant = 0
            bottomConstraint.constant = 0
            scrollView.contentInset = contentInset

        } else {
            topConstraint.constant = contentInset.top
            bottomConstraint.constant = -contentInset.bottom
            scrollView.contentInset = .zero
        }
    }

    override func convertPointToNavigatorSpace(_ point: CGPoint) -> CGPoint {
        var point = point
        if viewModel.scroll {
            if scrollView.contentOffset.x < 0 {
                point.x += abs(scrollView.contentOffset.x)
            }
            if scrollView.contentOffset.y < 0 {
                point.y += abs(scrollView.contentOffset.y)
            }
        }
        point.x += webView.frame.minX
        point.y += webView.frame.minY
        return point
    }

    override func convertRectToNavigatorSpace(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin = convertPointToNavigatorSpace(rect.origin)
        return rect
    }

    // MARK: - Location and progression

    override func progression(in index: ReadingOrder.Index) -> ClosedRange<Double> {
        guard
            spread.first.index == index,
            let progression = progression
        else {
            return 0 ... 0
        }
        return progression
    }

    override func spreadDidLoad() async {
        let link = spread.first.link
        if let linkJSON = try? link.jsonString() {
            await evaluateScript("readium.link = \(linkJSON);")
        }

        // Fragment targets need both the element and column layout (scrollWidth).
        // Jumping before columns settle lands every #id on page 0 of the chapter.
        let location = pendingLocation
        if location.location.needsEndLanding {
            await waitForPaginatedLayoutSettled()
        } else if case let .locator(locator) = location.location,
                  let id = locator.locations.fragments.first, !id.isEmpty {
            await waitForPaginatedLayoutSettled(timeout: 0.6)
            await waitForFragmentElement(id)
        } else {
            await waitForPaginatedLayoutSettled(timeout: 0.2)
        }

        await go(to: location.location, animated: location.animated)

        if location.location.needsEndLanding {
            await scrollToEndWithRetry(animated: location.animated)
        } else if case let .locator(locator) = location.location,
                  let id = locator.locations.fragments.first, !id.isEmpty {
            // Second pass after columns finish expanding on huge XHTML.
            await waitForPaginatedLayoutSettled(timeout: 0.25)
            _ = await scroll(toTagID: id, animated: false)
        }
    }

    /// Poll until scrollable size is meaningfully larger than the viewport, or timeout.
    private func waitForPaginatedLayoutSettled(timeout: TimeInterval = 0.4) async {
        let viewport = max(scrollView.bounds.width, scrollView.bounds.height, 1)
        var lastExtent: CGFloat = 0
        var stableTicks = 0
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            scrollView.layoutIfNeeded()
            let extent: CGFloat = {
                if viewModel.scroll, !viewModel.verticalText {
                    return scrollView.contentSize.height
                }
                return scrollView.contentSize.width
            }()

            if extent > viewport * 1.05 {
                if abs(extent - lastExtent) < 1 {
                    stableTicks += 1
                    if stableTicks >= 2 { return }
                } else {
                    stableTicks = 0
                    lastExtent = extent
                }
            }
            try? await Task.sleep(seconds: 0.03)
        }
    }

    /// Wait until `id` exists and has a laid-out box (needed for scrollToId).
    private func waitForFragmentElement(_ id: String) async {
        let escaped = id
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            let result = await evaluateScript("""
            (function(){
              var el = document.getElementById('\(escaped)');
              if (!el) return false;
              var r = el.getBoundingClientRect();
              return (r.width + r.height) > 0 || (el.offsetWidth + el.offsetHeight) > 0;
            })();
            """)
            if case let .success(value) = result, (value as? Bool) == true {
                return
            }
            try? await Task.sleep(seconds: 0.03)
        }
    }

    private func scrollToEndWithRetry(animated: Bool) async {
        await scroll(toProgression: 1, animated: animated)
        scrollView.layoutIfNeeded()
        let viewport = max(scrollView.bounds.width, 1)
        let contentW = scrollView.contentSize.width
        // Still looks like a single page while we expected multi-column end — wait and retry.
        if !viewModel.scroll, contentW <= viewport * 1.1 {
            try? await Task.sleep(seconds: 0.05)
            scrollView.layoutIfNeeded()
            await scroll(toProgression: 1, animated: false)
        }
        // Native fallback if JS left us near the start in paginated mode.
        if !viewModel.scroll {
            let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
            if maxX > 1, scrollView.contentOffset.x < maxX * 0.5 {
                scrollView.contentOffset = CGPoint(x: maxX, y: scrollView.contentOffset.y)
            }
        }
    }

    override func go(to direction: EPUBSpreadView.Direction, options: NavigatorGoOptions) async -> Bool {
        guard !viewModel.scroll else {
            return await super.go(to: direction, options: options)
        }

        let factor: CGFloat = {
            switch direction {
            case .left:
                return -1
            case .right:
                return 1
            }
        }()

        guard scrollView.bounds.width > 0 else { return false }
        let offsetX = scrollView.bounds.width * factor
        let targetX = round((scrollView.contentOffset.x + offsetX) / offsetX) * offsetX
        guard 0 ..< scrollView.contentSize.width ~= targetX else {
            return false
        }

        // We use JavaScript instead of `UIScrollView.setContentOffset()` to
        // prevent glitches when turning pages without animation.
        // See https://github.com/readium/swift-toolkit/issues/737#issuecomment-4090386881
        //
        // `scrollBy` is used instead of `scrollTo` because RTL content uses
        // negative `window.scrollX` values in WKWebView, whereas UIKit's
        // `contentOffset.x` is always non-negative. A relative displacement
        // (`offsetX`) is coordinate-system agnostic and works for both LTR and
        // RTL.
        let behavior = options.animated ? "smooth" : "instant"
        await evaluateScript("window.scrollBy({ left: \(offsetX), behavior: '\(behavior)' });")

        if options.animated {
            // Waits for the scroll animation to finish.
            await withCheckedContinuation { continuation in
                let request = ScrollAnimationRequest(continuation)
                pendingScrollAnimation?.resume()
                pendingScrollAnimation = request

                // Safety net in case `scrollDidEnd` never fires. The identity
                // check on `request` ensures a stale timeout from a previous
                // request does not resume a newer one.
                Task { @MainActor in
                    try? await Task.sleep(seconds: 0.8)
                    scrollDidEnd(for: request)
                }
            }
        }

        return true
    }

    private struct PendingLocation {
        var location: PageLocation
        var animated: Bool
    }

    /// Location to scroll to in the resource once the page is loaded.
    private var pendingLocation: PendingLocation = .init(location: .start, animated: false)

    override func go(to location: PageLocation, animated: Bool) async {
        guard isSpreadLoaded else {
            // Delays moving to the location until the document is loaded.
            pendingLocation = PendingLocation(location: location, animated: animated)

            await waitGoToCompletion()
            return
        }

        switch location {
        case let .locator(locator):
            await go(to: locator, animated: animated)
        case .start:
            await scroll(toProgression: 0, animated: animated)
        case .end:
            await scroll(toProgression: 1, animated: animated)
        }

        didCompleteGoTo()
    }

    private func waitGoToCompletion() async {
        await withCheckedContinuation { continuation in
            goToContinuations.append(continuation)
        }
    }

    private func didCompleteGoTo() {
        for cont in goToContinuations {
            cont.resume()
        }
        goToContinuations.removeAll()
    }

    private var goToContinuations: [CheckedContinuation<Void, Never>] = []

    private var pendingScrollAnimation: ScrollAnimationRequest?

    /// Represents an in-flight animated page turn, waiting for the scroll
    /// animation to settle before completing.
    private class ScrollAnimationRequest {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        /// Resumes the continuation. Safe to call multiple times; only the
        /// first call has any effect.
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func scrollDidEnd(for request: ScrollAnimationRequest? = nil) {
        guard request == nil || pendingScrollAnimation === request else {
            return
        }
        pendingScrollAnimation?.resume()
        pendingScrollAnimation = nil
    }

    @discardableResult
    private func go(to locator: Locator, animated: Bool) async -> Bool {
        if !["", "#"].contains(locator.href.string) {
            guard
                let index = viewModel.readingOrder.firstIndexWithHREF(locator.href),
                spread.contains(index: index)
            else {
                log(.warning, "The locator's href is not in the spread")
                return false
            }
        }

        if locator.text.highlight != nil {
            return await scroll(toLocator: locator, animated: animated)
            // TODO: find the first fragment matching a tag ID (need a regex)
        } else if let id = locator.locations.fragments.first, !id.isEmpty {
            var ok = await scroll(toTagID: id, animated: animated)
            if !ok {
                // Fragment often resolves only after column layout settles.
                await waitForPaginatedLayoutSettled()
                ok = await scroll(toTagID: id, animated: animated)
            }
            return ok
        } else {
            let progression = locator.locations.progression ?? 0
            return await scroll(toProgression: progression, animated: animated)
        }
    }

    /// Scrolls at given progression (from 0.0 to 1.0)
    @discardableResult
    private func scroll(toProgression progression: Double, animated: Bool) async -> Bool {
        guard progression >= 0, progression <= 1 else {
            log(.warning, "Scrolling to invalid progression \(progression)")
            return false
        }

        // Note: The JS layer does not take into account the scroll view's content inset. So it can't be used to reliably scroll to the top or the bottom of the page in scroll mode.
        if viewModel.scroll, !viewModel.verticalText, [0, 1].contains(progression) {
            var contentOffset = scrollView.contentOffset
            contentOffset.y = (progression == 0)
                ? -scrollView.contentInset.top
                : (scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
            scrollView.contentOffset = contentOffset
            return true
        } else {
            let dir = viewModel.readingProgression.rawValue
            await evaluateScript("readium.scrollToPosition(\'\(progression)\', \'\(dir)\', \(animated))")
            // Paginated end: JS can no-op when columns are not ready — pin native offset.
            if progression >= 0.999, !viewModel.scroll {
                let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
                if maxX > 1 {
                    scrollView.contentOffset = CGPoint(x: maxX, y: scrollView.contentOffset.y)
                }
            }
            return true
        }
    }

    /// Scrolls at the tag with ID `tagID`.
    @discardableResult
    private func scroll(toTagID tagID: String, animated: Bool) async -> Bool {
        // Robust column-aware scroll — do not rely solely on stock readium.scrollToId
        // (viewportWidth===0 → NaN snap; pre-layout rect → chapter start).
        let escaped = tagID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let anim = animated ? "true" : "false"
        let script = """
        (function(){
          var id = '\(escaped)';
          var el = document.getElementById(id);
          if (!el) {
            try { el = document.querySelector('#' + CSS.escape(id)); } catch (e) {}
          }
          if (!el) return false;
          var pageW = window.innerWidth || document.documentElement.clientWidth || 1;
          function snap(offset){
            if (!isFinite(offset) || pageW < 1) return 0;
            var v = offset + 1;
            return v - (v % pageW);
          }
          var scrollMode = false;
          try {
            scrollMode = getComputedStyle(document.documentElement)
              .getPropertyValue('--USER__view').trim() === 'readium-scroll-on';
          } catch (e) {}
          if (scrollMode) {
            var r = el.getBoundingClientRect();
            document.scrollingElement.scrollTo({
              top: r.top + window.scrollY,
              behavior: \(anim) ? 'smooth' : 'instant'
            });
            return true;
          }
          // Wait briefly if columns have not expanded yet (long chapters).
          var sw = document.scrollingElement.scrollWidth || 0;
          if (sw < pageW * 1.2) {
            // still try; caller may retry after layout
          }
          var rects = el.getClientRects();
          var rect = (rects && rects.length) ? rects[0] : el.getBoundingClientRect();
          var left = snap(rect.left + window.scrollX);
          document.scrollingElement.scrollTo({
            left: left,
            behavior: \(anim) ? 'smooth' : 'instant'
          });
          // Verify: element should share the visible page band.
          var after = el.getBoundingClientRect();
          var ok = after.left < pageW * 0.95 && after.right > pageW * 0.05;
          if (!ok && rects && rects.length) {
            left = snap(rects[0].left + window.scrollX);
            document.scrollingElement.scrollTo({ left: left, behavior: 'instant' });
          }
          return true;
        })();
        """
        let result = await evaluateScript(script)
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    /// Scrolls at the snippet matching the given text context.
    @discardableResult
    private func scroll(toLocator locator: Locator, animated: Bool) async -> Bool {
        guard let json = try? locator.jsonString() else {
            return false
        }
        let result = await evaluateScript("readium.scrollToLocator(\(json), \(animated));")
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    // MARK: - Progression

    /// Current progression range in the page.
    private var progression: ClosedRange<Double>?
    /// To check if a progression change was cancelled or not.
    private var previousProgression: ClosedRange<Double>?

    /// Called by the javascript code to notify that scrolling ended.
    private func progressionDidChange(_ body: Any) {
        guard
            isSpreadLoaded,
            let body = body as? [String: Any],
            var firstProgression = body["first"] as? Double,
            var lastProgression = body["last"] as? Double
        else {
            return
        }
        precondition(firstProgression <= lastProgression)
        firstProgression = min(max(firstProgression, 0.0), 1.0)
        lastProgression = min(max(lastProgression, 0.0), 1.0)

        if previousProgression == nil {
            previousProgression = progression
        }
        progression = firstProgression ... lastProgression

        setNeedsNotifyPagesDidChange()
    }

    private func setNeedsNotifyPagesDidChange() {
        // Makes sure we always receive the "ending scroll" event.
        // ie. https://stackoverflow.com/a/1857162/1474476
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyPagesDidChange), object: nil)
        perform(#selector(notifyPagesDidChange), with: nil, afterDelay: 0.3)
    }

    @objc private func notifyPagesDidChange() {
        guard previousProgression != progression else {
            return
        }
        previousProgression = nil

        scrollDidEnd()
        delegate?.spreadViewPagesDidChange(self)
    }

    // MARK: - Scripts

    override func registerJSMessages() {
        super.registerJSMessages()
        registerJSMessage(named: "progressionChanged") { [weak self] in self?.progressionDidChange($0) }
    }

    // MARK: - WKNavigationDelegate

    override func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        super.webView(webView, didFinish: navigation)

        // Fixes https://github.com/readium/r2-navigator-swift/issues/141 by disabling the native
        // double-tap gesture.
        // It's an acceptable fix because reflowable resources are not supposed to handle double-tap
        // since there's no zooming capabilities. This doesn't prevent JavaScript to handle
        // double-tap manually.
        webView.removeDoubleTapGestureRecognizer()
    }

    // MARK: - UIScrollViewDelegate

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        setNeedsNotifyPagesDidChange()
    }

    /// Disable pinch-zoom: WKWebView zoom breaks reflowable column pagination.
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        nil
    }
}
