import Foundation
import CoreBluetooth
import SwiftUI

/// Owns the Bluetooth stack and the connection to one Puffco device.
/// Everything runs on the main queue / main actor, which keeps things simple:
/// CoreBluetooth calls its delegate on the main queue because we pass `queue: nil`.
@MainActor
final class PuffcoController: NSObject, ObservableObject {
    // MARK: Published state

    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published var showAllDevices = false
    @Published private(set) var phase: ConnectionPhase = .disconnected
    @Published private(set) var status = DeviceStatus()
    @Published private(set) var connectedName: String?
    @Published var lastError: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var lastDevice: CBPeripheral?

    /// Studio heat-curve runner (unlocked with the Jailbreak button).
    lazy var curves = CurveRunner(controller: self)

    var visibleDevices: [DiscoveredDevice] {
        let list = showAllDevices ? devices : devices.filter(\.isLikelyPuffco)
        return list.sorted { $0.rssi > $1.rssi }
    }

    // MARK: Private state

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var replyChar: CBCharacteristic?
    private var versionChar: CBCharacteristic?
    private var eventChar: CBCharacteristic?
    /// Which setup step is running, so a failure message can say where it got stuck.
    private var setupStep = ""
    /// Log every packet until the device is unlocked (polling would flood the log afterwards).
    private var verbose = true
    /// Whether the device has replied to anything this connection (it stays silent until paired).
    private var gotAnyReply = false
    /// Firmware and model come from the Lorax file system; read them once per connection.
    private var readDeviceInfo = false
    /// Color file format this Peak uses, learned from its existing color files.
    @Published private(set) var colorFormat: PeakColorFormat?
    /// Latest live-preview color waiting to be sent (outer nil = nothing pending, inner nil = clear).
    private var pendingPreview: PreviewLook??
    private var previewTask: Task<Void, Never>?

    private var nextSeq: UInt16 = 0xFFFF
    private var pendingReplies: [UInt16: CheckedContinuation<Lorax.Reply, Error>] = [:]
    private var pendingReads: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private let gate = AsyncGate()
    private var pollTask: Task<Void, Never>?
    private var setupStarted = false
    private var userDisconnected = false
    /// Paths that timed out once; skipped afterwards so polling stays fast.
    private var unsupportedPaths: Set<String> = []

    private static let lastDeviceKey = "lastDeviceIdentifier"
    private static let nameKeywords = ["puffco", "peak", "proxy", "pivot"]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    func startScan() {
        guard central.state == .poweredOn, !isScanning else { return }
        devices.removeAll()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    // MARK: - Connecting

    func connect(_ device: DiscoveredDevice) {
        connect(peripheral: device.peripheral, name: device.name)
    }

    func connectLastDevice() {
        guard let p = lastDevice else { return }
        connect(peripheral: p, name: p.name ?? "Puffco")
    }

    private func connect(peripheral p: CBPeripheral, name: String) {
        stopScan()
        resetSession()
        userDisconnected = false
        lastError = nil
        peripheral = p
        p.delegate = self
        connectedName = name
        phase = .connecting
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.lastDeviceKey)
        lastDevice = p
        appendLog("Connecting to \(name)")
        central.connect(p, options: nil)
    }

    func disconnect() {
        userDisconnected = true
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        teardown(phase: .disconnected)
    }

    private func resetSession() {
        pollTask?.cancel()
        pollTask = nil
        commandChar = nil
        replyChar = nil
        versionChar = nil
        eventChar = nil
        setupStarted = false
        setupStep = ""
        verbose = true
        gotAnyReply = false
        nextSeq = 0xFFFF
        readDeviceInfo = false
        colorFormat = nil
        pendingPreview = nil
        previewTask?.cancel()
        previewTask = nil
        unsupportedPaths = []
        failPending(PuffcoError.notConnected)
    }

    private func teardown(phase newPhase: ConnectionPhase) {
        resetSession()
        peripheral = nil
        status = DeviceStatus()
        connectedName = nil
        phase = newPhase
    }

    private func fail(_ message: String) {
        appendLog("Error: \(message)")
        let p = peripheral
        userDisconnected = true
        teardown(phase: .failed(message))
        if let p { central.cancelPeripheralConnection(p) }
    }

