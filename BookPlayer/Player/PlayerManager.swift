//
//  PlayerManager.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 5/31/17.
//  Copyright © 2017 Tortuga Power. All rights reserved.
//

import AVFoundation
import BookPlayerKit
import Combine
import Foundation
import MediaPlayer
import WidgetKit

// swiftlint:disable file_length

final class PlayerManager: NSObject, TelemetryProtocol {
  private let dataManager: DataManager
  private let userActivityManager: UserActivityManager
  private let watchConnectivityService: WatchConnectivityService

  private var audioPlayer = AVPlayer()

  private var fadeTimer: Timer?

  private var playerItem: AVPlayerItem?

  private var speedSubscription: AnyCancellable?

  private var hasObserverRegistered = false
  private var observeStatus: Bool = false {
    didSet {
      guard oldValue != self.observeStatus else { return }

      if self.observeStatus {
        self.playerItem?.addObserver(self, forKeyPath: "status", options: .new, context: nil)
        self.hasObserverRegistered = true
      } else if self.hasObserverRegistered {
        self.playerItem?.removeObserver(self, forKeyPath: "status")
        self.hasObserverRegistered = false
      }
    }
  }

  @Published var currentBook: Book? {
    didSet {
      defer {
        self.hasChapters.value = currentBook?.hasChapters ?? false
      }

      guard let book = currentBook,
            let fileURL = book.fileURL else { return }

      let bookAsset = AVURLAsset(url: fileURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

      // Clean just in case
      if self.hasObserverRegistered {
        self.playerItem?.removeObserver(self, forKeyPath: "status")
        self.hasObserverRegistered = false
      }
      self.playerItem = AVPlayerItem(asset: bookAsset)
      self.playerItem?.audioTimePitchAlgorithm = .timeDomain
    }
  }

  public var hasChapters = CurrentValueSubject<Bool, Never>(false)

  private var nowPlayingInfo = [String: Any]()

  private let queue = OperationQueue()

  private(set) var hasLoadedBook = false

  private var rateObserver: NSKeyValueObservation?

  init(dataManager: DataManager, watchConnectivityService: WatchConnectivityService) {
    self.dataManager = dataManager
    self.watchConnectivityService = watchConnectivityService
    self.userActivityManager = UserActivityManager(dataManager: dataManager)

    super.init()
    let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

    self.rateObserver = self.audioPlayer.observe(\.rate, options: [.new]) { _, change in
      guard let newValue = change.newValue, newValue == 0 else { return }

      DispatchQueue.main.async {
        self.watchConnectivityService.sendMessage(message: ["notification": "bookPaused" as AnyObject])
      }
    }
    self.audioPlayer.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] _ in
      guard let self = self else {
        return
      }

      self.update()
    }

    // Only route audio for AirPlay
    self.audioPlayer.allowsExternalPlayback = false

    NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying(_:)), name: .AVPlayerItemDidPlayToEndTime, object: nil)
  }

  func preload(_ book: Book) {
    if self.currentBook != nil {
      self.stop()
    }

    self.currentBook = book
  }

  func load(_ book: Book, completion: @escaping (Bool) -> Void) {
    self.queue.addOperation {
      // try loading the player
      guard let item = self.playerItem,
            book.duration > 0 else {
              DispatchQueue.main.async {
                self.currentBook = nil

                completion(false)
              }

              return
            }

      self.audioPlayer.replaceCurrentItem(with: nil)
      self.audioPlayer.replaceCurrentItem(with: item)

      // Update UI on main thread
      DispatchQueue.main.async {
        // Set book metadata for lockscreen and control center
        self.nowPlayingInfo = [
          MPNowPlayingInfoPropertyDefaultPlaybackRate: SpeedManager.shared.getSpeed()
        ]

        self.setNowPlayingBookTitle()
        self.setNowPlayingBookTime()

        ArtworkService.retrieveImageFromCache(for: book.relativePath) { result in
          let image: UIImage

          switch result {
          case .success(let value):
            image = value.image
          case .failure(_):
            image = ArtworkService.generateDefaultArtwork(from: ThemeManager.shared.currentTheme.linkColor)!
          }

          self.nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size,
                                                                               requestHandler: { (_) -> UIImage in
            image
          })

          MPNowPlayingInfoCenter.default().nowPlayingInfo = self.nowPlayingInfo
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = self.nowPlayingInfo

        if book.currentTime > 0.0 {
          // if book is truly finished, start book again to avoid autoplaying next one
          // add 1 second as a finished threshold
          let time = (book.currentTime + 1) >= book.duration ? 0 : book.currentTime
          self.jumpTo(time, recordBookmark: false)
        }

        self.hasLoadedBook = true
        completion(true)
      }
    }
  }

    // Called every second by the timer
    @objc func update() {
        guard let book = self.currentBook,
              let fileURL = book.fileURL,
              let playerItem = self.playerItem,
              playerItem.status == .readyToPlay else {
            return
        }

        let currentTime = CMTimeGetSeconds(self.audioPlayer.currentTime())
        book.setCurrentTime(currentTime)

        book.percentCompleted = book.percentage

        self.dataManager.saveContext()
        self.userActivityManager.recordTime()

        self.setNowPlayingBookTime()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = self.nowPlayingInfo

        // stop timer if the book is finished
        if Int(currentTime) == Int(book.duration) {
            // Once book a book is finished, ask for a review
            UserDefaults.standard.set(true, forKey: "ask_review")
            self.markAsCompleted(true)
        }

        if let currentChapter = book.currentChapter,
            book.currentTime > currentChapter.end || book.currentTime < currentChapter.start {
            book.updateCurrentChapter()
            self.setNowPlayingBookTitle()
            NotificationCenter.default.post(name: .chapterChange, object: nil, userInfo: nil)
            self.dataManager.saveContext()
        }

        let userInfo = [
            "time": currentTime,
            "fileURL": fileURL
        ] as [String: Any]

        // Notify
        NotificationCenter.default.post(name: .bookPlaying, object: nil, userInfo: userInfo)
    }

  private func bindSpeedObserver() {
    self.speedSubscription?.cancel()
    self.speedSubscription = SpeedManager.shared.currentSpeed.sink { [weak self] speed in
      guard let self = self,
            self.isPlaying else { return }

      self.audioPlayer.rate = speed
    }
  }

    // MARK: - Player states

    var isPlaying: Bool {
        return self.audioPlayer.timeControlStatus == .playing
    }

  public var isPlayingPublisher: AnyPublisher<Bool, Never> {
    self.audioPlayer.publisher(for: \.timeControlStatus)
      .map({ timeControlStatus in
        return timeControlStatus == .playing
      })
      .eraseToAnyPublisher()
  }

    var boostVolume: Bool = false {
        didSet {
            self.audioPlayer.volume = self.boostVolume
                ? Constants.Volume.boosted.rawValue
                : Constants.Volume.normal.rawValue
        }
    }

    var currentTime: TimeInterval {
        get {
            return CMTimeGetSeconds(self.audioPlayer.currentTime())
        }

        set {
            self.audioPlayer.seek(to: CMTime(seconds: newValue, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
        }
    }

    static var rewindInterval: TimeInterval {
        get {
            if UserDefaults.standard.object(forKey: Constants.UserDefaults.rewindInterval.rawValue) == nil {
                return 30.0
            }

            return UserDefaults.standard.double(forKey: Constants.UserDefaults.rewindInterval.rawValue)
        }

        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.rewindInterval.rawValue)

            MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals = [newValue] as [NSNumber]
        }
    }

    static var forwardInterval: TimeInterval {
        get {
            if UserDefaults.standard.object(forKey: Constants.UserDefaults.forwardInterval.rawValue) == nil {
                return 30.0
            }

            return UserDefaults.standard.double(forKey: Constants.UserDefaults.forwardInterval.rawValue)
        }

        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaults.forwardInterval.rawValue)

            MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals = [newValue] as [NSNumber]
        }
    }

    func setNowPlayingBookTitle() {
        guard let currentBook = self.currentBook else {
            return
        }

        if currentBook.hasChapters, let currentChapter = currentBook.currentChapter {
            self.nowPlayingInfo[MPMediaItemPropertyTitle] = currentChapter.title
            self.nowPlayingInfo[MPMediaItemPropertyArtist] = currentBook.title
            self.nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = currentBook.author
        } else {
            self.nowPlayingInfo[MPMediaItemPropertyTitle] = currentBook.title
            self.nowPlayingInfo[MPMediaItemPropertyArtist] = currentBook.author
            self.nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = nil
        }
    }

    func setNowPlayingBookTime() {
        guard let currentBook = self.currentBook else {
            return
        }

        let prefersChapterContext = UserDefaults.standard.bool(forKey: Constants.UserDefaults.chapterContextEnabled.rawValue)
        let currentTimeInContext = currentBook.currentTimeInContext(prefersChapterContext)
        let maxTimeInContext = currentBook.maxTimeInContext(prefersChapterContext, false)

        self.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = SpeedManager.shared.getSpeed()
        self.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTimeInContext
        self.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = maxTimeInContext
        self.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackProgress] = currentTimeInContext / maxTimeInContext
    }
}

