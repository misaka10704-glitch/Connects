import XCTest
@testable import Connects

final class ChatMessagePersistenceTests: XCTestCase {
    func testLegacySingleImageJSONMigratesIntoImageList() throws {
        let json = """
        {
          "id": "m-legacy",
          "role": "user",
          "content": "legacy",
          "createdAt": 978307200,
          "imageJPEGBase64": "bGVnYWN5"
        }
        """
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.imageJPEGBase64List, ["bGVnYWN5"])
        XCTAssertEqual(message.imageJPEGBase64, "bGVnYWN5")
        XCTAssertEqual(message.imageCount, 1)
        XCTAssertTrue(message.hasImage)
    }

    func testImageListRoundTripsWithoutDuplicatingLegacyKey() throws {
        let original = ChatMessage(
            id: "m-multi",
            role: .user,
            content: "multi",
            createdAt: Date(timeIntervalSince1970: 978307200),
            imageJPEGBase64List: ["Zmlyc3Q", "c2Vjb25k"]
        )

        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["imageJPEGBase64List"] as? [String], ["Zmlyc3Q", "c2Vjb25k"])
        XCTAssertNil(object["imageJPEGBase64"])

        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.imageJPEGBase64List, ["Zmlyc3Q", "c2Vjb25k"])
        XCTAssertEqual(decoded.allImageBase64, ["Zmlyc3Q", "c2Vjb25k"])
        XCTAssertEqual(decoded.imageCount, 2)
    }

    func testLegacyAccessorReplacesFirstAndNilClearsList() {
        var message = ChatMessage(
            role: .user,
            content: "multi",
            imageJPEGBase64List: ["one", "two"]
        )

        message.imageJPEGBase64 = "replacement"
        XCTAssertEqual(message.imageJPEGBase64List, ["replacement", "two"])

        message.imageJPEGBase64 = nil
        XCTAssertTrue(message.imageJPEGBase64List.isEmpty)
        XCTAssertFalse(message.hasImage)
    }
}
