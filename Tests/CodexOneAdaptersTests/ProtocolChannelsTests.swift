import NIOCore
import NIOEmbedded
import Testing

@testable import CodexOneAdapters

@Test func protocolChannelsBoundCandidatesAndReclaimFailedSlots() throws {
  let owner = ProtocolChannels(limit: 3)
  let candidates = (0..<4).map { _ in EmbeddedChannel() }
  defer { for channel in candidates { _ = try? channel.finish() } }
  for channel in candidates.prefix(3) { #expect(owner.register(channel)) }
  #expect(!owner.register(candidates[3]))
  // A failed candidate is reclaimed by closeFuture, not by an explicit release from the caller.
  try candidates[0].close().wait()
  candidates[0].embeddedEventLoop.run()
  #expect(owner.register(candidates[3]))
  owner.close()
  for channel in candidates { channel.embeddedEventLoop.run() }
  for channel in candidates { try channel.closeFuture.wait() }
  let late = EmbeddedChannel()
  defer { _ = try? late.finish() }
  #expect(!owner.register(late))
}