// MARK: - Seek Controls

extension PlayerManager {
  func jumpTo(_ time: Double, fromEnd: Bool = false, recordBookmark: Bool = true) {
    guard let currentBook = self.currentBook else { return }

    if recordBookmark {
      self.createOrUpdateBookmark(at: self.audioPlayer.currentTime().seconds, book: currentBook, type: .skip)
    }

    let newTime = min(max(fromEnd ? currentBook.duration - time : time, 0), currentBook.duration)

    self.audioPlayer.seek(to: CMTime(seconds: newTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))

    if !self.isPlaying, let currentBook = self.currentBook {
      UserDefaults.standard.set(Date(), forKey: "\(Constants.UserDefaults.lastPauseTime)_\(currentBook.identifier!)")
    }

    self.update()
  }

  func jumpBy(_ direction: Double) {
    guard let book = self.currentBook else { return }

    self.createOrUpdateBookmark(at: self.audioPlayer.currentTime().seconds, book: book, type: .skip)

    let newTime = book.getInterval(from: direction) + CMTimeGetSeconds(self.audioPlayer.currentTime())
    self.audioPlayer.seek(to: CMTime(seconds: newTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))

    self.update()
  }

    func forward() {
        self.jumpBy(PlayerManager.forwardInterval)
        self.sendSignal(.forwardAction, with: ["interval": "\(PlayerManager.forwardInterval)"])
    }

    func rewind() {
        self.jumpBy(-PlayerManager.rewindInterval)
        self.sendSignal(.rewindAction, with: ["interval": "\(PlayerManager.rewindInterval)"])
    }
}

// MARK: - Playback

extension PlayerManager {
    func play(_ autoplayed: Bool = false) {
        guard let currentBook = self.currentBook, let item = self.playerItem else { return }

        guard item.status == .readyToPlay else {
            // queue playback
            self.observeStatus = true
            return
        }

        self.userActivityManager.resumePlaybackActivity()

        if let library = currentBook.getLibrary() {
            library.lastPlayedBook = currentBook
          self.dataManager.saveContext()
        }

        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            fatalError("Failed to activate the audio session")
        }

        self.createOrUpdateBookmark(at: self.audioPlayer.currentTime().seconds, book: currentBook, type: .play)

        let completed = Int(currentBook.duration) == Int(CMTimeGetSeconds(self.audioPlayer.currentTime()))

        if autoplayed, completed { return }

