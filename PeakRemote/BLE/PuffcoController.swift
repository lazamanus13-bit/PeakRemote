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

    private var nextSeq: UInt16 = 0
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
        setupStarted = false
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
            if let v = versionChar {
                do {
                    let data = try await readCharacteristic(v, timeout: 45)
                    appendLog("Version char: \([UInt8](data).hex)")
                } catch {
                    appendLog("Version read failed (continuing): \(error.localizedDescription)")
                }
            }

            phase = .authenticating
            try await authenticate()

            phase = .ready
            appendLog("Unlocked ✓")
            await refreshProfiles()
            await pollSlow()
            await pollFast()
            startPolling()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func authenticate() async throws {
        let seedReply = try await send(.getAccessSeed)
        appendLog("Seed (status \(seedReply.status)): \(seedReply.payload.hex)")
        guard let token = Lorax.authToken(seed: seedReply.payload) else { throw PuffcoError.authFailed }
        let unlock = try await send(.unlockAccess, body: token)
        appendLog("Unlock status: \(unlock.status)")

        // Confirm by reading something that requires access.
        let state = try await readPath(LoraxPath.operatingState, size: 1)
        guard let raw = state.first else { throw PuffcoError.authFailed }
        status.state = OperatingState(raw: raw)
    }

    // MARK: - Lorax request / reply

    private func send(_ opcode: Lorax.Opcode, body: [UInt8] = [], timeout: Double = 2.5) async throws -> Lorax.Reply {
        await gate.acquire()
        defer { gate.release() }

        guard let p = peripheral, p.state == .connected, let cmd = commandChar else {
            throw PuffcoError.notConnected
        }

        nextSeq = nextSeq &+ 1
        if nextSeq == 0 { nextSeq = 1 }
        let seq = nextSeq
        let packet = Lorax.command(seq: seq, opcode: opcode, body: body)
        let writeType: CBCharacteristicWriteType =
            cmd.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

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
        guard let reply = Lorax.parseReply(data) else { return }
        if let c = pendingReplies.removeValue(forKey: reply.seq) {
            c.resume(returning: reply)
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
        } catch {
            handlePollError(error)
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
                status.profiles[slot] = profile
            }
            if let b = try await readOptional(LoraxPath.activeProfile, size: 1), let i = b.first, i < 4 {
                status.activeProfile = Int(i)
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

    func saveProfile(slot: Int, tempC: Double, durationS: Double) {
        perform("Save profile") { c in
            let profile = c.status.profiles[slot]
            try await c.writePath(LoraxPath.profileTemp(slot), Encode.float32(Float(tempC)))
            let seconds = durationS.rounded()
            let timeBytes = profile.durationIsFloat ? Encode.float32(Float(seconds)) : Encode.uint32(UInt32(seconds))
            try await c.writePath(LoraxPath.profileTime(slot), timeBytes)
            await c.refreshProfiles()
        }
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
        p.discoverServices([Lorax.serviceUUID, Lorax.deviceInfoServiceUUID])
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
            default: break
            }
        }
        guard let reply = replyChar, commandChar != nil else {
            fail("The device is missing the Lorax command/reply characteristics.")
            return
        }
        p.setNotifyValue(true, for: reply)
    }

    private func handleNotifyState(_ c: CBCharacteristic, error: Error?) {
        guard c.uuid == Lorax.replyUUID else { return }
        if let error {
            fail("Couldn't subscribe to replies: \(error.localizedDescription)")
            return
        }
        appendLog("Subscribed to replies")
        Task { await runSetup() }
    }

    private func handleValue(_ c: CBCharacteristic, error: Error?) {
        if let pending = pendingReads.removeValue(forKey: c.uuid) {
            if let error { pending.resume(throwing: error) } else { pending.resume(returning: c.value ?? Data()) }
            return
        }
        guard error == nil, let data = c.value else { return }

        switch c.uuid {
        case Lorax.replyUUID:
            handleReply(data)
        case Lorax.modelNumberUUID:
            status.model = Decode.string([UInt8](data))
        case Lorax.serialNumberUUID:
            if status.serial == nil { status.serial = Decode.string([UInt8](data)) }
        case Lorax.firmwareUUID:
            status.firmware = Decode.string([UInt8](data))
        default:
            break
        }
    }
}

// MARK: - CoreBluetooth delegates
// Callbacks arrive on the main queue (we passed `queue: nil`), so hop onto the main actor synchronously.

extension PuffcoController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { self.handleStateUpdate(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { self.handleDiscovery(peripheral, advertisement: advertisementData, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.handleConnected(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = "Couldn't connect: \(error?.localizedDescription ?? "unknown error")"
        MainActor.assumeIsolated { self.fail(message) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { self.handleDisconnected(peripheral, error: error) }
    }
}

extension PuffcoController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { self.handleServices(peripheral, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { self.handleCharacteristics(peripheral, service: service, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { self.handleNotifyState(characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { self.handleValue(characteristic, error: error) }
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
