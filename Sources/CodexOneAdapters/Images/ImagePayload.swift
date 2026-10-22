import Foundation

/// Opaque image bytes with checked container structure and declared raster bounds.
/// No local raster decoding, metadata extraction, network fetch, or persistent copy.
struct ImagePayload: Sendable {
  let bytes: Data
  let mediaType: String
  let width: Int
  let height: Int
  let hasAlpha: Bool
  init(dataURL: String, maximumBytes: Int) throws {
    guard (1...50_000_000).contains(maximumBytes), let comma = dataURL.firstIndex(of: ","),
      dataURL[..<comma].utf8.count <= 32,
      ["data:image/png;base64", "data:image/jpeg;base64", "data:image/webp;base64"].contains(
        String(dataURL[..<comma]))
    else { throw GatewayProtocolError(400, "invalid_image") }
    let payload = dataURL[dataURL.index(after: comma)...]
    guard payload.utf8.count <= (maximumBytes + 2) / 3 * 4 else {
      throw GatewayProtocolError(413, "image_too_large")
    }
    guard let bytes = Data(base64Encoded: String(payload)), bytes.base64EncodedString() == payload
    else {
      throw GatewayProtocolError(400, "invalid_image")
    }
    let declared = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma])
      .replacingOccurrences(of: ";base64", with: "")
    try self.init(bytes: bytes, declaredType: declared, maximumBytes: maximumBytes)
  }
  init(bytes: Data, declaredType: String? = nil, maximumBytes: Int) throws {
    guard (1...50_000_000).contains(maximumBytes), bytes.count <= maximumBytes else {
      throw GatewayProtocolError(413, "image_too_large")
    }
    let bytes = bytes.startIndex == 0 ? bytes : Data(bytes)
    let info: (String, Int, Int, Bool)
    if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
      let value = try Self.png(bytes)
      info = ("image/png", value.0, value.1, value.2)
    } else if bytes.starts(with: [255, 216]) {
      let value = try Self.jpeg(bytes)
      info = ("image/jpeg", value.0, value.1, false)
    } else if bytes.count >= 12, bytes.prefix(4) == Data("RIFF".utf8),
      bytes[8..<12] == Data("WEBP".utf8)
    {
      let value = try Self.webp(bytes)
      info = ("image/webp", value.0, value.1, value.2)
    } else {
      throw GatewayProtocolError(400, "unsupported_image_format")
    }
    guard
      declaredType == nil || declaredType == "application/octet-stream" || declaredType == info.0,
      (1...16384).contains(info.1), (1...16384).contains(info.2),
      info.1 <= 64_000_000 / info.2
    else { throw GatewayProtocolError(400, "invalid_image_dimensions") }
    self.bytes = bytes
    mediaType = info.0
    width = info.1
    height = info.2
    hasAlpha = info.3
  }
  func validateMask(for first: ImagePayload) throws {
    guard mediaType == "image/png", hasAlpha, width == first.width, height == first.height else {
      throw GatewayProtocolError(400, "invalid_image_mask")
    }
  }
  var dataURL: String { "data:" + mediaType + ";base64," + bytes.base64EncodedString() }

  private static func integer(_ bytes: Data, _ offset: Int, _ count: Int, little: Bool = false)
    -> Int
  {
    var result = 0
    for index in 0..<count {
      result = result * 256 + Int(bytes[offset + (little ? count - index - 1 : index)])
    }
    return result
  }
  private static let crcTable: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
    return crc
  }
  private static func crc(_ bytes: Data, from start: Int, to end: Int) throws -> UInt32 {
    var value = UInt32.max
    for offset in start..<end {
      if offset % 16384 == 0 { try Task.checkCancellation() }
      value = crcTable[Int((value ^ UInt32(bytes[offset])) & 255)] ^ (value >> 8)
    }
    return value ^ UInt32.max
  }
  private static func png(_ bytes: Data) throws -> (Int, Int, Bool) {
    var offset = 8
    var width = 0
    var height = 0
    var alpha = false
    var idat = false
    var endedIDAT = false
    var paletteEntries = 0
    var color: UInt8 = 0
    var transparency = false
    var dataBytes = 0
    while offset <= bytes.count - 12 {
      let size = integer(bytes, offset, 4)
      guard size <= bytes.count - offset - 12 else {
        throw GatewayProtocolError(400, "invalid_image")
      }
      let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
      guard
        bytes[(offset + 4)..<(offset + 8)].allSatisfy({
          (65...90).contains($0) || (97...122).contains($0)
        }),
        (65...90).contains(bytes[offset + 6]),
        try crc(bytes, from: offset + 4, to: offset + 8 + size)
          == UInt32(integer(bytes, offset + 8 + size, 4))
      else { throw GatewayProtocolError(400, "invalid_image") }
      if offset == 8 && type != "IHDR" { throw GatewayProtocolError(400, "invalid_image") }
      switch type {
      case "IHDR":
        guard offset == 8, size == 13 else { throw GatewayProtocolError(400, "invalid_image") }
        width = integer(bytes, offset + 8, 4)
        height = integer(bytes, offset + 12, 4)
        let depth = bytes[offset + 16]
        color = bytes[offset + 17]
        let depths: [UInt8: Set<UInt8>] = [
          0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16],
        ]
        guard depths[color]?.contains(depth) == true, bytes[offset + 18] == 0,
          bytes[offset + 19] == 0, bytes[offset + 20] <= 1
        else { throw GatewayProtocolError(400, "invalid_image") }
        alpha = color == 4 || color == 6
      case "PLTE":
        guard !idat, paletteEntries == 0, ![0, 4].contains(color), size > 0, size <= 768,
          size % 3 == 0
        else {
          throw GatewayProtocolError(400, "invalid_image")
        }
        paletteEntries = size / 3
      case "tRNS":
        guard !idat, !transparency,
          (color == 0 && size == 2) || (color == 2 && size == 6)
            || (color == 3 && size > 0 && size <= paletteEntries)
        else { throw GatewayProtocolError(400, "invalid_image") }
        transparency = true
        alpha = true
      case "IDAT":
        guard !endedIDAT, color != 3 || paletteEntries > 0 else {
          throw GatewayProtocolError(400, "invalid_image")
        }
        idat = true
        dataBytes += size
      case "IEND":
        guard size == 0, idat, dataBytes > 0, offset + 12 == bytes.count else {
          throw GatewayProtocolError(400, "invalid_image")
        }
        return (width, height, alpha)
      case "acTL", "fcTL", "fdAT": throw GatewayProtocolError(400, "animated_image_unsupported")
      default:
        guard bytes[offset + 4] >= 97 else {
          throw GatewayProtocolError(400, "unsupported_image_format")
        }
      }
      if idat && type != "IDAT" { endedIDAT = true }
      offset += 12 + size
    }
    throw GatewayProtocolError(400, "invalid_image")
  }
  private static func jpeg(_ bytes: Data) throws -> (Int, Int) {
    guard bytes.count >= 4, bytes.suffix(2) == Data([255, 217]) else {
      throw GatewayProtocolError(400, "invalid_image")
    }
    var offset = 2
    var dimensions: (Int, Int)?
    while offset < bytes.count - 2 {
      guard bytes[offset] == 255 else { throw GatewayProtocolError(400, "invalid_image") }
      while offset < bytes.count && bytes[offset] == 255 { offset += 1 }
      guard offset < bytes.count else { throw GatewayProtocolError(400, "invalid_image") }
      let marker = bytes[offset]
      offset += 1
      guard marker != 0, marker != 216, marker != 217, !(208...215).contains(marker),
        offset <= bytes.count - 2
      else { throw GatewayProtocolError(400, "invalid_image") }
      let size = integer(bytes, offset, 2)
      guard size >= 2, size <= bytes.count - offset else {
        throw GatewayProtocolError(400, "invalid_image")
      }
      if [192, 193, 194].contains(marker) {
        guard dimensions == nil, size >= 8, bytes[offset + 2] == 8,
          (1...4).contains(bytes[offset + 7]), size == 8 + Int(bytes[offset + 7]) * 3
        else { throw GatewayProtocolError(400, "invalid_image") }
        dimensions = (integer(bytes, offset + 5, 2), integer(bytes, offset + 3, 2))
      }
      if marker == 218 {
        guard let dimensions, size >= 6, offset + size < bytes.count - 2 else {
          throw GatewayProtocolError(400, "invalid_image")
        }
        return dimensions
      }
      offset += size
    }
    throw GatewayProtocolError(400, "invalid_image")
  }
  private static func webp(_ bytes: Data) throws -> (Int, Int, Bool) {
    guard integer(bytes, 4, 4, little: true) == bytes.count - 8 else {
      throw GatewayProtocolError(400, "invalid_image")
    }
    var offset = 12
    var canvas: (Int, Int, Bool)?
    var raster: (Int, Int, Bool)?
    while offset <= bytes.count - 8 {
      let type = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
      let size = integer(bytes, offset + 4, 4, little: true)
      guard size <= bytes.count - offset - 8 else {
        throw GatewayProtocolError(400, "invalid_image")
      }
      let start = offset + 8
      switch type {
      case "VP8X":
        guard offset == 12, size == 10, bytes[start] & 2 == 0 else {
          throw GatewayProtocolError(400, "animated_image_unsupported")
        }
        canvas = (
          integer(bytes, start + 4, 3, little: true) + 1,
          integer(bytes, start + 7, 3, little: true) + 1, bytes[start] & 16 != 0
        )
      case "VP8 ":
        guard raster == nil, size >= 10, bytes[start] & 1 == 0,
          bytes[(start + 3)..<(start + 6)] == Data([157, 1, 42])
        else { throw GatewayProtocolError(400, "invalid_image") }
        raster = (
          integer(bytes, start + 6, 2, little: true) & 16383,
          integer(bytes, start + 8, 2, little: true) & 16383, canvas?.2 ?? false
        )
      case "VP8L":
        guard raster == nil, size >= 5, bytes[start] == 47 else {
          throw GatewayProtocolError(400, "invalid_image")
        }
        let packed = integer(bytes, start + 1, 4, little: true)
        guard packed >> 29 == 0 else { throw GatewayProtocolError(400, "invalid_image") }
        raster = ((packed & 16383) + 1, ((packed >> 14) & 16383) + 1, packed & (1 << 28) != 0)
      case "ANIM", "ANMF": throw GatewayProtocolError(400, "animated_image_unsupported")
      default: break
      }
      offset += 8 + size + size % 2
    }
    guard offset == bytes.count, let raster,
      canvas.map({ $0.0 == raster.0 && $0.1 == raster.1 }) ?? true
    else { throw GatewayProtocolError(400, "invalid_image") }
    return raster
  }
}
