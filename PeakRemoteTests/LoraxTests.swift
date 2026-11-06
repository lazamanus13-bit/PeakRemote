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

    func testRevisionString() {
        // Matches PuffcoBLE's revision_number_to_string
        XCTAssertEqual(PuffcoInfo.revisionString(0), "X*")
        XCTAssertEqual(PuffcoInfo.revisionString(1), "A")
        XCTAssertEqual(PuffcoInfo.revisionString(9), "J")
        XCTAssertEqual(PuffcoInfo.revisionString(21), "Z")
        XCTAssertEqual(PuffcoInfo.revisionString(22), "AA")
        XCTAssertEqual(PuffcoInfo.revisionString(43), "BA")
    }

    func testSolidColorPayloadMatchesPythonCBOR() {
        // cbor2.dumps({'lamp': {'name': 'solid', 'param': {'color': b'\\xff\\x00\\x00'}}}, canonical=True)
        XCTAssertEqual(PeakColor.solidPayload(r: 0xFF, g: 0, b: 0).hex,
                       "a1646c616d70a2646e616d6565736f6c696465706172616da165636f6c6f7243ff0000")
        XCTAssertEqual(PeakColor.solidPayload(r: 0x12, g: 0xAB, b: 0xEF).hex,
                       "a1646c616d70a2646e616d6565736f6c696465706172616da165636f6c6f724312abef")
    }

    func testColorRoundTrip() {
        let payload = PeakColor.solidPayload(r: 1, g: 2, b: 3)
        let c = PeakColor.firstColor(in: payload)
        XCTAssertEqual(c?.0, 1); XCTAssertEqual(c?.1, 2); XCTAssertEqual(c?.2, 3)
        XCTAssertNil(PeakColor.firstColor(in: [0xFF, 0x00]))
    }

    func testReadyModeOffEncoding() {
        // The official app writes 4294967295 into a float32 register for "off".
        XCTAssertEqual(Encode.float32(4_294_967_295).hex, "0000804f")
    }

    func testApi2ColorFormat() {
        // Matches the official app's RgbtColor.fromRgb / fromNull byte layouts.
        XCTAssertEqual(PeakColor.api2Solid(r: 0x12, g: 0x34, b: 0x56), [0x12, 0x34, 0x56, 0, 0, 0, 0, 0])
        XCTAssertEqual(PeakColor.api2None, [0, 0, 0, 255, 0, 0, 0, 0])
        XCTAssertEqual(PeakColorFormat.detect(PeakColor.api2Solid(r: 1, g: 2, b: 3)), .api2)
        XCTAssertEqual(PeakColorFormat.detect(PeakColor.solidPayload(r: 1, g: 2, b: 3)), .api3)
        let c = PeakColor.firstColor(in: [9, 8, 7, 0, 0, 0, 0, 0])
        XCTAssertEqual(c?.0, 9); XCTAssertEqual(c?.1, 8); XCTAssertEqual(c?.2, 7)
        XCTAssertNil(PeakColor.firstColor(in: PeakColor.api2None))
    }

    func testVaporLevels() {
        // Values from the official app's Vapor table.
        XCTAssertEqual(VaporLevel.standard.rawValue, 0)
        XCTAssertEqual(VaporLevel.high.rawValue, 0.5)
        XCTAssertEqual(VaporLevel.max.rawValue, 1)
        XCTAssertEqual(VaporLevel.xl.rawValue, 1.5)
        XCTAssertEqual(VaporLevel.nearest(0.49), .high)
        XCTAssertEqual(VaporLevel.nearest(1.6), .xl)
    }

    func testLightEffectInColor() {
        // Breathing (LumaAnimation 5) goes in byte 4 of the 8-byte color.
        let bytes = PeakColor.payload(RGB(r: 255, g: 0, b: 128), format: .api2, effect: .breathing)
        XCTAssertEqual(bytes, [255, 0, 128, 0, 5, 0, 0, 0])
        XCTAssertEqual(PeakColor.effect(in: bytes), .breathing)
        XCTAssertNil(PeakColor.effect(in: PeakColor.api2None))
        XCTAssertEqual(LightEffect.circlingSlow.rawValue, 21)
    }
}
