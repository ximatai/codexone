import Foundation
import Testing

@testable import CodexOneAdapters

let syntheticImagePNG = Data(
  base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQUDBgAAABBQBh3ab18QAAAABJRU5ErkJggg=="
)!

@Test func imageContainerAndMaskValidationRejectsTruncationCorruptionURLsAndOversizedDecodedData()
  throws
{
  let image = try ImagePayload(
    bytes: syntheticImagePNG, declaredType: "image/png", maximumBytes: 1024)
  #expect(image.width == 1 && image.height == 1 && image.hasAlpha)
  #expect(try ImagePayload(dataURL: image.dataURL, maximumBytes: 1024).bytes == image.bytes)
  try image.validateMask(for: image)
  for count in 0..<syntheticImagePNG.count {
    #expect(throws: (any Error).self) {
      try ImagePayload(bytes: Data(syntheticImagePNG.prefix(count)), maximumBytes: 1024)
    }
  }
  var corrupt = syntheticImagePNG
  corrupt[corrupt.count - 5] ^= 1
  #expect(throws: (any Error).self) { try ImagePayload(bytes: corrupt, maximumBytes: 1024) }
  #expect(throws: (any Error).self) {
    try ImagePayload(bytes: syntheticImagePNG, declaredType: "image/jpeg", maximumBytes: 1024)
  }
  #expect(throws: (any Error).self) { try ImagePayload(dataURL: image.dataURL, maximumBytes: 2) }
  #expect(throws: (any Error).self) {
    try ImagePayload(dataURL: "https://example.invalid/private.png", maximumBytes: 1024)
  }
  #expect(throws: (any Error).self) {
    try ImagePayload(dataURL: "data:image/svg+xml;base64,PHN2Zz4=", maximumBytes: 1024)
  }
  #expect(throws: (any Error).self) {
    try ImagePayload(dataURL: image.dataURL + "\n", maximumBytes: 1024)
  }
  #expect(throws: (any Error).self) {
    try ImagePayload(dataURL: image.dataURL, maximumBytes: Int.max)
  }
  var prefixed = Data([1, 2, 3])
  prefixed.append(syntheticImagePNG)
  #expect(try ImagePayload(bytes: prefixed.dropFirst(3), maximumBytes: 1024).width == 1)
}

@Test func realSyntheticJPEGAndWebPContainersRetainDeclaredDimensionsAndRejectWrongMasks() throws {
  for (name, type) in [("synthetic.jpg", "image/jpeg"), ("synthetic.webp", "image/webp")] {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/image-input")
    )
    let bytes = try Data(contentsOf: url)
    let image = try ImagePayload(bytes: bytes, declaredType: type, maximumBytes: 4096)
    #expect(image.width == 2 && image.height == 1 && image.mediaType == type)
    #expect(try ImagePayload(dataURL: image.dataURL, maximumBytes: 4096).bytes == bytes)
    let mask = try ImagePayload(bytes: syntheticImagePNG, maximumBytes: 1024)
    #expect(throws: (any Error).self) { try mask.validateMask(for: image) }
    for length in 0..<bytes.count {
      #expect(throws: (any Error).self) {
        try ImagePayload(bytes: Data(bytes.prefix(length)), maximumBytes: 4096)
      }
    }
  }
}
