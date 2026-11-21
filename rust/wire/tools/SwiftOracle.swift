import Foundation

// The real wire source only needs these two members of the transport error.
struct GatewayProtocolError: Error {
  let code: String
  init(_ status: Int, _ code: String) { self.code = code }
}

@main struct SwiftOracle {
  static func main() throws {
    let arguments = CommandLine.arguments.dropFirst()
    let mode = arguments.first!
    let options = arguments.dropFirst()
    while let line = readLine(), let data = Data(base64Encoded: line) {
      if mode == "json" {
        do {
          let value = try JSONValue.decode(data, rejectingDuplicateRootKeys: Set(options))
          print(try value.data(escapingSlashes: false).base64EncodedString())
        } catch let error as GatewayProtocolError {
          print(error.code)
        } catch {
          print("invalid_json")
        }
      } else {
        let limits = Array(options)
        var decoder = SSEDecoder(
          maximumEventBytes: Int(limits[1])!, maximumTotalBytes: Int(limits[2])!)
        var output: [String] = []
        var consumed = 0
        do {
          for byte in data {
            consumed += 1
            if let value = try decoder.append(byte) {
              output.append(try value.data().base64EncodedString())
            }
          }
          try decoder.finish()
        } catch let error as GatewayProtocolError {
          if error.code == "upstream_response_too_large" { consumed -= 1 }
          output.append(error.code)
        }
        print(
          output.joined(separator: ","), decoder.sawDone, decoder.isAtEventBoundary, consumed,
          separator: "|")
      }
    }
  }
}
