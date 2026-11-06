import Foundation

/// Runs a heat curve on the Peak: starts a session, then moves the heater's target along the curve.
///
/// Approach from puff-studio (MIT, by SoyMilkIsOk): first try moving the running session's own target
/// (/p/app/thc/temp) and confirm against the heater's real target (/p/app/htr/tcmd). If the Peak ignores
/// that, fall back to the boost override (/p/app/tmpo), which the firmware caps at a small offset.
///
/// Safety rules that can't be turned off:
/// - targets are clamped to 350-590 °F
/// - the session stops immediately if the chamber reaches 600 °F
/// - the run ends if the session stops for any other reason, or the connection drops
/// - preheat waits at most 65 s
/// - the profile slot used for the run is restored byte-for-byte afterwards
@MainActor
final class CurveRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case preheating
        case running
        case finished(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var curve: HeatCurve?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var targetF: Double?
    @Published private(set) var driveNote = ""

    static let safeTargetF: ClosedRange<Double> = 350...590
    static let cutoffF: Double = 600
    /// Profile slot used for runs (profile 4), so profiles 1-3 are never touched.
    static let curveSlot = 3

    var isBusy: Bool {
        switch phase {
        case .preparing, .preheating, .running: return true
        case .idle, .finished: return false
        }
    }

    private weak var controller: PuffcoController?
    private var task: Task<Void, Never>?
    private var backup: Backup?

    private struct Backup {
        let slot: Int
        let tempBytes: [UInt8]
        let timeBytes: [UInt8]
        let originalActiveSlot: Int?
        var colorBytes: [UInt8]?
        var touchedOverride = false
    }

    private enum Mode { case probe, live, boost, none }

    private struct Driver {
        var mode: Mode
        var baseF: Double
        var maxOverrideF: Double = 15
        var lastSentF: Double?
        var lastSentAt = Date.distantPast
        var lastConfirmedF: Double?
        var pendingCheck: (wantF: Double, at: Date)?
        var misses = 0
    }

    init(controller: PuffcoController) {
        self.controller = controller
    }

    func start(_ curve: HeatCurve) {
        guard !isBusy else { return }
        let clean = curve.sanitized()
        self.curve = clean
        elapsed = 0
        targetF = nil
        driveNote = ""
        task = Task { [weak self] in
            await self?.run(clean)
        }
    }

    /// User stop: ends the session and restores the profile.
    func stop() {
        guard isBusy else { return }
        task?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.endSession(reason: "Stopped.")
        }
    }

    func reset() {
        if !isBusy { phase = .idle }
    }

    // MARK: - Run

    private func run(_ curve: HeatCurve) async {
        guard let c = controller else { return }
        guard c.phase == .ready else { return finish("Connect to your Peak first.") }
        guard !c.status.state.isHeating else { return finish("Your Peak is already heating. Stop it first.") }

        phase = .preparing
        let slot = Self.curveSlot
        let startF = min(max(curve.startTempF, Self.safeTargetF.lowerBound), Self.safeTargetF.upperBound)

        do {
            // 1. Save the slot exactly as it is.
            let temp = try await c.readPath(LoraxPath.profileTemp(slot), size: 4)
            let time = try await c.readPath(LoraxPath.profileTime(slot), size: 4)
            guard temp.count == 4, time.count == 4 else {
                return finish("Couldn't read profile 4 to back it up, so the curve didn't start.")
            }
            backup = Backup(slot: slot, tempBytes: temp, timeBytes: time, originalActiveSlot: c.status.activeProfile)

            // 2. Program the run's length and starting temperature; never heat on values the Peak refused.
            let seconds = Float(curve.duration.rounded())
            let timeBytes = c.status.profiles[slot].durationIsFloat ? Encode.float32(seconds) : Encode.uint32(UInt32(seconds))
            guard try await c.writePath(LoraxPath.profileTime(slot), timeBytes) else {
                return await abort("Your Peak didn't accept a \(Int(seconds))s heat time.")
            }
            guard try await c.writePath(LoraxPath.profileTemp(slot), Encode.float32(Float(Temp.c(fromF: startF)))) else {
                return await abort("Your Peak didn't accept \(Int(startF))°F to start.")
            }
            guard try await c.setActiveProfileNow(slot) else {
                return await abort("Couldn't select profile 4 for the curve.")
            }

            // Optional: show the curve's color while it runs (the old lights come back afterwards).
            if let color = curve.color {
                if let old = try await c.readAll(LoraxPath.profileColor(slot)), !old.isEmpty {
                    backup?.colorBytes = old
                    _ = try await c.writeColor(LoraxPath.profileColor(slot), color,
                                               effect: c.colorFormat == .api3 ? nil : curve.effect)
                }
            }

            // 3. Start heating.
            guard try await c.sendModeCommand(.heatStart) else {
                return await abort("Your Peak didn't start heating.")
            }
        } catch {
            return await abort("Setup failed: \(error.localizedDescription)")
        }

        // 4. Preheat: hold the curve's clock until the chamber is ready.
        phase = .preheating
        targetF = startF
        let preheatStart = Date()
        var idleReads = 0
        while true {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            guard let c = controller, c.phase == .ready else { return finish("Lost connection to your Peak.") }
            let waited = Date().timeIntervalSince(preheatStart)
            let liveF = c.status.tempC.map { Temp.f(fromC: $0) } ?? 0
            if liveF >= Self.cutoffF {
                return await endSession(reason: "Safety stop: the chamber reached \(Int(liveF))°F.")
            }
            if waited > 5, !c.status.state.isHeating {
                idleReads += 1
                if idleReads >= 2 { return await endSession(reason: "The session ended during preheat.") }
            } else {
                idleReads = 0
            }
            let ready = (c.status.state.isActive && waited > 2) || (liveF >= startF - 10 && waited > 1.5)
            if ready || waited > 65 { break }
        }

        // 5. Follow the curve twice a second.
        phase = .running
        let runStart = Date()
        var driver = await makeDriver(baseF: startF)
        idleReads = 0
        while true {
            if Task.isCancelled { return }
            guard let c = controller, c.phase == .ready else { return finish("Lost connection to your Peak.") }
            let t = Date().timeIntervalSince(runStart)
            elapsed = min(t, curve.duration)
            if t >= curve.duration {
                return await endSession(reason: "Curve complete.")
            }
            let liveF = c.status.tempC.map { Temp.f(fromC: $0) } ?? 0
            if liveF >= Self.cutoffF {
                return await endSession(reason: "Safety stop: the chamber reached \(Int(liveF))°F.")
            }
            if t > 3, !c.status.state.isHeating {
                idleReads += 1
                if idleReads >= 2 { return await endSession(reason: "The session was stopped on the Peak.") }
            } else {
                idleReads = 0
            }
            let want = min(max(curve.temp(at: t), Self.safeTargetF.lowerBound), Self.safeTargetF.upperBound)
            targetF = want
            await drive(&driver, toF: want)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Driving the heater

    private func makeDriver(baseF: Double) async -> Driver {
        guard let c = controller else { return Driver(mode: .none, baseF: baseF) }
        // Only move the session target if the Peak shows it plainly as float32 °C.
        if let bytes = try? await c.readPath(LoraxPath.sessionTemp, size: 4),
           let f = Decode.float32(bytes), f.isFinite, f >= 150, f <= 400 {
            driveNote = "Steering the session temperature."
            return Driver(mode: .probe, baseF: Temp.f(fromC: Double(f)))
        }
        driveNote = "Using boost offsets (small range)."
        return Driver(mode: .boost, baseF: baseF)
    }

    private func drive(_ d: inout Driver, toF wantF: Double) async {
        guard let c = controller else { return }
        await verify(&d)
        if d.mode == .none { return }
        if let last = d.lastSentF, abs(wantF - last) < 2 || Date().timeIntervalSince(d.lastSentAt) < 0.6 { return }

        switch d.mode {
        case .probe, .live:
            let ok = (try? await c.writePath(LoraxPath.sessionTemp, Encode.float32(Float(Temp.c(fromF: wantF))))) ?? false
            guard ok else { return }
            if let last = d.lastConfirmedF ?? d.lastSentF, abs(wantF - last) > 6 {
                d.pendingCheck = (wantF, Date())
            }
        case .boost:
            let deltaF = min(d.maxOverrideF, max(-60, wantF - d.baseF))
            backup?.touchedOverride = true
            let ok = (try? await c.writePath(LoraxPath.tempOverride, Encode.float32(Float(deltaF * 5 / 9)))) ?? false
            guard ok else { return }
            if let read = try? await c.readPath(LoraxPath.tempOverride, size: 4), let v = Decode.float32(read), v.isFinite {
                let gotF = Double(v) * 9 / 5
                if deltaF > 0, gotF < deltaF - 0.6 { d.maxOverrideF = max(0, gotF) }
            }
        case .none:
            return
        }
        d.lastSentF = wantF
        d.lastSentAt = Date()
    }

    /// Checks whether the heater's real target followed a live write; two misses switch to boost offsets.
    private func verify(_ d: inout Driver) async {
        guard d.mode == .probe || d.mode == .live, let check = d.pendingCheck,
              Date().timeIntervalSince(check.at) > 0.4, let c = controller else { return }
        guard let bytes = try? await c.readPath(LoraxPath.heaterCommand, size: 4),
              let v = Decode.float32(bytes), v.isFinite, v > 0 else { return }
        let actualF = Temp.f(fromC: Double(v))
        d.pendingCheck = nil
        if abs(actualF - check.wantF) <= 6 {
            d.mode = .live
            d.misses = 0
            d.lastConfirmedF = actualF
        } else {
            d.misses += 1
            if d.misses >= 2 {
                d.mode = .boost
                d.misses = 0
                d.lastSentF = nil
                driveNote = "Your Peak ignored live changes; using boost offsets (small range)."
                _ = try? await c.writePath(LoraxPath.sessionTemp, Encode.float32(Float(Temp.c(fromF: d.baseF))))
            }
        }
    }

    // MARK: - Ending

    private func endSession(reason: String) async {
        if let c = controller, c.phase == .ready {
            _ = try? await c.sendModeCommand(.heatAbort)
        }
        await restore()
        finish(reason)
    }

    private func abort(_ reason: String) async {
        await restore()
        finish(reason)
    }

    private func restore() async {
        guard let b = backup, let c = controller, c.phase == .ready else { return }
        backup = nil
        if b.touchedOverride {
            _ = try? await c.writePath(LoraxPath.tempOverride, Encode.float32(0))
        }
        if let colorBytes = b.colorBytes {
            _ = try? await c.writeAll(LoraxPath.profileColor(b.slot), colorBytes)
        }
        _ = try? await c.writePath(LoraxPath.profileTemp(b.slot), b.tempBytes)
        _ = try? await c.writePath(LoraxPath.profileTime(b.slot), b.timeBytes)
        if let original = b.originalActiveSlot {
            _ = try? await c.setActiveProfileNow(original)
        }
        await c.refreshProfiles()
    }

    private func finish(_ message: String) {
        phase = .finished(message)
        driveNote = ""
        task = nil
    }
}
