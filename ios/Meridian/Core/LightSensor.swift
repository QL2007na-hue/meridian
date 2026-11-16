//
//  LightSensor.swift
//  Meridian — ambient light, at two very different power costs.
//
//  iOS exposes no public ambient-light sensor, so the room has to be inferred.
//  There are exactly two honest sources and they are not equal:
//
//    screen   UIScreen.brightness. Free: no permission, no hardware wake-up,
//             and on a device with Auto-Brightness on it already tracks the
//             room. Coarse, because it also follows the user's own preference.
//
//    precise  The front camera, sampled in 350ms bursts every 30 seconds. It
//             sees the actual room, but an always-on capture session is one of
//             the most expensive things an iPad can do — which is why it is a
//             burst, not a stream, and why it is opt-in.
//
//  A clock that runs all day must default to the free source.
//

import AVFoundation
import Foundation
import UIKit

final class LightSensor: NSObject {

    enum Mode {
        case screen
        case precise
    }

    /// Called on the main thread with a value in 0...1.
    var onLevel: ((Double) -> Void)?
    /// True while either source is producing readings.
    private(set) var isRunning = false

    private var mode: Mode = .screen

    // MARK: Screen backlight

    private var screenObserver: NSObjectProtocol?
    private var lastScreenRead: CFTimeInterval = 0
    private var screenEMA: Double = 0.5

    // MARK: Camera bursts

    private let controlQueue = DispatchQueue(label: "meridian.light.control", qos: .utility)
    private let sampleQueue = DispatchQueue(label: "meridian.light.sample", qos: .utility)
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var input: AVCaptureDeviceInput?
    private var latestLuma: Double?
    private var cameraEMA: Double?
    private var pulseTimer: Timer?
    private var burstDeadline: CFTimeInterval = 0
    private var generation = 0

    // MARK: - Public

    func start(mode: Mode, completion: @escaping (Bool) -> Void) {
        stop()
        self.mode = mode
        generation += 1
        let token = generation

        switch mode {
        case .screen:
            beginScreenMode(token: token, completion: completion)
        case .precise:
            beginPreciseMode(token: token, completion: completion)
        }
    }

    func stop() {
        generation += 1
        isRunning = false

        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        pulseTimer?.invalidate()
        pulseTimer = nil
        NotificationCenter.default.removeObserver(self)
        controlQueue.async { [weak self] in
            guard let self else { return }
            if self.session?.isRunning == true {
                self.session?.stopRunning()
            }
        }
    }

    // MARK: - Screen mode

    private func beginScreenMode(token: Int, completion: @escaping (Bool) -> Void) {
        isRunning = true
        readScreen(force: true)

        let center = NotificationCenter.default
        screenObserver = center.addObserver(
            forName: UIScreen.brightnessDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.readScreen(force: false)
        }

        // Pause while the app is not on screen: nothing reads a clock that is
        // not being looked at.
        center.addObserver(
            self,
            selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        DispatchQueue.main.async { completion(true) }
    }

    /// Maps screen backlight to "how bright is the room". The floor is 0.15 so a
    /// deliberately dimmed screen does not read as pitch black.
    private func readScreen(force: Bool) {
        let now = CACurrentMediaTime()
        if !force, now - lastScreenRead < 1.0 { return }   // 1s throttle
        lastScreenRead = now

        let raw = Double(UIScreen.main.brightness)
        let mapped = 0.15 + max(0, min(1, raw)) * 0.85
        screenEMA = screenEMA * 0.65 + mapped * 0.35
        emit(screenEMA)
    }

    // MARK: - Precise mode

    private func beginPreciseMode(token: Int, completion: @escaping (Bool) -> Void) {
        // Screen mode runs regardless: it is the fallback if the camera says no.
        beginScreenMode(token: token) { _ in }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self, self.generation == token else { return }
            guard granted else {
                // Silently degrade — the screen reading is already running.
                DispatchQueue.main.async { completion(true) }
                return
            }
            self.configureSessionIfNeeded()
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.startPulseLoop(token: token)
                completion(true)
            }
        }
    }

    private func startPulseLoop(token: Int) {
        pulseTimer?.invalidate()
        pulseNow(token: token)

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.pulseNow(token: token)
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    /// One 350ms burst: start the session, keep the newest frame, stop it again.
    /// The session object is reused, but it is *not running* between bursts, so
    /// the camera is genuinely powered down for ~29.6 of every 30 seconds.
    private func pulseNow(token: Int) {
        guard session != nil else { return }
        latestLuma = nil
        burstDeadline = CACurrentMediaTime() + 0.35

        controlQueue.async { [weak self] in
            guard let self else { return }
            self.session?.startRunning()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.generation == token else { return }
            self.controlQueue.async {
                if self.session?.isRunning == true {
                    self.session?.stopRunning()
                }
            }
            guard let luma = self.latestLuma else { return }
            // Fuse: the camera sees the room, the backlight knows the user's
            // intent. Weighted toward the camera, which is the real measurement.
            let fused = luma * 0.7 + self.screenEMA * 0.3
            let smoothed = (self.cameraEMA ?? fused) * 0.6 + fused * 0.4
            self.cameraEMA = smoothed
            self.emit(smoothed)
        }
    }

    private func configureSessionIfNeeded() {
        guard session == nil else { return }
        controlQueue.async { [weak self] in
            guard let self else { return }
            guard let device = Self.camera() else { return }
            let session = AVCaptureSession()
            session.sessionPreset = .low   // ~192x144 is plenty for an average
            guard let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.sampleQueue)
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)

            self.input = input
            self.output = output
            self.session = session
        }
    }

    private static func camera() -> AVCaptureDevice? {
        if let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            return front
        }
        if let any = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) {
            return any
        }
        return AVCaptureDevice.default(for: .video)
    }

    // MARK: - Emission

    private func emit(_ value: Double) {
        let clamped = min(1, max(0, value))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.onLevel?(clamped)
        }
    }

    // MARK: - Lifecycle

    @objc private func handleBackground() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        controlQueue.async { [weak self] in
            if self?.session?.isRunning == true {
                self?.session?.stopRunning()
            }
        }
    }

    @objc private func handleForeground() {
        guard isRunning else { return }
        let token = generation
        if mode == .precise, session != nil {
            startPulseLoop(token: token)
        }
        readScreen(force: true)
    }
}

// MARK: - Frame sampling

extension LightSensor: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Only the burst window matters; frames after the deadline are dropped
        // without touching the buffer.
        guard CACurrentMediaTime() < burstDeadline else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let luma = Self.averageLuma(of: pixelBuffer) else { return }
        // Same log compression as before: the camera's auto-exposure lifts dark
        // rooms, which would otherwise flatten the bottom of the range.
        latestLuma = pow(luma, 0.45)
    }

    private static func averageLuma(of pixelBuffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              width > 0, height > 0 else { return nil }

        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        var count = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                sum += Int(pointer[y * bytesPerRow + x])
                count += 1
                x += 16
            }
            y += 16
        }
        guard count > 0 else { return nil }
        return Double(sum) / Double(count) / 255.0
    }
}