    private func failPending(_ error: Error) {
        let replies = pendingReplies
        pendingReplies.removeAll()
        replies.values.forEach { $0.resume(throwing: error) }
        let reads = pendingReads
        pendingReads.removeAll()
        reads.values.forEach { $0.resume(throwing: error) }
    }

    // MARK: - Session setup (pair → unlock → first read)

    private func runSetup() async {
        guard !setupStarted else { return }
        setupStarted = true
        do {
            // Reading the version characteristic triggers iOS bonding on first connect.
            phase = .pairing
            setupStep = "pairing"
            if let v = versionChar {
                do {
                    let data = try await readCharacteristic(v, timeout: 45)
                    appendLog("Version char: \([UInt8](data).hex)")
                } catch {
                    appendLog("Version read failed (continuing): \(error.localizedDescription)")
                }
            }
            await readEverythingReadable()

            phase = .authenticating
            try await Task.sleep(nanoseconds: 500_000_000) // let the device settle, as melt does

            // Same opening sequence the official app uses (from melt's capture). Both are optional.
            setupStep = "init command"
            if let r = try? await send(.pruneFileHandles, body: [0x01, 0xC0, 0x03], timeout: 2) {
                appendLog("Init reply status \(r.status)")
            }
            setupStep = "get limits"
            if let r = try? await send(.getLimits) {
                appendLog("Limits (status \(r.status)): \(r.payload.hex)")
            }

            try await authenticate()

            phase = .ready
            setupStep = ""
            verbose = false
            appendLog("Unlocked ✓")
            await refreshProfiles()
            await pollSlow()
            await pollFast()
            startPolling()
        } catch {
            if let e = error as? PuffcoError, case .timeout = e, !gotAnyReply {
                fail("Your Peak isn't answering, which usually means it isn't paired with this device yet. Hold its button for 6 seconds until it glows blue, then tap it here again and accept the iOS pairing request.")
            } else {
                let step = setupStep.isEmpty ? "" : " (step: \(setupStep))"
                fail(error.localizedDescription + step)
            }
        }
    }

