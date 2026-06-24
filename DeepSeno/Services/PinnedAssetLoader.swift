import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Plays media (video/audio) from the public HTTPS relay through the *same*
/// cert-pinned transport the rest of the app uses.
///
/// Why this exists: `AVPlayer`/`AVURLAsset` has its own network stack that does
/// NOT go through `APIClient`'s pinned `URLSession`. On a public relay the media
/// URL is `https://<vps-ip>:<port>/...`, served by a self-signed cert. AVPlayer's
/// default TLS evaluation rejects that cert (hostname mismatch + untrusted
/// chain), so the video silently fails to load. There is no public API to hand
/// AVPlayer a custom `URLSession`.
///
/// The standard workaround: rewrite the `https://` scheme to a private scheme
/// (`kzpin://`) when building the `AVURLAsset`. AVPlayer doesn't know how to load
/// an unknown scheme, so it forwards every load request to our
/// `AVAssetResourceLoaderDelegate`. We restore the real `https://` URL and
/// satisfy the request with a `PinningDelegate`-backed `URLSession` — the exact
/// SPKI-pinned path that already works for images and SSE.
///
/// LAN connections are plain `http://` and trusted by ATS local-networking, so
/// they keep using `AVPlayer(url:)` directly — no resource loader needed.
enum PinnedAsset {
    /// Private scheme AVPlayer hands to our resource loader.
    static let scheme = "kzpin"

    /// Builds an `AVPlayerItem`.
    /// - On a secure (public relay) connection: routes byte-range loads through a
    ///   cert-pinned `URLSession`. The pinning delegate is retained for the life
    ///   of the returned item (see `PinnedAssetResourceLoader.attach`).
    /// - On LAN (`secure == false`): returns a plain item backed by the real URL.
    ///
    /// `fileName`: the recording's original file name (e.g. `clip.MOV`). The
    /// content UTI is derived from its extension when available, because the relay
    /// mislabels QuickTime `.MOV` files as `Content-Type: video/mp4`. Telling
    /// AVPlayer the wrong UTI (`public.mpeg-4` for an actual QuickTime stream) is
    /// tolerated by the Simulator's lenient demuxer but rejected by a real
    /// device's stricter one — the "video won't play" symptom on hardware.
    static func makePlayerItem(
        mediaURL: URL,
        secure: Bool,
        fingerprint: String?,
        fileName: String? = nil
    ) -> AVPlayerItem {
        // UTI derived from the real file extension (authoritative; beats a wrong
        // server Content-Type). nil → fall back to the HTTP MIME mapping.
        let extUTI: String? = fileName.flatMap { name in
            let ext = (name as NSString).pathExtension
            return ext.isEmpty ? nil : UTType(filenameExtension: ext)?.identifier
        }

        guard secure, let fingerprint else {
            return AVPlayerItem(url: mediaURL)
        }
        // Swap https -> kzpin so AVPlayer defers loading to our delegate.
        guard var comps = URLComponents(url: mediaURL, resolvingAgainstBaseURL: false) else {
            return AVPlayerItem(url: mediaURL)
        }
        comps.scheme = scheme
        guard let pinnedURL = comps.url else {
            return AVPlayerItem(url: mediaURL)
        }

        let asset = AVURLAsset(url: pinnedURL)
        let loader = PinnedAssetResourceLoader(
            realURL: mediaURL, fingerprint: fingerprint, contentTypeOverride: extUTI
        )
        // resourceLoader holds its delegate *weakly*; without a strong ref the
        // delegate deallocates immediately and AVPlayer hangs on "loading".
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let item = AVPlayerItem(asset: asset)
        PinnedAssetResourceLoader.attach(loader, to: item)
        return item
    }
}

