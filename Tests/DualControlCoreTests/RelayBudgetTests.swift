import Foundation
import Testing

@testable import DualControlCore

private func scan(_ chunks: [String]) -> RelayUsage? {
    var scanner = UsageScanner()
    for chunk in chunks { scanner.feed(Array(chunk.utf8)) }
    return scanner.finish()
}

// MARK: - Prices

@Test func eachFamilyIsPricedAtItsMostExpensiveModelAndUnknownModelsAtTheTop() {
    #expect(ModelPrices.price(for: "claude-opus-5-5") == ModelPrice(input: 5, output: 25))
    #expect(ModelPrices.price(for: "claude-opus-4-6") == ModelPrice(input: 5, output: 25))
    #expect(ModelPrices.price(for: "claude-sonnet-5-5") == ModelPrice(input: 3, output: 15))
    #expect(ModelPrices.price(for: "claude-haiku-5-5") == ModelPrice(input: 1, output: 5))
    #expect(ModelPrices.price(for: "claude-fable-5-1") == ModelPrice(input: 10, output: 50))
    #expect(ModelPrices.price(for: "claude-mythos-5-1") == ModelPrice(input: 10, output: 50))
    #expect(ModelPrices.price(for: "something-new") == ModelPrice(input: 10, output: 50))
    #expect(ModelPrices.price(for: "?") == ModelPrice(input: 10, output: 50))
}

@Test func costCountsEveryKindOfTokenWithAMargin() {
    // 1M input at $5 + 1M output at $25 + 1M cache writes at 2x input + 1M cache reads at 0.1x input = $40.50.
    let usage = RelayUsage(
        inputTokens: 1_000_000,
        outputTokens: 1_000_000,
        cacheCreationTokens: 1_000_000,
        cacheReadTokens: 1_000_000
    )
    #expect(abs(usage.cost(model: "claude-opus-5-5") - 40.5 * ModelPrices.margin) < 1e-9)
    var fast = usage
    fast.fast = true
    #expect(abs(fast.cost(model: "claude-opus-5-5") - 2 * usage.cost(model: "claude-opus-5-5")) < 1e-9)
    #expect(RelayUsage().cost(model: "claude-opus-5-5") == 0)
}

// MARK: - Usage

@Test func streamedUsageIsReadFromMessageStartAndTheLastMessageDelta() {
    let usage = scan([
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":120,",
        "\"cache_creation_input_tokens\":30,\"cache_read_input_tokens\":400,\"output_tokens\":1}}}\n\n",
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"usage\"}}\n\n",
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":15}}\n\n",
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":250}}\n\n",
    ])
    #expect(usage == RelayUsage(inputTokens: 120, outputTokens: 250, cacheCreationTokens: 30, cacheReadTokens: 400))
}

@Test func aPlainJSONAnswerAndFastModeAreRead() {
    let usage = scan([#"{"id":"m","usage":{"input_tokens":10,"output_tokens":"#, #"20,"speed":"fast"}}"#])
    #expect(usage == RelayUsage(inputTokens: 10, outputTokens: 20, fast: true))
}

@Test func answersWithoutUsageHaveNone() {
    #expect(scan([#"{"input_tokens": 512}"#]) == nil)
    #expect(scan(["event: ping\ndata: {}\n\n"]) == nil)
    #expect(scan([]) == nil)
}

@Test func aLineTooLongIsSkippedNotBuffered() {
    var scanner = UsageScanner()
    scanner.feed(Array(("data: " + String(repeating: "x", count: UsageScanner.maxLine + 10)).utf8))
    scanner.feed(Array("\ndata: {\"usage\":{\"output_tokens\":3}}\n".utf8))
    #expect(scanner.finish() == RelayUsage(outputTokens: 3))
}

// MARK: - The budget

@Test func theBudgetRefusesAtTheCapAndStartsAgainEachMonth() {
    var budget = RelayBudget(limit: 5, month: "2026-11")
    #expect(budget.refusal(month: "2026-11") == nil)
    budget.add(4.99, month: "2026-11")
    #expect(budget.refusal(month: "2026-11") == nil)
    budget.add(0.02, month: "2026-11")
    let refusal = budget.refusal(month: "2026-11")
    #expect(refusal?.contains("$5.00") == true && refusal?.contains("monthly") == true)
    // A new month starts at zero.
    #expect(budget.refusal(month: "2026-12") == nil)
    budget.add(1, month: "2026-12")
    #expect(budget.month == "2026-12" && abs(budget.spent - 1) < 1e-9)
    // No limit, no refusal.
    var open = RelayBudget(limit: nil, month: "2026-11")
    open.add(1000, month: "2026-11")
    #expect(open.refusal(month: "2026-11") == nil)
    #expect(
        RelayBudget.monthKey(Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "UTC")!)
            == "2027-01"
    )
}

@Test func theBudgetIsSavedAndRestored() throws {
    var budget = RelayBudget(limit: 5, month: "2026-11")
    budget.add(1.25, month: "2026-11")
    let restored = try JSONDecoder().decode(RelayBudget.self, from: JSONEncoder().encode(budget))
    #expect(restored == budget)
    #expect(RelayBudget.limitProblem(0) != nil && RelayBudget.limitProblem(-1) != nil)
    #expect(RelayBudget.limitProblem(10_001) != nil && RelayBudget.limitProblem(5) == nil)
}

// MARK: - Audit

@Test func eachExchangeIsAuditedWithItsUsageAndCost() {
    var supervisor = Supervisor()
    let exchange = ModelRelayExchange(
        number: 3,
        path: "/v1/messages",
        model: "claude-opus-5-5",
        status: 200,
        bytesUp: 10,
        bytesDown: 20,
        duration: 1,
        refusal: nil,
        usage: RelayUsage(inputTokens: 2000, outputTokens: 1000)
    )
    supervisor.recordModelRelay(exchange, now: Date())
    supervisor.recordRelayBudget(limit: 5, now: Date())
    let lines = supervisor.drainAuditLines()
    #expect(lines.contains { $0.contains("tokens in 2000, out 1000, cache write 0, read 0; $0.0385") })
    #expect(lines.contains { $0.contains("model relay monthly budget: $5.00") })
}
