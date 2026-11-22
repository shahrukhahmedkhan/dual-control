import Foundation

/// D12e: what the model relay's API use costs, and the owner's monthly budget for it. The relay reads the `usage`
/// fields Anthropic returns (`message_start.message.usage` and `message_delta.usage` in a stream, `usage` in a JSON
/// answer), prices them with the table below and refuses new requests once the month's spend reaches the budget.
/// Prices are conservative on purpose: each model family at its most expensive current model, cache writes at the
/// 1-hour rate, unknown models at the top tier, plus a margin. The request that crosses the budget still finishes.
public struct ModelPrice: Sendable, Equatable {
    /// US dollars per million input tokens.
    public let input: Double
    /// US dollars per million output tokens.
    public let output: Double
}

/// The price table, in US dollars per million tokens (Anthropic's first-party prices, 2026-10).
public enum ModelPrices {
    /// Added on top of every cost, for prices that change and for regional inference.
    public static let margin = 1.1
    /// Cache writes, as a multiple of the input price (the 1-hour cache; 5-minute writes cost 1.25x).
    public static let cacheWrite = 2.0
    /// Cache reads, as a multiple of the input price.
    public static let cacheRead = 0.1
    /// Fast mode, as a multiple of everything.
    public static let fast = 2.0
    /// The most expensive tier, for Fable, Mythos and any model not in the table.
    public static let top = ModelPrice(input: 10, output: 50)
    /// Families by the word in the model name: the most expensive current model of each.
    static let families: [(String, ModelPrice)] = [
        ("opus", ModelPrice(input: 5, output: 25)),
        ("sonnet", ModelPrice(input: 3, output: 15)),
        ("haiku", ModelPrice(input: 1, output: 5)),
    ]

    /// The price used for `model`.
    public static func price(for model: String) -> ModelPrice {
        let lowered = model.lowercased()
        guard lowered.hasPrefix("claude-") else { return top }
        return families.first { lowered.contains($0.0) }?.1 ?? top
    }
}

/// The tokens one answer used, from its `usage` fields.
public struct RelayUsage: Sendable, Equatable {
    /// `input_tokens`: uncached input.
    public var inputTokens = 0
    /// `output_tokens`.
    public var outputTokens = 0
    /// `cache_creation_input_tokens`.
    public var cacheCreationTokens = 0
    /// `cache_read_input_tokens`.
    public var cacheReadTokens = 0
    /// `usage.speed` was "fast".
    public var fast = false

    /// Usage.
    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        fast: Bool = false
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.fast = fast
    }

    /// What it costs at `model`'s price, in US dollars, margin included.
    public func cost(model: String) -> Double {
        let price = ModelPrices.price(for: model)
        let tokens =
            Double(inputTokens) * price.input + Double(outputTokens) * price.output
            + Double(cacheCreationTokens) * price.input * ModelPrices.cacheWrite
            + Double(cacheReadTokens) * price.input * ModelPrices.cacheRead
        return tokens / 1_000_000 * ModelPrices.margin * (fast ? ModelPrices.fast : 1)
    }

    var summary: String {
        "tokens in \(inputTokens), out \(outputTokens), cache write \(cacheCreationTokens), read \(cacheReadTokens)"
            + (fast ? ", fast" : "")
    }
}

/// Reads `usage` out of an answer as it streams past, line by line, without keeping the answer: each server-sent
/// `data:` line, or a JSON answer (kept up to `maxPlainBody` to read at the end). Each field keeps its largest value,
/// since `message_delta` counts are running totals.
public struct UsageScanner: Sendable {
    /// The longest line read; longer ones (large text deltas) are skipped.
    public static let maxLine = 64 << 10
    /// The most of a non-stream answer kept.
    public static let maxPlainBody = 4 << 20

    private var line: [UInt8] = []
    private var skipping = false
    private var plain: [UInt8] = []
    private var sawEvents = false
    private var usage: RelayUsage?

    /// A scanner.
    public init() {}

    /// The next bytes of the answer.
    public mutating func feed(_ bytes: [UInt8]) {
        if plain.count < Self.maxPlainBody { plain += bytes.prefix(Self.maxPlainBody - plain.count) }
        for byte in bytes {
            if byte == 0x0A {
                if !skipping { take(line) }
                line.removeAll(keepingCapacity: true)
                skipping = false
            } else if !skipping {
                line.append(byte)
                if line.count > Self.maxLine {
                    skipping = true
                    line.removeAll()
                }
            }
        }
    }

    /// The usage found, or `nil` if the answer had none.
    public mutating func finish() -> RelayUsage? {
        if !skipping { take(line) }
        line = []
        if !sawEvents, let object = try? JSONSerialization.jsonObject(with: Data(plain)) as? [String: Any] {
            merge(object["usage"])
        }
        return usage
    }

    private mutating func take(_ line: [UInt8]) {
        guard line.starts(with: Array("data:".utf8)) else { return }
        sawEvents = true
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5))) as? [String: Any]
        else { return }
        merge(object["usage"])
        merge((object["message"] as? [String: Any])?["usage"])
    }

    private mutating func merge(_ value: Any?) {
        guard let fields = value as? [String: Any] else { return }
        var merged = usage ?? RelayUsage()
        func count(_ name: String) -> Int { (fields[name] as? NSNumber)?.intValue ?? 0 }
        merged.inputTokens = max(merged.inputTokens, count("input_tokens"))
        merged.outputTokens = max(merged.outputTokens, count("output_tokens"))
        merged.cacheCreationTokens = max(merged.cacheCreationTokens, count("cache_creation_input_tokens"))
        merged.cacheReadTokens = max(merged.cacheReadTokens, count("cache_read_input_tokens"))
        if fields["speed"] as? String == "fast" { merged.fast = true }
        usage = merged
    }
}

/// The owner's monthly budget for the model relay and this month's spend, in US dollars (the currency of
/// Anthropic's prices and of the Console's spend limits).
public struct RelayBudget: Sendable, Equatable, Codable {
    /// The largest budget accepted.
    public static let maxLimit = 10_000.0

    /// The budget per calendar month; `nil` means none.
    public var limit: Double?
    /// The month `spent` is for, `yyyy-MM`.
    public private(set) var month: String
    /// Spent this month.
    public private(set) var spent: Double = 0

    /// A budget for `month`.
    public init(limit: Double?, month: String) {
        self.limit = limit
        self.month = month
    }

    /// `yyyy-MM` of `date` in `timeZone`.
    public static func monthKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Why `limit` cannot be a budget, or `nil`.
    public static func limitProblem(_ limit: Double) -> String? {
        limit > 0 && limit <= maxLimit && limit.isFinite ? nil : "the budget must be more than $0 and at most $10,000"
    }

    /// Spent in `month` (zero for a month not yet started).
    public func spent(in month: String) -> Double { month == self.month ? spent : 0 }

    /// Why a new request may not go upstream in `month`, or `nil`.
    public func refusal(month: String) -> String? {
        guard let limit, spent(in: month) >= limit else { return nil }
        return String(
            format: "the owner's monthly model budget of $%.2f is used up ($%.2f spent this month)",
            limit,
            spent(in: month)
        )
    }

    /// Adds `cost` to `month`'s spend, starting the month afresh if it is a new one.
    public mutating func add(_ cost: Double, month: String) {
        if month != self.month {
            self.month = month
            spent = 0
        }
        spent += max(cost, 0)
    }
}
