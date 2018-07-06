//
//  RNTrackPlayer.swift
//  RNTrackPlayer
//
//  Created by David Chavez on 13.08.17.
//  Copyright © 2017 David Chavez. All rights reserved.
//

import Foundation
import MediaPlayer
import AVFoundation

@objc(RNTrackPlayer)
class RNTrackPlayer: RCTEventEmitter, MediaWrapperDelegate {
    private lazy var mediaWrapper: MediaWrapper = {
        let wrapper = MediaWrapper()
        wrapper.delegate = self
        
        return wrapper
    }()
    
    // MARK: - MediaWrapperDelegate Methods
    
    func playerUpdatedState() {
        guard !isTesting else { return }
        sendEvent(withName: "playback-state", body: ["state": mediaWrapper.mappedState.rawValue])
    }
    
    func playerSwitchedTracks(trackId: String?, time: TimeInterval?, nextTrackId: String?) {
        guard !isTesting else { return }
        sendEvent(withName: "playback-track-changed", body: [
            "track": trackId,
            "position": time,
            "nextTrack": nextTrackId
        ])
    }
    
    func playerExhaustedQueue(trackId: String?, time: TimeInterval?) {
        guard !isTesting else { return }
        sendEvent(withName: "playback-queue-ended", body: [
            "track": trackId,
            "position": time,
        ])
    }
    
    func playbackFailed(error: Error) {
        guard !isTesting else { return }
        sendEvent(withName: "playback-error", body: ["error": error.localizedDescription])
    }
    