        // If book is completed, reset to start
        if completed {
            self.audioPlayer.seek(to: CMTime(seconds: 0, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
        }

        // Handle smart rewind.
        let lastPauseTimeKey = "\(Constants.UserDefaults.lastPauseTime)_\(currentBook.identifier!)"
        let smartRewindEnabled = UserDefaults.standard.bool(forKey: Constants.UserDefaults.smartRewindEnabled.rawValue)

        if smartRewindEnabled, let lastPlayTime: Date = UserDefaults.standard.object(forKey: lastPauseTimeKey) as? Date {
            let timePassed = Date().timeIntervalSince(lastPlayTime)
            let timePassedLimited = min(max(timePassed, 0), Constants.SmartRewind.threshold.rawValue)

            let delta = timePassedLimited / Constants.SmartRewind.threshold.rawValue

            // Using a cubic curve to soften the rewind effect for lower values and strengthen it for higher
            let rewindTime = pow(delta, 3) * Constants.SmartRewind.maxTime.rawValue

            let newPlayerTime = max(CMTimeGetSeconds(self.audioPlayer.currentTime()) - rewindTime, 0)

            UserDefaults.standard.set(nil, forKey: lastPauseTimeKey)

            self.audioPlayer.seek(to: CMTime(seconds: newPlayerTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
        }

        self.fadeTimer?.invalidate()
        self.boostVolume = UserDefaults.standard.bool(forKey: Constants.UserDefaults.boostVolumeEnabled.rawValue)
        // Set play state on player and control center
        self.audioPlayer.playImmediately(atRate: SpeedManager.shared.getSpeed())
        self.bindSpeedObserver()

        // Set last Play date
        currentBook.updatePlayDate()

        self.setNowPlayingBookTitle()

        DispatchQueue.main.async {
            CarPlayManager.setNowPlayingInfo(with: currentBook)
            NotificationCenter.default.post(name: .bookPlayed, object: nil)
            self.watchConnectivityService.sendMessage(message: ["notification": "bookPlayed" as AnyObject])
            if #available(iOS 14.0, *) {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }

        self.update()
    }

    // swiftlint:disable block_based_kvo
    // Using this instead of new form, because the new one wouldn't work properly on AVPlayerItem
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let path = keyPath, path == "status",
            let item = object as? AVPlayerItem,
            item.status == .readyToPlay else {
            super.observeValue(forKeyPath: keyPath,
                               of: object,
                               change: change,
                               context: context)
            return
        }

        self.observeStatus = false

        self.play()
    }

    func pause(fade: Bool = false) {
        guard let currentBook = self.currentBook else {
            return
        }

        self.observeStatus = false

        self.userActivityManager.stopPlaybackActivity()

        if let library = currentBook.getLibrary() {
            library.lastPlayedBook = currentBook
          self.dataManager.saveContext()
        }

        self.update()

        let pauseActionBlock: () -> Void = {
            // Set pause state on player and control center
            self.audioPlayer.pause()
            self.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
            self.setNowPlayingBookTime()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = self.nowPlayingInfo

            UserDefaults.standard.set(Date(), forKey: "\(Constants.UserDefaults.lastPauseTime)_\(currentBook.identifier!)")

            try? AVAudioSession.sharedInstance().setActive(false)
        }

        guard fade else {
            pauseActionBlock()
            return
        }

        self.fadeTimer = self.audioPlayer.fadeVolume(from: 1, to: 0, duration: 5, completion: pauseActionBlock)
    }

    // Toggle play/pause of book
    func playPause(autoplayed _: Bool = false) {
        // Pause player if it's playing
        if self.audioPlayer.timeControlStatus == .playing {
            self.pause()
        } else {
            self.play()
        }
    }

  func stop() {
    self.observeStatus = false

    self.audioPlayer.pause()

    self.userActivityManager.stopPlaybackActivity()

    if let book = self.currentBook {
      if let library = book.library ?? book.folder?.library {
        library.lastPlayedBook = nil
        self.dataManager.saveContext()
      }
    }

    self.currentBook = nil
    self.hasLoadedBook = false
  }

    func markAsCompleted(_ flag: Bool) {
        guard let book = self.currentBook,
            let fileURL = book.fileURL,
            let bookIdentifier = book.identifier else { return }

        book.markAsFinished(flag)
      self.dataManager.saveContext()

        NotificationCenter.default.post(name: .bookEnd,
                                        object: nil,
                                        userInfo: [
                                            "fileURL": fileURL,
                                            "bookIdentifier": bookIdentifier
                                        ])
    }

    @objc
    func playerDidFinishPlaying(_ notification: Notification) {
        if let book = self.currentBook,
            let library = book.library ?? book.folder?.library {
            library.lastPlayedBook = nil
          self.dataManager.saveContext()
        }

        self.update()

        self.markAsCompleted(true)

        guard let nextBook = self.currentBook?.nextBook() else { return }

        self.load(nextBook, completion: { success in
            guard success else { return }

            let userInfo = ["book": nextBook]

            NotificationCenter.default.post(name: .bookChange,
                                            object: nil,
                                            userInfo: userInfo)
        })
    }
}

// MARK: - BookMarks
extension PlayerManager {
  public func createOrUpdateBookmark(at time: Double, book: Book, type: BookmarkType) {
    let bookmark = self.dataManager.getBookmark(of: type, for: book)
    ?? self.dataManager.createBookmark(at: time, book: book, type: type)
    bookmark.time = floor(time)
    bookmark.note = type.getNote()
    self.dataManager.saveContext()
  }
}
