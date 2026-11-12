import CSQLite
import CodexOneCore
import Foundation

extension SQLiteExecutionStore: AccountObservationStore {
  public func quotaObservation(id: String) async throws -> AccountQuotaObservation {
    guard ManagedAccount.validID(id) else { throw ExecutionError.invalidCommand }
    return try await perform { db in
      _ = try Self.loadAccount(db, id)
      return try Self.loadQuota(db, id)
    }
  }
  public func quotaCycleTrend(id: String) async throws -> AccountQuotaTrend {
    guard ManagedAccount.validID(id) else { throw ExecutionError.invalidCommand }
    guard
      quotaCycleReaderGate.withLock({ busy in
        if busy { return false }
        busy = true
        return true
      })
    else { throw ExecutionError.capacity }
    defer { quotaCycleReaderGate.withLock { $0 = false } }
    return try await perform { db in
      _ = try Self.loadAccount(db, id)
      let legacy = try Self.loadQuota(db, id).trend ?? AccountQuotaTrend()
      func load(_ kind: Int64, _ previous: QuotaWindowTrend?) throws -> QuotaWindowTrend? {
        let newest = try Self.latestQuotaCycle(db, account: id, kind: kind)
        guard let metadata = newest ?? previous else { return nil }
        let samples = try db.rows(
          """
          SELECT at_epoch, remaining FROM account_quota_cycle_samples
          WHERE account_id=? AND kind=? ORDER BY bucket_epoch LIMIT 105123
          """, [.text(id), .number(kind)]
        ) { row -> QuotaTrendSample in
          guard let raw = sqlite3_column_text(row, 1), let remaining = Double(String(cString: raw)),
            (0...100).contains(remaining)
          else { throw ExecutionError.storageUnavailable }
          return QuotaTrendSample(at: sqlite3_column_int64(row, 0), remaining: remaining)
        }
        guard samples.count <= 105122 else { throw ExecutionError.capacity }
        let all = samples.isEmpty ? metadata.samples : samples
        guard let last = all.last else { return metadata }
        let recent = all.filter { $0.at >= last.at - 86_400 }
        let width = max(Int64(300), (metadata.duration + 511) / 512)
        var segments: [[QuotaTrendSample]] = []
        var bucket: Int64?
        var bucketStart = 0
        var prior: QuotaTrendSample?
        var sampled = false
        for sample in all {
          if let prior, sample.at - prior.at > 900 {
            segments.append([])
            bucket = nil
          }
          if segments.isEmpty { segments.append([]) }
          let index = segments.count - 1
          let nextBucket = sample.at / width
          if bucket != nextBucket { bucketStart = segments[index].count }
          if bucket == nextBucket, segments[index].count - bucketStart >= 2 {
            segments[index].removeLast()
            sampled = true
          }
          segments[index].append(sample)
          bucket = nextBucket
          prior = sample
        }
        let omitted = segments.count > 1024
        if omitted {
          let count = segments.count
          segments = (0..<1024).map { segments[$0 * (count - 1) / 1023] }
        }
        return QuotaWindowTrend(
          reset: metadata.reset, duration: metadata.duration, samples: recent,
          historySegments: segments, historySampled: sampled, historyOmitted: omitted)
      }
      return try AccountQuotaTrend(
        primary: load(0, legacy.primary), secondary: load(1, legacy.secondary))
    }
  }
  public func creditHistory(id: String, from: Int64, through: Int64) async throws
    -> [[AccountCreditSample]]
  {
    guard ManagedAccount.validID(id), from > 0, through >= from,
      through - from <= 604_800
    else { throw ExecutionError.invalidCommand }
    return try await perform { db in
      _ = try Self.loadAccount(db, id)
      let samples = try db.rows(
        """
        SELECT at_epoch, balance FROM account_credit_samples
        WHERE account_id=? AND bucket_epoch BETWEEN ? AND ? AND at_epoch BETWEEN ? AND ?
        ORDER BY bucket_epoch
        """,
        [.text(id), .number(from / 300), .number(through / 300), .number(from), .number(through)]
      ) { row in
        AccountCreditSample(
          at: sqlite3_column_int64(row, 0),
          balance: String(cString: sqlite3_column_text(row, 1)))
      }
      var segments: [[AccountCreditSample]] = []
      var previousBucket: Int64?
      let fineSince = through - 86_400
      for sample in samples {
        guard SubscriptionUsageCredits.parseBalance(sample.balance) != nil else {
          throw ExecutionError.storageUnavailable
        }
        let bucket = sample.at / 300
        if let previousBucket, bucket == previousBucket + 1 {
          let index = segments.count - 1
          // Keep the endpoints of a continuous run, including a flat run within an hour.
          if sample.at < fineSince, segments[index].count > 1,
            let latest = segments[index].last, latest.at / 3600 == sample.at / 3600
          {
            segments[index].removeLast()
          }
          segments[index].append(sample)
        } else {
          segments.append([sample])
        }
        previousBucket = bucket
      }
      return segments
    }
  }
  public func recordQuotaObservation(
    account: ManagedAccount, atUnixSeconds: Int64,
    result: Result<SubscriptionQuota, QuotaObservationFailure>
  ) async throws -> AccountQuotaObservation {
    guard (1...1_000_000_000_000).contains(atUnixSeconds) else {
      throw ExecutionError.invalidCommand
    }
    if case .success(let quota) = result { try quota.validate() }
    return try await perform(optional: true) { db in
      try db.transaction {
        let current = try Self.loadAccount(db, account.id).account
        guard current.namespace == account.namespace,
          current.credentialVersion == account.credentialVersion
        else { throw ExecutionError.conflict }
        let old = try Self.loadQuota(db, account.id)
        var updated: AccountQuotaObservation
        var trend = old.trend ?? AccountQuotaTrend()
        switch result {
        case .success(let quota):
          guard current.authorization == .ready else { throw ExecutionError.conflict }
          updated = try .init(
            attemptedAtUnixSeconds: atUnixSeconds, observedAtUnixSeconds: atUnixSeconds,
            quota: quota, failure: nil)
          trend.record(quota, at: atUnixSeconds)
          try Self.recordQuotaCycle(
            db, account: account.id, kind: 0,
            previous: old.trend?.primary, current: trend.primary, at: atUnixSeconds)
          try Self.recordQuotaCycle(
            db, account: account.id, kind: 1,
            previous: old.trend?.secondary, current: trend.secondary, at: atUnixSeconds)
          if atUnixSeconds >= (old.attemptedAtUnixSeconds ?? 0) {
            if case .balance(let balance) = quota.usageCredits {
              try db.write(
                """
                INSERT INTO account_credit_samples
                SELECT ?,?,?,?
                WHERE NOT EXISTS (
                  SELECT 1 FROM account_credit_samples WHERE account_id=? AND bucket_epoch>?
                )
                ON CONFLICT(account_id,bucket_epoch) DO UPDATE
                SET at_epoch=excluded.at_epoch,balance=excluded.balance
                WHERE excluded.at_epoch >= account_credit_samples.at_epoch
                """,
                [
                  .text(account.id), .number(atUnixSeconds / 300), .number(atUnixSeconds),
                  .text(balance), .text(account.id), .number(atUnixSeconds / 300),
                ])
            }
            try db.write(
              "DELETE FROM account_credit_samples WHERE at_epoch<?",
              [.number(atUnixSeconds - 604_800)])
          }
        case .failure(let error):
          updated = try .init(
            attemptedAtUnixSeconds: atUnixSeconds, observedAtUnixSeconds: old.observedAtUnixSeconds,
            quota: old.quota, failure: error)
        }
        updated.trend = trend
        var record = try encode(updated)
        while record.utf8.count > 16_384 {
          updated.trend = trend.discardOldestHalf() ? trend : nil
          record = try encode(updated)
          if updated.trend == nil { break }
        }
        try db.write(
          "INSERT INTO account_quota VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET record_json=excluded.record_json",
          [.text(account.id), .text(record)])
        var priming = try Self.loadQuotaPriming(db, account.id)
        if !priming.windows.isEmpty {
          let enabled = priming.settings.enabled
          priming.observe(updated, now: db.clock.unixSeconds)
          if enabled && !priming.settings.enabled {
            try Self.bumpPrimingRevision(db, account.id)
          }
          try Self.saveQuotaPriming(db, account.id, priming)
        }
        return updated
      }
    }
  }
  private static func latestQuotaCycle(
    _ db: SQLiteConnection, account: String, kind: Int64
  ) throws -> QuotaWindowTrend? {
    let rows = try db.rows(
      """
      SELECT at_epoch, remaining, reset_epoch, duration_seconds FROM account_quota_cycle_samples
      WHERE account_id=? AND kind=? ORDER BY bucket_epoch DESC LIMIT 1
      """, [.text(account), .number(kind)]
    ) { row -> QuotaWindowTrend in
      guard let raw = sqlite3_column_text(row, 1), let remaining = Double(String(cString: raw)),
        (0...100).contains(remaining)
      else { throw ExecutionError.storageUnavailable }
      return QuotaWindowTrend(
        reset: sqlite3_column_int64(row, 2), duration: sqlite3_column_int64(row, 3),
        samples: [QuotaTrendSample(at: sqlite3_column_int64(row, 0), remaining: remaining)])
    }
    return rows.first
  }
  private static func recordQuotaCycle(
    _ db: SQLiteConnection, account: String, kind: Int64,
    previous: QuotaWindowTrend?, current: QuotaWindowTrend?, at: Int64
  ) throws {
    let stored = try latestQuotaCycle(db, account: account, kind: kind)
    let effectivePrevious = stored ?? previous
    let changed: Bool
    if let previous = effectivePrevious, let current, let last = previous.samples.last,
      let next = current.samples.last
    {
      changed =
        previous.reset <= at || abs(previous.reset - current.reset) > 60
        || previous.duration != current.duration || last.at > at || last.remaining < next.remaining
    } else {
      changed = true
    }
    if changed {
      try db.write(
        "DELETE FROM account_quota_cycle_samples WHERE account_id=? AND kind=?",
        [.text(account), .number(kind)])
    }
    guard let current, let latest = current.samples.last else { return }
    let anchor = changed ? current : (effectivePrevious ?? current)
    func insert(_ sample: QuotaTrendSample) throws {
      try db.write(
        """
        INSERT INTO account_quota_cycle_samples(account_id,kind,bucket_epoch,at_epoch,remaining,reset_epoch,duration_seconds)
        VALUES(?,?,?,?,?,?,?) ON CONFLICT(account_id,kind,bucket_epoch) DO UPDATE
        SET at_epoch=excluded.at_epoch,remaining=excluded.remaining,reset_epoch=excluded.reset_epoch,duration_seconds=excluded.duration_seconds
        WHERE excluded.at_epoch >= account_quota_cycle_samples.at_epoch
        """,
        [
          .text(account), .number(kind), .number(sample.at / 300), .number(sample.at),
          .text(String(sample.remaining)), .number(anchor.reset), .number(anchor.duration),
        ])
    }
    if !changed, stored == nil, let previous {
      for sample in previous.samples { try insert(sample) }
    }
    try insert(latest)
    try db.write(
      "DELETE FROM account_quota_cycle_samples WHERE account_id=? AND kind=? AND bucket_epoch<=? AND at_epoch<?",
      [
        .text(account), .number(kind), .number((anchor.reset - anchor.duration - 60) / 300),
        .number(anchor.reset - anchor.duration - 60),
      ])
  }
  private static func loadQuota(_ db: SQLiteConnection, _ id: String) throws
    -> AccountQuotaObservation
  {
    let records = try db.rows(
      "SELECT record_json FROM account_quota WHERE account_id=?", [.text(id)]
    ) {
      String(cString: sqlite3_column_text($0, 0))
    }
    guard let record = records.first else {
      return try .init(
        attemptedAtUnixSeconds: nil, observedAtUnixSeconds: nil, quota: nil, failure: nil)
    }
    let stored = try decode(AccountQuotaObservation.self, record)
    try stored.quota?.validate()
    var validated = try AccountQuotaObservation(
      attemptedAtUnixSeconds: stored.attemptedAtUnixSeconds,
      observedAtUnixSeconds: stored.observedAtUnixSeconds, quota: stored.quota,
      failure: stored.failure)
    validated.trend = stored.trend
    return validated
  }
}