    private let isTesting = { () -> Bool in
        if let _ = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] {
            return true
        } else if let testingEnv = ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] {
            return testingEnv.contains("libXCTTargetBootstrapInject.dylib")
        } else {
            return false
        }
    }()
    
    
    // MARK: - Required Methods
    
    override open static func requiresMainQueueSetup() -> Bool {
        return true;
    }
    
    @objc(constantsToExport)
    override func constantsToExport() -> [AnyHashable: Any] {
        return [
            "STATE_NONE": MediaWrapper.PlaybackState.none.rawValue,
            "STATE_PLAYING": MediaWrapper.PlaybackState.playing.rawValue,
            "STATE_PAUSED": MediaWrapper.PlaybackState.paused.rawValue,
            "STATE_STOPPED": MediaWrapper.PlaybackState.stopped.rawValue,
            "STATE_BUFFERING": MediaWrapper.PlaybackState.buffering.rawValue,
            
            "PITCH_ALGORITHM_LINEAR": PitchAlgorithm.linear.rawValue,
            "PITCH_ALGORITHM_MUSIC": PitchAlgorithm.music.rawValue,
            "PITCH_ALGORITHM_VOICE": PitchAlgorithm.voice.rawValue,

            "CAPABILITY_PLAY": Capability.play.rawValue,
            "CAPABILITY_PAUSE": Capability.pause.rawValue,
            "CAPABILITY_STOP": Capability.stop.rawValue,
            "CAPABILITY_SKIP_TO_NEXT": Capability.next.rawValue,
            "CAPABILITY_SKIP_TO_PREVIOUS": Capability.previous.rawValue,
            "CAPABILITY_JUMP_FORWARD": Capability.jumpForward.rawValue,
            "CAPABILITY_JUMP_BACKWARD": Capability.jumpBackward.rawValue
        ]
    }
    
    @objc(supportedEvents)
    override func supportedEvents() -> [String] {
        return [
            "playback-queue-ended",
            "playback-state",
            "playback-error",
            "playback-track-changed",
            
            "remote-stop",
            "remote-pause",
            "remote-play",
            "remote-next",
            "remote-previous",
            "remote-jump-forward",
            "remote-jump-backward",
        ]
    }
    
    
    // MARK: - Bridged Methods
    
    @objc(setupPlayer:resolver:rejecter:)
    func setupPlayer(config: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        do {
            try AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            reject("setup_audio_session_failed", "Failed to setup audio session", error)
        }
        
        resolve(NSNull())
    }
    
    @objc(destroy)
    func destroy() {
        print("Destroying player")
    }
    
    @objc(updateOptions:)
    func update(options: [String: Any]) {
        let remoteCenter = MPRemoteCommandCenter.shared()
        let castedCapabilities = (options["capabilities"] as? [String])
        let capabilities = castedCapabilities?.flatMap { Capability(rawValue: $0) } ?? []
        
        let enableStop = capabilities.contains(.stop)
        let enablePause = true // capabilities.contains(.pause)
        let enablePlay = true // capabilities.contains(.play)
        let enablePlayNext = true // capabilities.contains(.next)
        let enablePlayPrevious = true // capabilities.contains(.previous)
        let enableSkipForward = capabilities.contains(.jumpForward)
        let enableSkipBackward = capabilities.contains(.jumpBackward)
        
        toggleRemoteHandler(command: remoteCenter.stopCommand, selector: #selector(remoteSentStop), enabled: enableStop)
        toggleRemoteHandler(command: remoteCenter.pauseCommand, selector: #selector(remoteSentPause), enabled: enablePause)
        toggleRemoteHandler(command: remoteCenter.playCommand, selector: #selector(remoteSentPlay), enabled: enablePlay)
        toggleRemoteHandler(command: remoteCenter.togglePlayPauseCommand, selector: #selector(remoteSentPlayPause), enabled: enablePause && enablePlay)
        toggleRemoteHandler(command: remoteCenter.nextTrackCommand, selector: #selector(remoteSentNext), enabled: enablePlayNext)
        toggleRemoteHandler(command: remoteCenter.previousTrackCommand, selector: #selector(remoteSentPrevious), enabled: enablePlayPrevious)
        
        
        remoteCenter.skipForwardCommand.preferredIntervals = [options["jumpInterval"] as? NSNumber ?? 15]
        remoteCenter.skipBackwardCommand.preferredIntervals = [options["jumpInterval"] as? NSNumber ?? 15]
        toggleRemoteHandler(command: remoteCenter.skipForwardCommand, selector: #selector(remoteSendSkipForward), enabled: enableSkipForward)
        toggleRemoteHandler(command: remoteCenter.skipBackwardCommand, selector: #selector(remoteSendSkipBackward), enabled: enableSkipBackward)
    }
    
    @objc(add:before:resolver:rejecter:)
    func add(trackDicts: [[String: Any]], before trackId: String?, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if let trackId = trackId, !mediaWrapper.queueContainsTrack(trackId: trackId) {
            reject("track_not_in_queue", "Given track ID was not found in queue", nil)
            return
        }
        
        var tracks = [Track]()
        for trackDict in trackDicts {
            guard let track = Track(dictionary: trackDict) else {
                reject("invalid_track_object", "Track is missing a required key", nil)
                return
            }
            
            tracks.append(track)
        }
        
        print("Adding tracks:", tracks)
        mediaWrapper.addTracks(tracks, before: trackId)
        resolve(NSNull())
    }
    
    @objc(remove:resolver:rejecter:)
    func remove(tracks ids: [String], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        print("Removing tracks:", ids)
        mediaWrapper.removeTracks(ids: ids)
        
        resolve(NSNull())
    }
    
    @objc(removeUpcomingTracks)
    func removeUpcomingTracks() {
        print("Removing upcoming tracks")
        mediaWrapper.removeUpcomingTracks()
    }
    
    @objc(skip:resolver:rejecter:)
    func skip(to trackId: String, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if !mediaWrapper.queueContainsTrack(trackId: trackId) {
            reject("track_not_in_queue", "Given track ID was not found in queue", nil)
            return
        }
        
        print("Skipping to track:", trackId)
        mediaWrapper.skipToTrack(id: trackId)
        resolve(NSNull())
    }
    
    @objc(skipToNext:rejecter:)
    func skipToNext(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        print("Skipping to next track")
        if (mediaWrapper.playNext()) {
            resolve(NSNull())
        } else {
            reject("queue_exhausted", "There is no tracks left to play", nil)
        }
    }
    
    @objc(skipToPrevious:rejecter:)
    func skipToPrevious(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        print("Skipping to next track")
        if (mediaWrapper.playPrevious()) {
            resolve(NSNull())
        } else {
            reject("no_previous_track", "There is no previous track", nil)
        }
    }
    
    @objc(reset)
    func reset() {
        print("Resetting player.")
        mediaWrapper.reset()
    }
    
    @objc(play)
    func play() {
        print("Starting/Resuming playback")
        mediaWrapper.play()
    }
    
    @objc(pause)
    func pause() {
        print("Pausing playback")
        mediaWrapper.pause()
    }
    
    @objc(stop)
    func stop() {
        print("Stopping playback")
        mediaWrapper.stop()
    }
    
    @objc(seekTo:)
    func seek(to time: Double) {
        print("Seeking to \(time) seconds")
        mediaWrapper.seek(to: time)
    }
    
    @objc(setVolume:)
    func setVolume(level: Float) {
        print("Setting volume to \(level)")
        mediaWrapper.volume = level
    }
    
    @objc(getVolume:rejecter:)
    func getVolume(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        print("Getting current volume")
        resolve(mediaWrapper.volume)
    }
    
    @objc(setRate:)
    func setRate(rate: Float) {
        guard [.playing].contains(mediaWrapper.mappedState) else { return }
        print("Setting rate to \(rate)")
        mediaWrapper.rate = rate
    }
    
    @objc(getRate:rejecter:)
    func getRate(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        print("Getting current rate")
        resolve(mediaWrapper.rate)
    }
    
    @objc(getTrack:resolver:rejecter:)
    func getTrack(id: String, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if !mediaWrapper.queueContainsTrack(trackId: id) {
            reject("track_not_in_queue", "Given track ID was not found in queue", nil)
            return
        }
        
        let track = mediaWrapper.queue.first(where: { $0.id == id })
        resolve(track!.toObject())
    }
    
    @objc(getQueue:rejecter:)
    func getQueue(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        let queue = mediaWrapper.queue.map { $0.toObject() }
        resolve(queue)
    }
    
    @objc(getCurrentTrack:rejecter:)
    func getCurrentTrack(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        resolve(mediaWrapper.currentTrack?.id)
    }
    
    @objc(getDuration:rejecter:)
    func getDuration(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        resolve(mediaWrapper.currentTrackDuration)
    }
    
    @objc(getBufferedPosition:rejecter:)
    func getBufferedPosition(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        resolve(mediaWrapper.bufferedPosition)
    }
    
    @objc(getPosition:rejecter:)
    func getPosition(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        resolve(mediaWrapper.currentTrackProgression)
    }
    
    @objc(getState:rejecter:)
    func getState(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        resolve(mediaWrapper.mappedState.rawValue)
    }
    
    
    // MARK: - Private Helpers
    
    private func toggleRemoteHandler(command: MPRemoteCommand, selector: Selector, enabled: Bool) {
        command.removeTarget(self, action: selector)
        command.addTarget(self, action: selector)
        command.isEnabled = enabled
    }
    
    
    // MARK: - Remote Dynamic Methods
    
    func remoteSentStop() {
        sendEvent(withName: "remote-stop", body: nil)
    }
    
    func remoteSentPause() {
        sendEvent(withName: "remote-pause", body: nil)
    }
    
    func remoteSentPlay() {
        sendEvent(withName: "remote-play", body: nil)
    }
    
    func remoteSentNext() {
        sendEvent(withName: "remote-next", body: nil)
    }
    
    func remoteSentPrevious() {
        sendEvent(withName: "remote-previous", body: nil)
    }
    
    func remoteSendSkipForward(event: MPSkipIntervalCommandEvent) {
        sendEvent(withName: "remote-jump-forward", body: ["interval": event.interval])
    }
    
    func remoteSendSkipBackward(event: MPSkipIntervalCommandEvent) {
        sendEvent(withName: "remote-jump-backward", body: ["interval": event.interval])
    }
    
    func remoteSentPlayPause() {
        if mediaWrapper.mappedState == .paused {
            sendEvent(withName: "remote-play", body: nil)
            return
        }
        
        sendEvent(withName: "remote-pause", body: nil)
    }
}
