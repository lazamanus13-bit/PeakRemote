import XCTest
@testable import PeakRemote

/// Expected values were generated with the Python reference implementations
/// (puffco-py `calculate_lorax_auth_token` / `pack_lorax_*`, and PuffcoBLE `_make_key`),
/// which agree with each other.
final class LoraxTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    func testHandshakeKeyMatchesBase64() {
        XCTAssertEqual(Lorax.handshakeKey, [UInt8](Data(base64Encoded: "ZMZFYlbyb1scoSc3pd1x+w==")!))
    }

    func testAuthToken() {
        let seed = Array(UInt8(0x10)...UInt8(0x1F))
        XCTAssertEqual(Lorax.authToken(seed: seed)?.hex, "c5418b9b4884d5a0dcd4b6bd8306b85e")
        XCTAssertNil(Lorax.authToken(seed: [1, 2, 3]))
    }

    func testCommandPackets() {
        XCTAssertEqual([UInt8](Lorax.command(seq: 1, opcode: .getAccessSeed)).hex, "010000")

        let token = bytes("c5418b9b4884d5a0dcd4b6bd8306b85e")
        XCTAssertEqual([UInt8](Lorax.command(seq: 2, opcode: .unlockAccess, body: token)).hex,
                       "020001c5418b9b4884d5a0dcd4b6bd8306b85e")

        let read = Lorax.command(seq: 3, opcode: .readShort,
                                 body: Lorax.readShortBody(path: "/p/app/stat/id", size: 1))
        XCTAssertEqual([UInt8](read).hex, "030010000001002f702f6170702f737461742f6964")

        let write = Lorax.command(seq: 4, opcode: .writeShort,
                                  body: Lorax.writeShortBody(path: "/p/app/mc", value: [ModeCommand.heatStart.rawValue]))
        XCTAssertEqual([UInt8](write).hex, "0400110000002f702f6170702f6d630007")
    }

    func testSequenceIsLittleEndian() {
        XCTAssertEqual([UInt8](Lorax.command(seq: 0x1234, opcode: .readShort)).hex, "341210")
    }

    func testParseReply() {
        let reply = Lorax.parseReply(Data(bytes("0300002a")))
        XCTAssertEqual(reply, Lorax.Reply(seq: 3, status: 0, payload: [0x2A]))
        XCTAssertEqual(Lorax.parseReply(Data([0x05, 0x00, 0x00]))?.payload, [])
        XCTAssertNil(Lorax.parseReply(Data([0x01, 0x00])))
    }

    func testTemperature() {
        // float32 232.2 °C (= 450 °F in puffco-py's parse_temp)
        let c = Decode.temperatureC(bytes("33336843"))!
        XCTAssertEqual(Temp.f(fromC: c), 450, accuracy: 0.1)
        // int32 tenths of °C (Proxy): 2650 → 265.0
        XCTAssertEqual(Decode.temperatureC(Encode.uint32(2650))!, 265, accuracy: 0.001)
        XCTAssertNil(Decode.temperatureC([0, 0]))
    }

    func testSecondsEncodingDetection() {
        let asFloat = Decode.seconds(Encode.float32(45))!
        XCTAssertEqual(asFloat.value, 45)
        XCTAssertTrue(asFloat.isFloat)

        let asInt = Decode.seconds(Encode.uint32(45))!
        XCTAssertEqual(asInt.value, 45)
        XCTAssertFalse(asInt.isFloat)
    }

    func testBattery() {
        XCTAssertEqual(Decode.battery([87]), 87)
        XCTAssertEqual(Decode.battery(Encode.float32(64.6)), 65)
        XCTAssertEqual(Decode.battery(Encode.uint32(42)), 42)
        XCTAssertEqual(Decode.battery(Encode.uint32(8700)), 87)
    }

    func testCount() {
        XCTAssertEqual(Decode.count(Encode.uint32(1234)), 1234)
        XCTAssertEqual(Decode.count(Encode.float32(1234)), 1234)
        XCTAssertEqual(Decode.count([0x10, 0x27]), 10_000)
    }

    func testString() {
        XCTAssertEqual(Decode.string(Array("Daily".utf8) + [0, 0, 0]), "Daily")
        XCTAssertNil(Decode.string([0, 0]))
    }
}
