//
//  ChromeCastPlaybackProvider.swift
//  WWDC
//
//  Created by Guilherme Rambo on 03/06/17.
//  Copyright © 2017 Guilherme Rambo. All rights reserved.
//

/*
 ChromeCast support was disabled as part of the Apple Silicon transition,
 since we're moving to SPM instead of Carthage. ChromeCastCore includes
 Objective-C code which would need to be rewritten in Swift in order
 to work properly under SPM. Additionally, I'm not sure how much people
 actually use this feature and have no way to test it in practice,
 so I've decided to just disable it for the time being.
 */
#if ENABLE_CHROMECAST

import Cocoa
import ChromeCastCore
import PlayerUI
import CoreMedia
import OSLog

private struct ChromeCastConstants {
    static let defaultHost = "devstreaming-cdn.apple.com"
    static let chromeCastSupportedHost = "devstreaming.apple.com"
    static let placeholderImageURL = URL(string: "https://wwdc.io/images/placeholder.jpg")!
}

private extension URL {

    /// The default host returned by Apple's WWDC app has invalid headers for ChromeCast streaming,
    /// this rewrites the URL to use another host which returns a valid response for the ChromeCast device
    /// Calling this on a non-streaming URL doesn't change the URL
    var chromeCastSupportedURL: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }

        if components.host == ChromeCastConstants.defaultHost {
            components.scheme = "http"
            components.host = ChromeCastConstants.chromeCastSupportedHost
        }

        return components.url
    }

}

final class ChromeCastPlaybackProvider: PUIExternalPlaybackProvider, Logging {

    fileprivate weak var consumer: PUIExternalPlaybackConsumer?

    private lazy var scanner: CastDeviceScanner = CastDeviceScanner()

    static let log = makeLogger()

    /// Initializes the external playback provider to start playing the media at the specified URL
    ///
    /// - Parameter consumer: The consumer that's going to be using this provider
    init(consumer: PUIExternalPlaybackConsumer) {
        self.consumer = consumer
        status = PUIExternalPlaybackMediaStatus()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(deviceListDidChange),
                                               name: CastDeviceScanner.DeviceListDidChange,
                                               object: scanner)

        scanner.startScanning()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Whether this provider only works with a remote URL or can be used with only the `AVPlayer` instance
    var requiresRemoteMediaUrl: Bool {
        return true
    }

    /// The name of the external playback system (ex: "AirPlay")
    static var name: String {
        return "ChromeCast"
    }

    /// An image to be used as the icon in the UI
    var icon: NSImage {
        return #imageLiteral(resourceName: "chromecast")
    }

    var image: NSImage {
        return #imageLiteral(resourceName: "chromecast-large")
    }

    var info: String {
        return "To control playback, use the Google Home app on your phone"
    }

    /// The current media status
    var status: PUIExternalPlaybackMediaStatus

    /// Return whether this playback system is available
    var isAvailable: Bool = false

    /// Tells the external playback provider to play
    func play() {

    }

    /// Tells the external playback provider to pause
    func pause() {

    }

    /// Tells the external playback provider to seek to the specified time (in seconds)
    func seek(to timestamp: Double) {

    }

    /// Tells the external playback provider to change the volume on the device
    ///
    /// - Parameter volume: The volume (value between 0 and 1)
    func setVolume(_ volume: Float) {

    }

    // MARK: - ChromeCast management

    fileprivate var client: CastClient?
    fileprivate var mediaPlayerApp: CastApp?
    fileprivate var currentSessionId: Int?
    fileprivate var mediaStatusRefreshTimer: Timer?