    /// Reads every readable characteristic outside the Lorax/Device Info services.
    /// If any of them requires encryption, iOS shows its pairing prompt and bonds with the Peak.
    private func readEverythingReadable() async {
        guard let p = peripheral else { return }
        for service in p.services ?? [] where service.uuid != Lorax.serviceUUID && service.uuid != Lorax.deviceInfoServiceUUID {
            appendLog("Service \(service.uuid.uuidString.prefix(8))")
            for c in service.characteristics ?? [] {
                let id = String(c.uuid.uuidString.prefix(8))
                guard c.properties.contains(.read) else {
                    appendLog("  \(id): \(Self.describe(c.properties))")
                    continue
                }
                do {
                    let data = try await readCharacteristic(c, timeout: 30)
                    appendLog("  \(id) read: \(Array([UInt8](data).prefix(24)).hex)")
                } catch {
                    appendLog("  \(id) read error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func authenticate() async throws {
        setupStep = "get unlock seed"
        var seedReply: Lorax.Reply
        do {
            seedReply = try await send(.getAccessSeed)
        } catch PuffcoError.timeout {
            appendLog("Seed request timed out, retrying once")
            seedReply = try await send(.getAccessSeed)
        }
        appendLog("Seed (status \(seedReply.status)): \(seedReply.payload.hex)")
        guard let token = Lorax.authToken(seed: seedReply.payload) else { throw PuffcoError.authFailed }

        setupStep = "unlock"
        let unlock = try await send(.unlockAccess, body: token)
        appendLog("Unlock status: \(unlock.status)")

        // Confirm by reading something that requires access.
        setupStep = "first read"
        let state = try await readPath(LoraxPath.operatingState, size: 1)
        guard let raw = state.first else { throw PuffcoError.authFailed }
        status.state = OperatingState(raw: raw)
    }

    // MARK: - Lorax request / reply

    private func send(_ opcode: Lorax.Opcode, body: [UInt8] = [], timeout: Double = 5) async throws -> Lorax.Reply {
        await gate.acquire()
        defer { gate.release() }

        guard let p = peripheral, p.state == .connected, let cmd = commandChar else {
            throw PuffcoError.notConnected
        }

        nextSeq = nextSeq &+ 1 // starts at 0 on each connection, like the official app
        let seq = nextSeq
        let packet = Lorax.command(seq: seq, opcode: opcode, body: body)
        // Write with response when possible (melt found unacknowledged writes get dropped).
        let writeType: CBCharacteristicWriteType =
            cmd.properties.contains(.write) ? .withResponse : .withoutResponse
        if verbose { appendLog("TX \(opcode) seq \(seq): \([UInt8](packet).hex)") }

        return try await withCheckedThrowingContinuation { continuation in
            pendingReplies[seq] = continuation
            p.writeValue(packet, for: cmd, type: writeType)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.expireReply(seq)
            }
        }
    }

    private func expireReply(_ seq: UInt16) {
        if let c = pendingReplies.removeValue(forKey: seq) {
            c.resume(throwing: PuffcoError.timeout)
        }
    }

    private func handleReply(_ data: Data) {
        gotAnyReply = true
        guard let reply = Lorax.parseReply(data) else {
            appendLog("RX (too short): \([UInt8](data).hex)")
            return
        }
        if let c = pendingReplies.removeValue(forKey: reply.seq) {
            if verbose { appendLog("RX seq \(reply.seq) status \(reply.status): \(reply.payload.hex)") }
            c.resume(returning: reply)
        } else {
            appendLog("RX unmatched seq \(reply.seq): \([UInt8](data).hex)")
        }
    }

    /// Reads a VFS path. Returns an empty array if the device reports an error.
    func readPath(_ path: String, size: UInt16) async throws -> [UInt8] {
        let reply = try await send(.readShort, body: Lorax.readShortBody(path: path, size: size))
        return reply.status == 0 ? reply.payload : []
    }

    /// Like `readPath`, but gives up quietly (and remembers) if the path never answers.
    private func readOptional(_ path: String, size: UInt16) async throws -> [UInt8]? {
        if unsupportedPaths.contains(path) { return nil }
        do {
            let bytes = try await readPath(path, size: size)
            return bytes.isEmpty ? nil : bytes
        } catch PuffcoError.timeout {
            unsupportedPaths.insert(path)
            appendLog("No answer for \(path); skipping it from now on")
            return nil
        }
    }

    /// Reads a whole file in chunks (color files can be longer than one packet).
    func readAll(_ path: String, chunk: UInt16 = 96, limit: Int = 2048) async throws -> [UInt8]? {
        if unsupportedPaths.contains(path) { return nil }
        var out: [UInt8] = []
        while out.count < limit {
            let reply: Lorax.Reply
            do {
                reply = try await send(.readShort, body: Lorax.readShortBody(path: path, offset: UInt16(out.count), size: chunk))
            } catch PuffcoError.timeout {
                unsupportedPaths.insert(path)
                return out.isEmpty ? nil : out
            }
            guard reply.status == 0, !reply.payload.isEmpty else { break }
            out += reply.payload
            if reply.payload.count < Int(chunk) { break }
        }
        return out.isEmpty ? nil : out
    }

    /// Writes a whole file in chunks at increasing offsets (as PuffcoBLE does for color files).
    @discardableResult
    func writeAll(_ path: String, _ value: [UInt8], chunk: Int = 80) async throws -> Bool {
        var offset = 0
        while offset < value.count {
            let piece = Array(value[offset..<min(offset + chunk, value.count)])
            let reply = try await send(.writeShort, body: Lorax.writeShortBody(path: path, value: piece, offset: UInt16(offset)))
            appendLog("Write \(path) @\(offset) (\(piece.count) bytes) → status \(reply.status)")
            guard reply.status == 0 else { return false }
            offset += piece.count
        }
        return true
    }

    @discardableResult
    func writePath(_ path: String, _ value: [UInt8]) async throws -> Bool {
        let reply = try await send(.writeShort, body: Lorax.writeShortBody(path: path, value: value))
        appendLog("Write \(path) = \(value.hex) → status \(reply.status)")
        return reply.status == 0
    }

    private func readCharacteristic(_ c: CBCharacteristic, timeout: Double) async throws -> Data {
        guard let p = peripheral else { throw PuffcoError.notConnected }
        let uuid = c.uuid
        return try await withCheckedThrowingContinuation { continuation in
            pendingReads[uuid] = continuation
            p.readValue(for: c)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let pending = self?.pendingReads.removeValue(forKey: uuid) {
                    pending.resume(throwing: PuffcoError.timeout)
                }
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var lastSlow = Date()
            while !Task.isCancelled {
                guard let self else { return }
                if Date().timeIntervalSince(lastSlow) > 5 {
                    lastSlow = Date()
                    await self.pollSlow()
                }
                await self.pollFast()
                let delay = self.status.state.isHeating ? 0.3 : 1.0
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func pollFast() async {
        do {
            let stateBytes = try await readPath(LoraxPath.operatingState, size: 1)
            if let raw = stateBytes.first { status.state = OperatingState(raw: raw) }

            if let bytes = try await readOptional(LoraxPath.heaterTemp, size: 4),
               let c = Decode.temperatureC(bytes) {
                status.tempC = c
            }

            if status.state.isHeating {
                if let bytes = try await readOptional(LoraxPath.heaterTarget, size: 4),
                   let c = Decode.temperatureC(bytes) {
                    status.targetC = c
                }
                let elapsedBytes = try await readOptional(LoraxPath.elapsed, size: 4)
                let totalBytes = try await readOptional(LoraxPath.total, size: 4)
                if let eb = elapsedBytes, let tb = totalBytes,
                   var e = Decode.seconds(eb)?.value, var t = Decode.seconds(tb)?.value {
                    if t > 300 { e /= 1000; t /= 1000 } // some firmware reports milliseconds
                    status.elapsedS = e
                    status.totalS = t
                }
            } else {
                status.elapsedS = nil
                status.totalS = nil
                if let active = status.activeProfile, active < status.profiles.count {
                    status.targetC = status.profiles[active].tempC
                }
            }
        } catch {
            handlePollError(error)
        }
    }

    private func pollSlow() async {
        do {
            if let b = try await readOptional(LoraxPath.batteryCapacity, size: 4), let pct = Decode.battery(b) {
                status.batteryPct = pct
            } else if let b = try await readOptional(LoraxPath.batterySoc, size: 4), let pct = Decode.battery(b) {
                status.batteryPct = pct
            }
            if let b = try await readOptional(LoraxPath.chargeState, size: 1) { status.chargeRaw = b.first }
            if let b = try await readOptional(LoraxPath.chamberType, size: 1) { status.chamberRaw = b.first }

            if let b = try await readOptional(LoraxPath.totalDabs, size: 4), let n = Decode.count(b) {
                status.lifetimeDabs = n
            } else if let b = try await readOptional(LoraxPath.odometerDabs, size: 4), let n = Decode.count(b) {
                status.lifetimeDabs = n
            }

            if let b = try await readOptional(LoraxPath.activeProfile, size: 1), let i = b.first, i < 4 {
                status.activeProfile = Int(i)
            }
            if let b = try await readOptional(LoraxPath.stealth, size: 1), let v = b.first {
                status.stealth = v != 0
            }
            if let b = try await readOptional(LoraxPath.ledBrightness, size: 4), let v = b.first {
                status.brightness = v
            }
            if status.deviceName == nil, let b = try await readOptional(LoraxPath.deviceName, size: 32) {
                status.deviceName = Decode.string(b)
            }
            if status.serial == nil, let b = try await readOptional(LoraxPath.serial, size: 32) {
                status.serial = Decode.string(b)
            }
            try await pollSettingsAndStats()
            if !readDeviceInfo {
                readDeviceInfo = true
                if let b = try await readOptional(LoraxPath.firmwareRevision, size: 12), let rev = b.first {
                    appendLog("Firmware bytes: \(b.hex)")
                    status.firmware = PuffcoInfo.revisionString(Int(rev))
                }
                if let b = try await readOptional(LoraxPath.modelCode, size: 4), let code = Decode.uint32(b) {
                    appendLog("Model code: \(code)")
                    status.model = PuffcoInfo.model(code: code) ?? "Model code \(code)"
                }
            }
        } catch {
            handlePollError(error)
        }
    }

    private func pollSettingsAndStats() async throws {
        func float(_ path: String) async throws -> Double? {
            guard let b = try await readOptional(path, size: 4) else { return nil }
            return Decode.finiteFloat(b)
        }
        if let v = try await float(LoraxPath.readyMode) {
            status.readyModeProfile = (v >= 0 && v < 4) ? Int(v) : -1
        }
        status.batteryVolts = try await float(LoraxPath.batteryVolts) ?? status.batteryVolts
        status.batteryTempC = try await float(LoraxPath.batteryTemp) ?? status.batteryTempC
        if let b = try await readOptional(LoraxPath.chargeSource, size: 1) { status.chargeSourceRaw = b.first }
        status.chargeTimeToFullS = try await float(LoraxPath.chargeTimeToFull)
        status.maxBatteryPct = try await float(LoraxPath.maxBatterySoc) ?? status.maxBatteryPct
        status.lowBatteryWarnPct = try await float(LoraxPath.lowBatteryWarn) ?? status.lowBatteryWarnPct
        if let b = try await readOptional(LoraxPath.totalHeatTime, size: 4) { status.totalHeatTimeS = Decode.seconds(b)?.value }
        if let b = try await readOptional(LoraxPath.tripDabs, size: 4) { status.tripDabs = Decode.count(b) }
        if let b = try await readOptional(LoraxPath.tripHeatTime, size: 4) { status.tripHeatTimeS = Decode.seconds(b)?.value }
        status.dabsPerDay = try await float(LoraxPath.dabsPerDay) ?? status.dabsPerDay
        status.dabsRemaining = try await float(LoraxPath.dabsRemaining) ?? status.dabsRemaining
        if status.lantern {
            status.lanternRemainingS = try await float(LoraxPath.lanternRemaining)
        }
    }

    func refreshProfiles() async {
        do {
            for slot in 0..<4 {
                var profile = status.profiles[slot]
                if let b = try await readOptional(LoraxPath.profileName(slot), size: 32) {
                    profile.name = Decode.string(b)
                }
                if let b = try await readOptional(LoraxPath.profileTemp(slot), size: 4) {
                    profile.tempC = Decode.temperatureC(b)
                }
                if let b = try await readOptional(LoraxPath.profileTime(slot), size: 4),
                   let s = Decode.seconds(b) {
                    profile.durationS = s.value
                    profile.durationIsFloat = s.isFloat
                }
                if let b = try await readOptional(LoraxPath.profileBoostTemp(slot), size: 4) {
                    profile.boostTempDeltaC = Decode.finiteFloat(b)
                }
                if let b = try await readOptional(LoraxPath.profileBoostTime(slot), size: 4) {
                    profile.boostTimeS = Decode.finiteFloat(b)
                }
                if let b = try await readOptional(LoraxPath.profileIntensity(slot), size: 4) {
                    profile.intensity = Decode.finiteFloat(b)
                }
                if let b = try await readAll(LoraxPath.profileColor(slot)) {
                    if colorFormat == nil, let f = PeakColorFormat.detect(b) {
                        colorFormat = f
                        appendLog("Color format: \(f)")
                    }
                    if verbose || slot == 0 { appendLog("Profile \(slot + 1) color file: \(Array(b.prefix(48)).hex)") }
                    if let c = PeakColor.firstColor(in: b) { profile.color = RGB(r: c.0, g: c.1, b: c.2) }
                    profile.lightEffect = PeakColor.effect(in: b)
                    profile.isMultiColor = PeakColor.isMultiColor(b)
                }
                status.profiles[slot] = profile
            }
            if let b = try await readOptional(LoraxPath.activeProfile, size: 1), let i = b.first, i < 4 {
                status.activeProfile = Int(i)
            }
            if let b = try await readAll(LoraxPath.lanternColor),
               let c = PeakColor.firstColor(in: b) {
                status.lanternColor = RGB(r: c.0, g: c.1, b: c.2)
                status.lanternEffect = PeakColor.effect(in: b)
            }
            if let b = try await readAll(LoraxPath.lanternColor) {
                status.lanternIsMultiColor = PeakColor.isMultiColor(b)
            }
        } catch {
            handlePollError(error)
        }
    }

    private func handlePollError(_ error: Error) {
        if let e = error as? PuffcoError, case .notConnected = e { return }
        appendLog("Poll error: \(error.localizedDescription)")
    }

    // MARK: - Commands

    func startHeat() { sendMode(.heatStart) }
    func boost() { sendMode(.heatBoost) }
    func stopHeat() { sendMode(.heatAbort) }

    private func sendMode(_ command: ModeCommand) {
        perform("Mode command \(command)") { c in
            try await c.writePath(LoraxPath.modeCommand, [command.rawValue])
            await c.pollFast()
        }
    }

    func selectProfile(_ slot: Int) {
        perform("Select profile") { c in
            if try await c.writePath(LoraxPath.activeProfile, [UInt8(slot)]) {
                c.status.activeProfile = slot
                c.status.targetC = c.status.profiles[slot].tempC
            }
        }
    }

    func saveProfile(slot: Int, edit: ProfileEdit) {
        perform("Save profile") { c in
            let profile = c.status.profiles[slot]
            try await c.writePath(LoraxPath.profileTemp(slot), Encode.float32(Float(edit.tempC)))
            let seconds = edit.durationS.rounded()
            let timeBytes = profile.durationIsFloat ? Encode.float32(Float(seconds)) : Encode.uint32(UInt32(seconds))
            try await c.writePath(LoraxPath.profileTime(slot), timeBytes)
            if let d = edit.boostTempDeltaC {
                try await c.writePath(LoraxPath.profileBoostTemp(slot), Encode.float32(Float(d)))
            }
            if let t = edit.boostTimeS {
                try await c.writePath(LoraxPath.profileBoostTime(slot), Encode.float32(Float(t.rounded())))
            }
            if let level = edit.intensity, level != profile.intensity {
                try await c.writePath(LoraxPath.profileIntensity(slot), Encode.float32(Float(level)))
            }
            if let multi = edit.multi {
                let pointer = try await c.writeMultiColor(multi, slot: MultiColorSlot.profile(slot))
                try await c.writePath(LoraxPath.profileColor(slot), pointer)
            } else if let color = edit.color, color != profile.color || profile.isMultiColor || (edit.effect != nil && edit.effect != profile.lightEffect) {
                try await c.writeColor(LoraxPath.profileColor(slot), color, effect: edit.effect)
            }
            await c.refreshProfiles()
        }
    }

    /// -1 turns Ready Mode off; 0...3 picks the profile that starts when the Peak leaves the Power Dock.
    func setReadyMode(_ profile: Int) {
        perform("Ready Mode") { c in
            let value: Float = profile < 0 ? 4_294_967_295 : Float(profile)
            if try await c.writePath(LoraxPath.readyMode, Encode.float32(value)) {
                c.status.readyModeProfile = profile
            }
        }
    }

    func setLanternColor(_ color: RGB, effect: LightEffect? = nil) {
        perform("Lantern color") { c in
            if try await c.writeColor(LoraxPath.lanternColor, color, effect: effect) {
                c.status.lanternColor = color
                if let effect { c.status.lanternEffect = effect }
            }
        }
    }

    func setLanternMultiColor(_ look: MultiColorLook) {
        perform("Lantern colors") { c in
            let pointer = try await c.writeMultiColor(look, slot: MultiColorSlot.lantern)
            if try await c.writePath(LoraxPath.lanternColor, pointer) {
                c.status.lanternIsMultiColor = true
            }
        }
    }

    /// Writes the color list and offset list for `look` into `slot`; returns the 8-byte pointer to use.
    private func writeMultiColor(_ look: MultiColorLook, slot: UInt8) async throws -> [UInt8] {
        try await writeAll(LoraxPath.userColorList(slot), look.colorListBytes())
        try await writeAll(LoraxPath.userOffsetList(slot), look.offsetListBytes())
        return look.pointerBytes(slot: slot)
    }

    /// Writes a solid color in whichever format this Peak uses (8-byte by default).
    @discardableResult
    private func writeColor(_ path: String, _ color: RGB, effect: LightEffect? = nil) async throws -> Bool {
        let format = colorFormat ?? .api2
        let bytes = PeakColor.payload(color, format: format, effect: effect)
        if format == .api2 {
            return try await writePath(path, bytes)
        } else {
            return try await writeAll(path, bytes)
        }
    }

    /// Shows a color on the Peak while the user is choosing it; nil ends the preview.
    /// Sends at most ~8 updates a second and always delivers the latest one.
    func preview(_ color: RGB?, effect: LightEffect? = nil) {
        preview(color.map { PreviewLook.singleColor($0, effect) })
    }

    /// Live preview of a single color or a multi-color look; nil ends the preview.
    func preview(_ look: PreviewLook?) {
        guard phase == .ready else { return }
        pendingPreview = .some(look)
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            while let strong = self, let next = strong.pendingPreview {
                strong.pendingPreview = nil
                do {
                    try await strong.sendPreview(next)
                } catch {
                    strong.appendLog("Preview failed: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            self?.previewTask = nil
        }
    }

    private func sendPreview(_ look: PreviewLook?) async throws {
        let format = colorFormat ?? .api2
        let bytes: [UInt8]
        if let multi = look?.multi, format == .api2 {
            bytes = try await writeMultiColor(multi, slot: MultiColorSlot.preview)
        } else if let look, let color = look.color {
            bytes = PeakColor.payload(color, format: format, effect: look.effect)
        } else {
            bytes = format == .api2 ? PeakColor.api2None : [0xF6] // CBOR null
        }
        let reply = try await send(.writeShort, body: Lorax.writeShortBody(path: LoraxPath.previewColor, value: bytes))
        if reply.status != 0 { appendLog("Preview write status \(reply.status)") }
    }

    // MARK: - Awaitable commands (Studio)

    /// Sends a mode command and reports whether the Peak accepted it.
    func sendModeCommand(_ command: ModeCommand) async throws -> Bool {
        try await writePath(LoraxPath.modeCommand, [command.rawValue])
    }

    /// Selects a profile slot and waits for the Peak's answer.
    func setActiveProfileNow(_ slot: Int) async throws -> Bool {
        let ok = try await writePath(LoraxPath.activeProfile, [UInt8(slot)])
        if ok { status.activeProfile = slot }
        return ok
    }

    func setStealth(_ on: Bool) {
        perform("Stealth") { c in
            if try await c.writePath(LoraxPath.stealth, [on ? 1 : 0]) { c.status.stealth = on }
        }
    }

    func setLantern(_ on: Bool) {
        perform("Lantern") { c in
            if try await c.writePath(LoraxPath.lantern, [on ? 1 : 0]) { c.status.lantern = on }
        }
    }

    func setBrightness(_ value: UInt8) {
        perform("Brightness") { c in
            if try await c.writePath(LoraxPath.ledBrightness, [value, value, value, value]) {
                c.status.brightness = value
            }
        }
    }

    private func perform(_ label: String, _ work: @escaping @MainActor (PuffcoController) async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch {
                self.lastError = "\(label) failed: \(error.localizedDescription)"
                self.appendLog(self.lastError ?? "")
            }
        }
    }

    // MARK: - Log

    func appendLog(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        log.append("\(stamp)  \(line)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    func clearLog() { log.removeAll() }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - Delegate handlers (main actor)

    private func handleStateUpdate(_ state: CBManagerState) {
        bluetoothState = state
        if state == .poweredOn {
            if lastDevice == nil,
               let idString = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
               let id = UUID(uuidString: idString) {
                lastDevice = central.retrievePeripherals(withIdentifiers: [id]).first
            }
            if !phase.isInSession { startScan() }
        } else {
            isScanning = false
            if phase.isInSession { teardown(phase: .failed("Bluetooth is unavailable.")) }
        }
    }

    private func handleDiscovery(_ p: CBPeripheral, advertisement: [String: Any], rssi: Int) {
        let advName = advertisement[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? p.name ?? "Unnamed device"
        let services = (advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisement[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let lower = name.lowercased()
        let likely = services.contains(Lorax.serviceUUID)
            || services.contains(Lorax.legacyServiceUUID)
            || Self.nameKeywords.contains { lower.contains($0) }

        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].rssi = rssi
            devices[i].lastSeen = Date()
            if advName != nil { devices[i].name = name }
            devices[i].isLikelyPuffco = devices[i].isLikelyPuffco || likely
        } else {
            devices.append(DiscoveredDevice(peripheral: p, name: name, rssi: rssi, isLikelyPuffco: likely, lastSeen: Date()))
        }
    }

    private func handleConnected(_ p: CBPeripheral) {
        guard p == peripheral else { return }
        appendLog("Connected. Discovering services…")
        p.discoverServices(nil) // all services: reading the protected ones makes iOS pair
    }

    private func handleDisconnected(_ p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        appendLog("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        if userDisconnected { return }
        // Keep the peripheral and ask iOS to reconnect whenever it comes back in range.
        resetSession()
        phase = .reconnecting
        central.connect(p, options: nil)
    }

    private func handleServices(_ p: CBPeripheral, error: Error?) {
        if let error { fail("Service discovery failed: \(error.localizedDescription)"); return }
        let services = p.services ?? []
        guard services.contains(where: { $0.uuid == Lorax.serviceUUID }) else {
            fail(PuffcoError.unsupportedFirmware.localizedDescription)
            return
        }
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    private func handleCharacteristics(_ p: CBPeripheral, service: CBService, error: Error?) {
        if let error { appendLog("Characteristic discovery error: \(error.localizedDescription)") }
        let chars = service.characteristics ?? []

        if service.uuid == Lorax.deviceInfoServiceUUID {
            for c in chars where [Lorax.modelNumberUUID, Lorax.serialNumberUUID, Lorax.firmwareUUID].contains(c.uuid) {
                p.readValue(for: c)
            }
            return
        }

        guard service.uuid == Lorax.serviceUUID else { return }
        for c in chars {
            switch c.uuid {
            case Lorax.commandUUID: commandChar = c
            case Lorax.replyUUID: replyChar = c
            case Lorax.versionUUID: versionChar = c
            case Lorax.eventUUID: eventChar = c
            default: break
            }
            appendLog("Char \(c.uuid.uuidString.prefix(8)): \(Self.describe(c.properties))")
        }
        guard let reply = replyChar, commandChar != nil else {
            fail("The device is missing the Lorax command/reply characteristics.")
            return
        }
        setupStep = "subscribe to replies"
        p.setNotifyValue(true, for: reply)
        if let event = eventChar { p.setNotifyValue(true, for: event) }
    }

    private static func describe(_ props: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if props.contains(.read) { parts.append("read") }
        if props.contains(.write) { parts.append("write") }
        if props.contains(.writeWithoutResponse) { parts.append("writeNoResp") }
        if props.contains(.notify) { parts.append("notify") }
        if props.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }

    private func handleWrite(uuid: CBUUID, error: Error?) {
        if let error, uuid == Lorax.commandUUID {
            appendLog("Write error: \(error.localizedDescription)")
        }
    }

    private func handleNotifyState(_ c: CBCharacteristic, error: Error?) {
        if c.uuid == Lorax.eventUUID {
            appendLog(error.map { "Event subscribe failed: \($0.localizedDescription)" } ?? "Subscribed to events")
            return
        }
        guard c.uuid == Lorax.replyUUID else { return }
        if let error {
            fail("Couldn't subscribe to replies: \(error.localizedDescription)")
            return
        }
        appendLog("Subscribed to replies")
        Task { await runSetup() }
    }

    private func handleValue(uuid: CBUUID, data value: Data?, error: Error?) {
        if let pending = pendingReads.removeValue(forKey: uuid) {
            if let error { pending.resume(throwing: error) } else { pending.resume(returning: value ?? Data()) }
            return
        }
        guard error == nil, let data = value else { return }

        switch uuid {
        case Lorax.replyUUID:
            handleReply(data)
        case Lorax.eventUUID:
            appendLog("EVENT: \([UInt8](data).hex)")
        case Lorax.modelNumberUUID:
            appendLog("GATT model: \([UInt8](data).hex)")
            if status.model == nil { status.model = Decode.string([UInt8](data)) }
        case Lorax.serialNumberUUID:
            if status.serial == nil { status.serial = Decode.string([UInt8](data)) }
        case Lorax.firmwareUUID:
            appendLog("GATT firmware: \([UInt8](data).hex)")
            if status.firmware == nil { status.firmware = Decode.string([UInt8](data)) }
        default:
            break
        }
    }
}

// MARK: - CoreBluetooth delegates
// Callbacks arrive on the main queue (we passed `queue: nil`); each one is forwarded to the main actor.

extension PuffcoController: CBCentralManagerDelegate {
    nonisolated func onMain(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        onMain { self.handleStateUpdate(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        onMain { self.handleDiscovery(peripheral, advertisement: advertisementData, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onMain { self.handleConnected(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = "Couldn't connect: \(error?.localizedDescription ?? "unknown error")"
        onMain { self.fail(message) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        onMain { self.handleDisconnected(peripheral, error: error) }
    }
}

extension PuffcoController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        onMain { self.handleServices(peripheral, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        onMain { self.handleCharacteristics(peripheral, service: service, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        onMain { self.handleNotifyState(characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Copy the value now: CoreBluetooth overwrites it on the next notification.
        let uuid = characteristic.uuid
        let value = characteristic.value
        onMain { self.handleValue(uuid: uuid, data: value, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        onMain { self.handleWrite(uuid: uuid, error: error) }
    }
}

// MARK: - AsyncGate

/// One Lorax request in flight at a time.
@MainActor
final class AsyncGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