/// `AVAssetResourceLoaderDelegate` that satisfies AVPlayer's byte-range requests
/// over a cert-pinned `URLSession`. Each loading request maps to one HTTP `Range`
/// GET; the response headers feed `contentInformationRequest` and the body feeds
/// `dataRequest`.
///
/// `@unchecked Sendable`: the only mutable state (`tasks`) is mutated solely on
/// `queue`, and `realURL`/`session`/`pinningDelegate` are immutable after init.
/// AVFoundation drives the delegate callbacks on `queue`, and the URLSession
/// completion handlers hop back onto `queue` before touching anything.
final class PinnedAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// The real https URL (with the original scheme + token query param) to fetch.
    private let realURL: URL
    private let session: URLSession
    /// Strong ref to the pinning delegate — URLSession only holds it weakly.
    private let pinningDelegate: PinningDelegate
    /// Authoritative content UTI derived from the real file extension, used in
    /// preference to the (sometimes wrong) HTTP `Content-Type`. nil → use MIME.
    private let contentTypeOverride: String?
    /// Serial queue the resource loader callbacks run on; also used as the
    /// session delegate queue so trust challenges are serialized with loads.
    let queue = DispatchQueue(label: "com.enmooy.deepseno.pinned-asset-loader")

    /// Maps an in-flight `AVAssetResourceLoadingRequest` to its `URLSessionDataTask`
    /// so a cancellation can abort the network fetch.
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(realURL: URL, fingerprint: String, contentTypeOverride: String? = nil) {
        self.realURL = realURL
        self.contentTypeOverride = contentTypeOverride
        let delegate = PinningDelegate(fingerprint: fingerprint)
        self.pinningDelegate = delegate
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        super.init()
    }

    // MARK: - Delegate lifetime

    /// Stable, unique address used as the associated-object key. A `static let`
    /// reference type gives a fixed pointer for the process lifetime without the
    /// Swift 6 "mutable global state" error a `static var UInt8` would raise.
    private final class AssociationKey: Sendable {}
    private static let attachKey = AssociationKey()

    /// Pin the loader's lifetime to the `AVPlayerItem` via an associated object.
    /// `AVAssetResourceLoader.delegate` is weak, and callers typically only retain
    /// the `AVPlayer`/`AVPlayerItem`. Without this, the loader is released right
    /// after `makePlayerItem` returns and playback silently stalls.
    static func attach(_ loader: PinnedAssetResourceLoader, to item: AVPlayerItem) {
        objc_setAssociatedObject(
            item,
            Unmanaged.passUnretained(attachKey).toOpaque(),
            loader,
            .OBJC_ASSOCIATION_RETAIN
        )
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let hasContentInfo = loadingRequest.contentInformationRequest != nil

        var req = URLRequest(url: realURL)
        req.timeoutInterval = 60

        // Translate the requested byte range into an HTTP Range header. AVPlayer
        // first probes with a small range to read content info, then streams the
        // rest in chunks. If requestsAllDataToEndOfResource is set we leave the
        // upper bound open ("bytes=offset-").
        if let dataRequest = loadingRequest.dataRequest {
            let offset = dataRequest.requestedOffset
            let length = dataRequest.requestedLength
            if dataRequest.requestsAllDataToEndOfResource || length <= 0 {
                req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            } else {
                let end = offset + Int64(length) - 1
                req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            }
        } else if hasContentInfo {
            // contentInfo-only request (no dataRequest). AVPlayer just wants the
            // headers (MIME, total length, byte-range support). Issue a tiny Range
            // GET so the server replies 206 with a Content-Range total — that's
            // what lets us fill isByteRangeAccessSupported + contentLength.
            req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }

        let key = ObjectIdentifier(loadingRequest)
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                self.tasks.removeValue(forKey: key)
                if loadingRequest.isCancelled { return }

                if let error {
                    loadingRequest.finishLoading(with: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    loadingRequest.finishLoading(with: URLError(.badServerResponse))
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    loadingRequest.finishLoading(
                        with: NSError(domain: "PinnedAssetLoader", code: http.statusCode)
                    )
                    return
                }

                self.fill(contentInformation: loadingRequest.contentInformationRequest, from: http)

                if let dataRequest = loadingRequest.dataRequest, let data {
                    dataRequest.respond(with: data)
                }
                loadingRequest.finishLoading()
            }
        }

        tasks[key] = task
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        queue.async {
            self.tasks.removeValue(forKey: key)?.cancel()
        }
    }

    // MARK: - Content information

    /// Populate the content-information request from response headers so AVPlayer
    /// knows the MIME type, total length, and that byte-range access is supported.
    private func fill(
        contentInformation info: AVAssetResourceLoadingContentInformationRequest?,
        from http: HTTPURLResponse
    ) {
        guard let info else { return }

        // Content type → UTI. AVFoundation wants a UTI string, not a MIME type.
        // Prefer the UTI derived from the real file extension: the relay mislabels
        // QuickTime `.MOV` as `video/mp4`, and a real device's demuxer rejects a
        // QuickTime stream announced as `public.mpeg-4`. Fall back to the MIME map.
        if let override = contentTypeOverride {
            info.contentType = override
        } else if let mime = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
           let uti = UTType(mimeType: mime) {
            info.contentType = uti.identifier
        }

        // Total resource length. Prefer Content-Range's total ("bytes a-b/total"),
        // since on a 206 the Content-Length is only the size of this chunk.
        var totalLength: Int64?
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/") {
            let totalPart = contentRange[contentRange.index(after: slash)...]
            if totalPart != "*" { totalLength = Int64(totalPart) }
        }
        if totalLength == nil, http.statusCode == 200, http.expectedContentLength > 0 {
            totalLength = http.expectedContentLength
        }
        if let totalLength { info.contentLength = totalLength }

        // A 206 (or an Accept-Ranges: bytes on a 200) means the server honors Range.
        let acceptsRanges = http.statusCode == 206
            || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        info.isByteRangeAccessSupported = acceptsRanges
    }
}
