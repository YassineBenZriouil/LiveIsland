import Foundation

/// What the island's cost and history pane shows, worked out from the ledgers' daily totals,
/// so the view only lays it out. The numbers are estimates at API list prices.
public struct UsageReport: Equatable, Sendable {
    /// One line of a breakdown: a model or a project over the whole period.
    public struct Slice: Equatable, Sendable, Identifiable {
        public var name: String
        public var cost: CostEstimate
        /// Fresh tokens (cache reads left out, as everywhere else in the island).
        public var tokens: Int
        /// Its part of the period, 0…1: by cost when anything was priced, else by tokens.
        public var share: Double

        public var id: String { name }

        public init(name: String, cost: CostEstimate, tokens: Int, share: Double) {
            (self.name, self.cost, self.tokens, self.share) = (name, cost, tokens, share)
        }
    }

    /// Each day's height for the sparkline, 0…1 against the busiest day, oldest first.
    public var trend: [Double]
    /// Whether `trend` follows the estimated cost (else fresh tokens: nothing had a price).
    public var trendIsCost: Bool
    public var cost: CostEstimate
    public var tokens: Int
    /// Days with any use, out of `trend.count`.
    public var activeDays: Int
    /// Biggest first, the rest folded into "Other".
    public var models: [Slice]
    public var projects: [Slice]

    /// - Parameter top: how many models and projects to name before "Other".
    public init(history days: [UsageDay], top: Int = 3) {
        var cost = CostEstimate()
        var tokens = 0
        for day in days {
            cost += day.cost
            tokens += day.counts.fresh
        }
        let byCost = cost.dollars > 0
        let values = days.map { byCost ? $0.cost.dollars : Double($0.counts.fresh) }
        self.trend = Self.levels(values)
        self.trendIsCost = byCost
        self.cost = cost
        self.tokens = tokens
        self.activeDays = days.filter { $0.requests > 0 }.count

        var buckets: [UsageBucket] = []
        for day in days { for bucket in day.buckets { UsageHistory.add(bucket, to: &buckets) } }
        let period = UsageDay(start: .distantPast, buckets: buckets)
        self.models = Self.slices(period.byModel, top: top, byCost: byCost, total: byCost ? cost.dollars : Double(tokens)) {
            $0.model.map(ModelName.short) ?? "Unknown model"
        }
        self.projects = Self.slices(period.byProject, top: top, byCost: byCost, total: byCost ? cost.dollars : Double(tokens)) {
            $0.project ?? "No project"
        }
    }

    public var isEmpty: Bool { activeDays == 0 }

    /// Values scaled to the largest, so the busiest day fills the sparkline. All zero stays zero.
    public static func levels(_ values: [Double]) -> [Double] {
        let peak = values.max() ?? 0
        guard peak > 0 else { return values.map { _ in 0 } }
        return values.map { max(0, $0) / peak }
    }

    /// Codex's daily tokens as sparkline heights, oldest first.
    public static func levels(codex days: [CodexUsageDay]) -> [Double] {
        levels(days.map { Double($0.tokens) })
    }

    private static func slices(_ groups: [UsageBucket], top: Int, byCost: Bool, total: Double,
                               name: (UsageBucket) -> String) -> [Slice] {
        func share(_ bucket: UsageBucket) -> Double {
            guard total > 0 else { return 0 }
            return (byCost ? bucket.cost.dollars : Double(bucket.counts.fresh)) / total
        }
        // A model or project with no use at all (only cache reads) isn't worth a line.
        let used = groups.filter { $0.counts.fresh > 0 || $0.cost.dollars > 0 }
        var named = used.prefix(top).map { Slice(name: name($0), cost: $0.cost, tokens: $0.counts.fresh, share: share($0)) }
        let rest = used.dropFirst(top)
        if !rest.isEmpty {
            var other = UsageBucket(model: nil, project: nil)
            for bucket in rest {
                other.counts += bucket.counts
                other.cost += bucket.cost
            }
            named.append(Slice(name: "Other", cost: other.cost, tokens: other.counts.fresh, share: share(other)))
        }
        return named
    }
}

/// Short names for model ids, for a line in a 200-point panel.
public enum ModelName {
    /// "claude-opus-4-5-20251101" → "Opus 4.5", "us.anthropic.claude-sonnet-4-5-20250929-v1:0" →
    /// "Sonnet 4.5", "claude-3-5-haiku-20241022" → "Haiku 3.5". Anything else (a proxy's own
    /// name) is kept as it is.
    public static func short(_ model: String) -> String {
        var name = model.lowercased()
        if let claude = name.range(of: "claude-") { name = String(name[claude.upperBound...]) } else { return model }
        // Drop what follows the version: "@date", "[1m]", ":0".
        if let cut = name.firstIndex(where: { "@[:".contains($0) }) { name = String(name[..<cut]) }
        let parts = name.split(separator: "-").map(String.init)
        guard let family = parts.firstIndex(where: { $0.first?.isLetter == true }) else { return model }
        // A version part is a short number; a date (8 digits) or "v1" ends it.
        let isVersion = { (part: String) in part.count <= 2 && part.allSatisfy(\.isNumber) }
        let before = parts[..<family].prefix(while: isVersion)
        let after = parts[(family + 1)...].prefix(while: isVersion)
        let version = (before.isEmpty ? after : before).joined(separator: ".")
        let title = parts[family].prefix(1).uppercased() + parts[family].dropFirst()
        return version.isEmpty ? title : "\(title) \(version)"
    }
}

extension Format {
    /// $0.42, $4.20, $38, $1.2K: an estimate, so cents only while they matter. Under a cent
    /// reads "<$0.01", not "$0.00" that looks like nothing was used.
    public static func dollars(_ value: Double) -> String {
        switch value {
        case ..<0.005: return value > 0 ? "<$0.01" : "$0"
        case ..<100: return String(format: "$%.2f", value)
        case ..<1_000: return String(format: "$%.0f", value)
        default:
            let thousands = (value / 100).rounded() / 10
            return thousands == thousands.rounded() ? String(format: "$%.0fK", thousands) : String(format: "$%.1fK", thousands)
        }
    }

    /// The estimate with a "+" when some replies had no known price, so it reads as at least that.
    public static func cost(_ estimate: CostEstimate) -> String {
        dollars(estimate.dollars) + (estimate.isComplete ? "" : "+")
    }
}
