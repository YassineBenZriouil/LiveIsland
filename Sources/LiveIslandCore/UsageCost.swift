import Foundation

/// Token use split the way Claude bills it. Cache reads are usually most of the total (each
/// reply re-reads the whole conversation from cache) but cost a tenth of fresh input or less,
/// so a single sum says little: keep the kinds apart.
public struct TokenCounts: Codable, Equatable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    /// Tokens written to the prompt cache, including `cacheWrite1h`.
    public var cacheWrite: Int
    /// The part of `cacheWrite` kept for an hour, which costs more than the 5-minute cache.
    public var cacheWrite1h: Int
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    public static let zero = TokenCounts()

    /// Everything, cache reads included.
    public var total: Int { input + output + cacheWrite + cacheRead }
    /// What the model newly read or wrote: everything but cache reads.
    public var fresh: Int { input + output + cacheWrite }
    /// The prompt's size, for long-context prices.
    public var context: Int { input + cacheWrite + cacheRead }
    public var isZero: Bool { total == 0 }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                    cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h, cacheRead: lhs.cacheRead + rhs.cacheRead)
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }

    /// The larger of each count. A reply is logged once per content block and the counts can
    /// grow from one line to the next (output streams in), so the largest is the real one.
    public func merged(with other: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(input, other.input), output: max(output, other.output), cacheWrite: max(cacheWrite, other.cacheWrite),
                    cacheWrite1h: max(cacheWrite1h, other.cacheWrite1h), cacheRead: max(cacheRead, other.cacheRead))
    }

    private enum CodingKeys: String, CodingKey {
        case input = "i", output = "o", cacheWrite = "w", cacheWrite1h = "h", cacheRead = "r"
    }
}

/// A model's list price in US dollars per million tokens. Cache writes follow Anthropic's rule
/// (1.25× input for 5 minutes, 2× for an hour); cache reads vary by model.
public struct ModelPrice: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    /// Prompts larger than this many tokens are billed at `longContext` instead.
    public var longContextThreshold: Int?
    public var longInput: Double?
    public var longOutput: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil,
                longContextThreshold: Int? = nil, longInput: Double? = nil, longOutput: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? input / 10
        self.longContextThreshold = longContextThreshold
        self.longInput = longInput
        self.longOutput = longOutput
    }

    /// The estimated cost of one reply.
    public func cost(of tokens: TokenCounts) -> Double {
        var input = self.input, output = self.output, cacheRead = self.cacheRead
        if let threshold = longContextThreshold, tokens.context > threshold, let longInput, let longOutput {
            cacheRead *= longInput / input
            input = longInput
            output = longOutput
        }
        let cacheWrite5m = max(0, tokens.cacheWrite - tokens.cacheWrite1h)
        let dollars = Double(tokens.input) * input + Double(tokens.output) * output + Double(tokens.cacheRead) * cacheRead
            + Double(cacheWrite5m) * input * 1.25 + Double(tokens.cacheWrite1h) * input * 2
        return dollars / 1_000_000
    }
}

/// List prices for Claude models, to estimate what token use would cost on the API. It's an
/// estimate: subscriptions don't bill per token, and prices change. Unknown models (a proxy's
/// own names) have no price rather than a guessed one.
public enum ModelPrices {
    /// Model id prefixes, matched on whole name parts so "claude-opus-4" doesn't catch "claude-opus-4-5".
    static let table: [(model: String, price: ModelPrice)] = [
        ("claude-fable-5-2", ModelPrice(input: 8, output: 40, cacheRead: 0.20)),
        ("claude-mythos-5-2", ModelPrice(input: 8, output: 40, cacheRead: 0.20)),
        ("claude-fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", ModelPrice(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", ModelPrice(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-preview", ModelPrice(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-8", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-7", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-6", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-5", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-1", ModelPrice(input: 15, output: 75)),
        ("claude-opus-4", ModelPrice(input: 15, output: 75)),
        ("claude-3-opus", ModelPrice(input: 15, output: 75)),
        ("claude-sonnet-5-5", ModelPrice(input: 2, output: 10, cacheRead: 0.10)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10)),
        ("claude-sonnet-4-6", ModelPrice(input: 3, output: 15)),
        ("claude-sonnet-4-5", ModelPrice(input: 3, output: 15, longContextThreshold: 200_000, longInput: 6, longOutput: 22.5)),
        ("claude-sonnet-4", ModelPrice(input: 3, output: 15, longContextThreshold: 200_000, longInput: 6, longOutput: 22.5)),
        ("claude-3-7-sonnet", ModelPrice(input: 3, output: 15)),
        ("claude-3-5-sonnet", ModelPrice(input: 3, output: 15)),
        ("claude-haiku-5-5", ModelPrice(input: 0.10, output: 0.50, longContextThreshold: 100_000, longInput: 0.50, longOutput: 2.50)),
        ("claude-haiku-4-5", ModelPrice(input: 1, output: 5)),
        ("claude-3-5-haiku", ModelPrice(input: 0.80, output: 4)),
        ("claude-3-haiku", ModelPrice(input: 0.25, output: 1.25, cacheRead: 0.03)),
    ]

    /// The price of a model id as Claude Code logs it, also under Bedrock or Vertex names
    /// ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-opus-4-5@20251101").
    public static func price(for model: String) -> ModelPrice? {
        let name = model.lowercased()
        var best: (length: Int, price: ModelPrice)?
        for entry in table where entry.model.count > (best?.length ?? 0) {
            guard let range = name.range(of: entry.model) else { continue }
            // The id must end there or carry on with a new part (a date, a version, "[1m]").
            if range.upperBound < name.endIndex, !"-@[.:_ ".contains(name[range.upperBound]) { continue }
            best = (entry.model.count, entry.price)
        }
        return best?.price
    }

    public static func cost(of tokens: TokenCounts, model: String?) -> Double? {
        guard let model, let price = price(for: model) else { return nil }
        return price.cost(of: tokens)
    }
}

/// What some replies would have cost at list prices. Replies whose model has no known price
/// are counted apart rather than guessed, so the UI can say the estimate is partial.
public struct CostEstimate: Codable, Equatable, Hashable, Sendable {
    public var dollars: Double
    public var unpricedRequests: Int

    public init(dollars: Double = 0, unpricedRequests: Int = 0) {
        self.dollars = dollars
        self.unpricedRequests = unpricedRequests
    }

    /// Whether every reply was priced.
    public var isComplete: Bool { unpricedRequests == 0 }

    public mutating func add(_ tokens: TokenCounts, model: String?) {
        if let cost = ModelPrices.cost(of: tokens, model: model) {
            dollars += cost
        } else if !tokens.isZero {
            unpricedRequests += 1
        }
    }

    public static func += (lhs: inout CostEstimate, rhs: CostEstimate) {
        lhs.dollars += rhs.dollars
        lhs.unpricedRequests += rhs.unpricedRequests
    }

    private enum CodingKeys: String, CodingKey { case dollars = "d", unpricedRequests = "u" }
}