    @objc private func deviceListDidChange() {
        isAvailable = scanner.devices.count > 0

        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        scanner.devices.forEach { device in
            let item = NSMenuItem(title: device.name, action: #selector(didSelectDeviceOnMenu), keyEquivalent: "")
            item.representedObject = device
            item.target = self

            if device.hostName == selectedDevice?.hostName {
                item.state = .on
            }

            menu.addItem(item)
        }

        // send menu to consumer
        consumer?.externalPlaybackProvider(self, deviceSelectionMenuDidChangeWith: menu)
    }

    private var selectedDevice: CastDevice?

    @objc private func didSelectDeviceOnMenu(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? CastDevice else { return }

        scanner.stopScanning()

        if let previousClient = client {
            if let app = mediaPlayerApp {
                client?.stop(app: app)
            }

            mediaStatusRefreshTimer?.invalidate()
            mediaStatusRefreshTimer = nil

            previousClient.disconnect()
            client = nil
        }

        if device.hostName == selectedDevice?.hostName {
            sender.state = .off

            consumer?.externalPlaybackProviderDidInvalidatePlaybackSession(self)
        } else {
            selectedDevice = device
            sender.state = .on

            client = CastClient(device: device)
            client?.delegate = self

            client?.connect()

            consumer?.externalPlaybackProviderDidBecomeCurrent(self)
        }
    }

    fileprivate var mediaForChromeCast: CastMedia? {
        guard let originalMediaURL = consumer?.remoteMediaUrl else {
            log.error("Unable to play because the player view doesn't have a remote media URL associated with it")
            return nil
        }

        guard let mediaURL = originalMediaURL.chromeCastSupportedURL else {
            log.error("Error generating ChromeCast-compatible media URL")
            return nil
        }

        log.info("ChromeCast media URL is \(mediaURL.absoluteString, privacy: .public)")

        let posterURL: URL

        if let poster = consumer?.mediaPosterUrl {
            posterURL = poster
        } else {
            posterURL = ChromeCastConstants.placeholderImageURL
        }

        let title: String

        if let playerTitle = consumer?.mediaTitle {
            title = playerTitle
        } else {
            title = "WWDC Video"
        }

        let streamType: CastMediaStreamType

        if let isLive = consumer?.mediaIsLiveStream {
            streamType = isLive ? .live : .buffered
        } else {
            streamType = .buffered
        }

        var currentTime: Double = 0

        if let playerTime = consumer?.player?.currentTime() {
            currentTime = Double(CMTimeGetSeconds(playerTime))
        }

        let media = CastMedia(title: title,
                              url: mediaURL,
                              poster: posterURL,
                              contentType: "application/vnd.apple.mpegurl",
                              streamType: streamType,
                              autoplay: true,
                              currentTime: currentTime)

        return media
    }

    fileprivate func loadMediaOnDevice() {
        guard let media = mediaForChromeCast else { return }
        guard let app = mediaPlayerApp else { return }
        guard let url = consumer?.remoteMediaUrl else { return }

        log.debug("Load media at \(url.absoluteString, privacy: .public) on session ID \(app.sessionId, privacy: .public)")

        var currentTime: Double = 0

        if let playerTime = consumer?.player?.currentTime() {
            currentTime = Double(CMTimeGetSeconds(playerTime))
        }

        log.info("Will start media on ChromeCast at \(currentTime, privacy: .public)s")

        client?.load(media: media, with: app) { [weak self] error, mediaStatus in
            guard let self = self else { return }

            guard let mediaStatus = mediaStatus, error == nil else {
                if let error = error {
                    log.error("Failed to load media on ChromeCast: \(String(describing: error), privacy: .public)")
                    WWDCAlert.show(with: error)
                }
                return
            }

            self.currentSessionId = mediaStatus.mediaSessionId

            log.info("The media is now loaded with session ID \(mediaStatus.mediaSessionId, privacy: .public)")
            log.info("Current media status is \(String(describing: mediaStatus), privacy: .public)")

            self.startFetchingMediaStatusPeriodically()
        }
    }

    fileprivate func startFetchingMediaStatusPeriodically() {
        mediaStatusRefreshTimer = Timer.scheduledTimer(timeInterval: 5.0, target: self, selector: #selector(requestMediaStatus), userInfo: nil, repeats: true)
    }

    @objc private func requestMediaStatus(_ sender: Any?) {
        do {
            try client?.requestStatus()
        } catch {
            log.error("Failed to obtain status from connected ChromeCast device: \(String(describing: error), privacy: .public)")
        }
    }

}

extension ChromeCastPlaybackProvider: CastClientDelegate {

    public func castClient(_ client: CastClient, willConnectTo device: CastDevice) {
        log.debug("Will connect to device \(device.name, privacy: .public)")
    }

    public func castClient(_ client: CastClient, didConnectTo device: CastDevice) {
        log.debug("Connected to device \(device.name, privacy: .public). Launching media player app.")

        client.launch(appId: .defaultMediaPlayer) { [weak self] error, app in
            guard let self = self else { return }

            guard let app = app, error == nil else {
                if let error = error {
                    log.error("Failed to launch media player app: \(String(describing: error), privacy: .public)")
                    WWDCAlert.show(with: error)
                }
                return
            }

            log.info("Media player launched. Session id is \(app.sessionId, privacy: .public)")

            self.mediaPlayerApp = app
            self.loadMediaOnDevice()
        }
    }

    public func castClient(_ client: CastClient, didDisconnectFrom device: CastDevice) {
        consumer?.externalPlaybackProviderDidInvalidatePlaybackSession(self)
    }

    public func castClient(_ client: CastClient, connectionTo device: CastDevice, didFailWith error: NSError) {
        WWDCAlert.show(with: error)

        consumer?.externalPlaybackProviderDidInvalidatePlaybackSession(self)
    }

    public func castClient(_ client: CastClient, deviceStatusDidChange status: CastStatus) {
        self.status.volume = Float(status.volume.level)

        consumer?.externalPlaybackProviderDidChangeMediaStatus(self)
    }

    public func castClient(_ client: CastClient, mediaStatusDidChange status: CastMediaStatus) {
        let rate: Float = status.playerState == .playing ? 1.0 : 0.0

        let newStatus = PUIExternalPlaybackMediaStatus(rate: rate,
                                                       volume: self.status.volume,
                                                       currentTime: status.currentTime)

        self.status = newStatus

        log.debug("Media status: \(String(describing: newStatus), privacy: .public)")

        consumer?.externalPlaybackProviderDidChangeMediaStatus(self)
    }

}

#endif
