import Foundation

/// Who a login belongs to: for Claude Code, from the `oauthAccount` object it keeps in
/// `~/.claude.json`; for Codex, from its `auth.json` (`CodexLogin`).
public struct ClaudeAccountIdentity: Codable, Equatable, Sendable {
    public var accountUUID: String
    public var email: String
    public var name: String?
    public var organizationUUID: String?
    public var organizationName: String?
    /// "default_claude_max_20x", …
    public var tier: String?

    public init(accountUUID: String, email: String, name: String? = nil, organizationUUID: String? = nil,
                organizationName: String? = nil, tier: String? = nil) {
        self.accountUUID = accountUUID
        self.email = email
        self.name = name
        self.organizationUUID = organizationUUID
        self.organizationName = organizationName
        self.tier = tier
    }

    /// One person can have the same email in a personal and a team organization.
    public var key: String { ClaudeAccountIdentity.key(email: email, organization: organizationUUID) }

    public static func key(email: String, organization: String?) -> String {
        email.lowercased() + "|" + (organization ?? "")
    }

    /// Claude's tiers name Claude ("default_claude_max_20x") or start with "default_"; anything
    /// else is a ChatGPT plan. A Claude tier LiveIsland doesn't know never reads as one.
    public var plan: String? {
        guard let tier else { return nil }
        return ClaudePlan.isClaudeTier(tier) ? ClaudePlan.label(tier: tier) : CodexPlan.label(planType: tier)
    }

    /// What to call the account: the person's name when Claude has one, else the email.
    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return email
    }

    public static func parse(_ oauthAccount: Data) -> ClaudeAccountIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: oauthAccount) as? [String: Any],
              let uuid = object["accountUuid"] as? String, let email = object["emailAddress"] as? String
        else { return nil }
        let name = (object["displayName"] as? String) ?? (object["fullName"] as? String)
        return ClaudeAccountIdentity(accountUUID: uuid, email: email, name: name,
                                     organizationUUID: object["organizationUuid"] as? String,
                                     organizationName: object["organizationName"] as? String,
                                     tier: (object["organizationRateLimitTier"] as? String) ?? (object["userRateLimitTier"] as? String))
    }
}

public enum ClaudePlan {
    /// "default_claude_max_20x" → "Max 20x".
    public static func label(tier: String?) -> String? {
        guard let tier = tier?.lowercased() else { return nil }
        if tier.contains("max") {
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
            return "Max"
        }
        if tier.contains("enterprise") { return "Enterprise" }
        if tier.contains("team") { return "Team" }
        if tier.contains("pro") { return "Pro" }
        return unknownLabel(tier)
    }

    /// Claude's rate limit tiers, as `~/.claude.json` names them.
    public static func isClaudeTier(_ tier: String) -> Bool {
        let tier = tier.lowercased()
        return tier.contains("claude") || tier.hasPrefix("default_")
    }

    /// A tier Claude adds later ("default_claude_ultra" -> "Ultra"): its own words, without
    /// the ones every tier shares. Nil when nothing is left ("default_claude_ai"), rather
    /// than a made-up plan name.
    static func unknownLabel(_ tier: String) -> String? {
        let filler: Set<String> = ["default", "claude", "ai", "tier", "rate", "limit"]
        let words = tier.lowercased().split { $0 == "_" || $0 == "-" || $0 == " " }.map(String.init).filter { !filler.contains($0) }
        guard !words.isEmpty else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// `~/.claude.json` edits that leave every byte outside the edited value as it was:
/// Claude Code owns the file, so LiveIsland only ever swaps its `oauthAccount` object.
public enum ClaudeConfigFile {
    /// The raw JSON text of a top-level key's value.
    public static func value(of key: String, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let range = topLevelValueRange(of: key, in: bytes) else { return nil }
        return Data(bytes[range])
    }

    /// The file with a top-level key's value replaced by `value` (raw JSON text), or the key
    /// added at the end when it's missing. Nil when the file isn't a JSON object.
    public static func replacingValue(of key: String, in data: Data, with value: Data) -> Data? {
        let bytes = [UInt8](data)
        if let range = topLevelValueRange(of: key, in: bytes) {
            return Data(bytes[..<range.lowerBound]) + value + Data(bytes[range.upperBound...])
        }
        // Missing (logged out): add it before the closing brace.
        guard let close = bytes.lastIndex(where: { !isWhitespace($0) }), bytes[close] == UInt8(ascii: "}"),
              let open = bytes.firstIndex(where: { !isWhitespace($0) }), bytes[open] == UInt8(ascii: "{")
        else { return nil }
        let isEmpty = bytes[(open + 1)..<close].allSatisfy(isWhitespace)
        var end = close
        while end > open + 1, isWhitespace(bytes[end - 1]) { end -= 1 }
        let entry = Data((isEmpty ? "\n  " : ",\n  ").utf8) + Data("\"\(key)\": ".utf8) + value + Data("\n".utf8)
        return Data(bytes[..<end]) + entry + Data(bytes[close...])
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    /// Walks only the top level of the object, skipping nested values whole, so a key of the
    /// same name inside another object never matches.
    static func topLevelValueRange(of key: String, in bytes: [UInt8]) -> Range<Int>? {
        var index = 0
        func skipWhitespace() { while index < bytes.count, isWhitespace(bytes[index]) { index += 1 } }
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
        index += 1
        let wanted = Array(key.utf8)
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let keyEnd = endOfString(bytes, from: index) else { return nil }
            let name = bytes[(index + 1)..<keyEnd]
            index = keyEnd + 1
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            skipWhitespace()
            let start = index
            guard let end = endOfValue(bytes, from: index) else { return nil }
            if name.elementsEqual(wanted) { return start..<end }
            index = end
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ",") else { return nil }
            index += 1
        }
    }

    /// The index of the closing quote of the string starting at `start`.
    private static func endOfString(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): return index
            default: index += 1
            }
        }
        return nil
    }

    /// One past the end of the value starting at `start`.
    private static func endOfValue(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return endOfString(bytes, from: start).map { $0 + 1 }
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    guard let end = endOfString(bytes, from: index) else { return nil }
                    index = end
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            return nil
        default:
            var index = start
            while index < bytes.count, !isWhitespace(bytes[index]),
                  bytes[index] != UInt8(ascii: ","), bytes[index] != UInt8(ascii: "}"), bytes[index] != UInt8(ascii: "]") {
                index += 1
            }
            return index
        }
    }
}

/// The Claude account part of Claude Code's credential item. The same item also holds the
/// logins of the user's MCP servers, which must survive an account switch untouched.
public enum ClaudeLogin {
    public static let key = "claudeAiOauth"

    public static func extract(from credentials: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any] else { return nil }
        return object[key] as? [String: Any]
    }

    /// The credential item with only the Claude login replaced. ASCII-only, as Claude Code
    /// reads the item back with `security -w`, which hex-encodes anything else.
    public static func replacing(in credentials: Data, with login: [String: Any]) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any] else { return nil }
        object[key] = login
        return asciiJSON(object)
    }

    /// When the access token and the login itself expire. Claude Code stores milliseconds.
    public static func expiry(of login: [String: Any]) -> (access: Date?, login: Date?) {
        func date(_ value: Any?) -> Date? {
            guard let number = value as? Double, number > 0 else { return nil }
            return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
        }
        return (date(login["expiresAt"]), date(login["refreshTokenExpiresAt"]))
    }

    /// JSON with every non-ASCII character escaped, so `security -w` prints it as text.
    public static func asciiJSON(_ object: Any) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for unit in text.utf16 {
            if unit < 0x80 {
                escaped.unicodeScalars.append(Unicode.Scalar(unit)!)
            } else {
                escaped += String(format: "\\u%04x", unit)
            }
        }
        return Data(escaped.utf8)
    }
}

/// What LiveIsland remembers about each account: no secrets (those stay in the Keychain),
/// just who it is and its limits when last seen.
public struct AccountBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var identity: ClaudeAccountIdentity
        public var fiveHour: RateLimitWindow?
        public var sevenDay: RateLimitWindow?
        public var limitsObservedAt: Date?
        /// LiveIsland keeps a copy of this account's login, so it can switch to it.
        public var hasSavedLogin: Bool
        /// When the saved login stops working and needs a fresh /login.
        public var loginExpiresAt: Date?

        public init(identity: ClaudeAccountIdentity, hasSavedLogin: Bool = false) {
            self.identity = identity
            self.hasSavedLogin = hasSavedLogin
        }
    }

    public var entries: [String: Entry] = [:]
    public var activeKey: String?
    /// When the active account last changed; nil when LiveIsland never saw it change.
    public var activeSince: Date?

    public init() {
        version = Self.currentVersion
    }

    /// Notes the account Claude Code is logged in to now.
    public mutating func setActive(_ identity: ClaudeAccountIdentity, at now: Date) {
        if entries[identity.key] == nil {
            entries[identity.key] = Entry(identity: identity)
        } else {
            entries[identity.key]!.identity = identity
        }
        guard activeKey != identity.key else { return }
        if activeKey != nil { activeSince = now }
        activeKey = identity.key
    }

    /// Files the status line's limits under the account they belong to: the one whose reset
    /// times they match (every account's windows reset at their own times), or else the
    /// account in use, when the session that reported them started after the latest switch.
    /// A session reads the login when it starts and can keep it as long as it runs, so a
    /// report from an older session could be any account's: it waits. Returns false when the
    /// report can't be placed yet.
    @discardableResult
    public mutating func record(_ limits: ClaudeUsageLimits, sessionStartedAt: Date?) -> Bool {
        let matching = entries.filter { Self.sameWindows($0.value, limits) }.map(\.key)
        if let owner = owner(among: matching, sessionStartedAt: sessionStartedAt) {
            store(limits, in: owner)
            return true
        }
        guard let key = activeKey, entries[key] != nil,
              Self.belongsToActive(sessionStartedAt: sessionStartedAt, activeSince: activeSince)
        else { return false }
        store(limits, in: key)
        return true
    }

    /// A request Claude refused for a limit: that account is out of room until the notice's
    /// reset time. It's the only news an exhausted account ever gives, as it never answers.
    /// Placed by the same rules as the status line's reports.
    /// Only the 5-hour and weekly limits count: a model's own weekly limit ("seven_day_opus")
    /// leaves the other models working, and filing it as a 5-hour one would invent a 5-hour
    /// limit for a plan that has none.
    public mutating func record(_ notice: ClaudeLimitNotice, sessionStartedAt: Date?) {
        let minutes: Int
        switch notice.type {
        case "five_hour": minutes = 300
        case "seven_day": minutes = 10_080
        default: return
        }
        let window = RateLimitWindow(usedPercent: 100, windowMinutes: minutes, resetsAt: notice.resetsAt)
        let matching = entries.filter { entry in
            let known = window.windowMinutes == 300 ? entry.value.fiveHour : entry.value.sevenDay
            return Self.sameReset(known?.resetsAt, notice.resetsAt)
        }.map(\.key)
        let owner = owner(among: matching, sessionStartedAt: sessionStartedAt)
        let active = Self.belongsToActive(sessionStartedAt: sessionStartedAt, activeSince: activeSince) ? activeKey : nil
        guard let key = owner ?? active, entries[key] != nil else { return }
        if let seen = entries[key]!.limitsObservedAt, seen > notice.observedAt { return }
        if window.windowMinutes == 300 { entries[key]!.fiveHour = window } else { entries[key]!.sevenDay = window }
        entries[key]!.limitsObservedAt = notice.observedAt
    }

    /// Readings made before version 2 were placed by "a request went out after the switch",
    /// which a session still on the previous login breaks. They may be another account's.
    public static let currentVersion = 2
    public var version: Int?

    public mutating func migrate(now: Date) {
        guard (version ?? 1) < Self.currentVersion else { return }
        for key in entries.keys {
            entries[key]!.fiveHour = nil
            entries[key]!.sevenDay = nil
            entries[key]!.limitsObservedAt = nil
        }
        // Sessions already running may be on any account; only new ones count.
        if activeSince == nil, entries.count > 1 { activeSince = now }
        version = Self.currentVersion
    }

    private mutating func store(_ limits: ClaudeUsageLimits, in key: String) {
        if let seen = entries[key]!.limitsObservedAt, seen > limits.observedAt { return }
        entries[key]!.fiveHour = limits.fiveHour
        entries[key]!.sevenDay = limits.sevenDay
        entries[key]!.limitsObservedAt = limits.observedAt
    }

    /// Which of the accounts whose reset times a reading matches it belongs to. Windows reset
    /// on the hour, so two accounts can share one: the account in use wins when the session
    /// started after the latest switch (then it's certainly that login), else the account
    /// read most recently, as the one still being used. The key settles a last tie, so the
    /// answer never depends on a dictionary's order.
    func owner(among keys: [String], sessionStartedAt: Date?) -> String? {
        if let activeKey, keys.contains(activeKey),
           Self.belongsToActive(sessionStartedAt: sessionStartedAt, activeSince: activeSince) {
            return activeKey
        }
        return keys.max { lhs, rhs in
            let left = entries[lhs]?.limitsObservedAt ?? .distantPast, right = entries[rhs]?.limitsObservedAt ?? .distantPast
            return left != right ? left < right : lhs > rhs
        }
    }

    /// The entry a switcher's row stands for. claude-swap leaves the organization out for
    /// personal accounts and ccswap never gives one, so the email decides, and when one email
    /// has several entries (a personal and a team organization), the closest wins: the same
    /// organization, else one that no other row of that email claims; then one without an
    /// organization, one whose plan fits the row (a team's for a row with an organization,
    /// a person's without), one as active as the row is, and the key last, so the pick never
    /// depends on a dictionary's order.
    func entry(email: String, organization: String?, isActive: Bool, claimedOrganizations: Set<String>) -> Entry? {
        let candidates = entries.filter { _, entry in
            guard entry.identity.email.caseInsensitiveCompare(email) == .orderedSame else { return false }
            guard let theirs = entry.identity.organizationUUID else { return true }
            if let organization { return theirs == organization }
            return !claimedOrganizations.contains(theirs)
        }
        func rank(_ key: String, _ entry: Entry) -> [Int] {
            let organizational: Set<String> = ["Team", "Enterprise", "Business", "Edu"]
            return [entry.identity.organizationUUID == organization ? 0 : 1,
                    entry.identity.organizationUUID == nil ? 0 : 1,
                    organizational.contains(entry.identity.plan ?? "") == (organization != nil) ? 0 : 1,
                    (key == activeKey) == isActive ? 0 : 1]
        }
        return candidates.min { lhs, rhs in
            let left = rank(lhs.key, lhs.value), right = rank(rhs.key, rhs.value)
            return left != right ? left.lexicographicallyPrecedes(right) : lhs.key < rhs.key
        }?.value
    }

    /// Whether a session uses the account in use now: only certain when it started after the
    /// latest switch. With no switch ever seen, there's just the one account.
    public static func belongsToActive(sessionStartedAt: Date?, activeSince: Date?) -> Bool {
        guard let activeSince else { return true }
        guard let started = sessionStartedAt else { return false }
        return started > activeSince
    }

    /// Same reset times for every window both sides know: the same account. Reset times move
    /// only when a window starts over, and two accounts sharing both is vanishingly unlikely.
    static func sameWindows(_ entry: Entry, _ limits: ClaudeUsageLimits) -> Bool {
        let pairs = [(entry.fiveHour?.resetsAt, limits.fiveHour?.resetsAt), (entry.sevenDay?.resetsAt, limits.sevenDay?.resetsAt)]
            .filter { $0.0 != nil && $0.1 != nil }
        return !pairs.isEmpty && pairs.count == [limits.fiveHour?.resetsAt, limits.sevenDay?.resetsAt].compactMap { $0 }.count
            && pairs.allSatisfy { sameReset($0.0, $0.1) }
    }

    static func sameReset(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) <= 90
    }

    /// Readings that ended up under two accounts: keep the newest, clear the others.
    public mutating func removeDuplicateReadings() {
        let read = entries.filter { $0.value.limitsObservedAt != nil }
        for (key, entry) in read {
            let limits = ClaudeUsageLimits(fiveHour: entry.fiveHour, sevenDay: entry.sevenDay, observedAt: entry.limitsObservedAt!)
            let newer = read.contains { other in
                other.key != key && Self.sameWindows(other.value, limits)
                    && (other.value.limitsObservedAt! > entry.limitsObservedAt! || (other.value.limitsObservedAt! == entry.limitsObservedAt! && other.key == activeKey))
            }
            if newer {
                entries[key]!.fiveHour = nil
                entries[key]!.sevenDay = nil
                entries[key]!.limitsObservedAt = nil
            }
        }
    }

    public mutating func remove(_ key: String) {
        guard key != activeKey else {
            entries[key]?.hasSavedLogin = false
            return
        }
        entries[key] = nil
    }
}

/// An account as the island shows it, whatever it came from.
public struct ClaudeAccount: Identifiable, Equatable, Sendable {
    public enum Switcher: String, Codable, Sendable {
        case liveIsland
        case claudeSwap
        /// ccswap, for Codex accounts.
        case ccswap
    }

    public var identity: ClaudeAccountIdentity
    public var kind: AgentKind
    public var isActive: Bool
    /// Nil when the account has no 5-hour limit (some plans have only the weekly ones), or
    /// when it was never read.
    public var fiveHour: RateLimitWindow?
    public var sevenDay: RateLimitWindow?
    /// Weekly limits of single models ("Fable"), as claude-swap reports them.
    public var models: [RateLimitWindow] = []
    public var limitsObservedAt: Date?
    /// How to switch to it; nil when it can't be switched to from here.
    public var switcher: Switcher?
    /// Its saved login expired: sign in to it again with /login.
    public var needsLogin: Bool
    public var claudeSwapNumber: Int?
    /// Its number in ccswap, for Codex accounts ccswap manages.
    public var ccswapNumber: Int?

    public var id: String { kind.rawValue + ":" + identity.key }

    public init(identity: ClaudeAccountIdentity, kind: AgentKind = .claude, isActive: Bool = false, fiveHour: RateLimitWindow? = nil,
                sevenDay: RateLimitWindow? = nil, limitsObservedAt: Date? = nil, switcher: Switcher? = nil,
                needsLogin: Bool = false, claudeSwapNumber: Int? = nil) {
        self.identity = identity
        self.kind = kind
        self.isActive = isActive
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limitsObservedAt = limitsObservedAt
        self.switcher = switcher
        self.needsLogin = needsLogin
        self.claudeSwapNumber = claudeSwapNumber
    }

    /// Windows that reset since they were seen count from zero again.
    public func current(at now: Date) -> ClaudeAccount {
        var account = self
        account.fiveHour = fiveHour?.current(at: now)
        account.sevenDay = sevenDay?.current(at: now)
        account.models = models.map { $0.current(at: now) }
        return account
    }

    /// Every limit it reports, in the order to show them: the 5-hour one only when it has one,
    /// the week, then each model's week.
    public var windows: [RateLimitWindow] { [fiveHour, sevenDay].compactMap { $0 } + models }

    /// The fuller of the two account-wide windows: what decides whether it can take more work.
    /// Without a 5-hour limit, that's the week alone. A model's own limit stops only that model.
    public var used: Double? {
        let values = [fiveHour?.usedPercent, sevenDay?.usedPercent].compactMap { $0 }
        return values.max()
    }

    public var isAtLimit: Bool { (used ?? 0) >= 100 }

    /// The window that ran out first, for "5-hour limit reached".
    public var exhaustedWindow: RateLimitWindow? {
        [fiveHour, sevenDay].compactMap { $0 }.first { $0.usedPercent >= 100 }
    }

    /// The account to move to next: one that can be switched to, with the most room left.
    /// Accounts never measured come last; one at 95% or more has no real room left.
    public static func best(_ accounts: [ClaudeAccount], at now: Date) -> ClaudeAccount? {
        accounts
            .filter { !$0.isActive && $0.switcher != nil && !$0.needsLogin }
            .map { $0.current(at: now) }
            .filter { ($0.used ?? 0) < 95 }
            .min { ($0.used ?? 99.5) < ($1.used ?? 99.5) }
    }
}

/// One account in claude-swap's `cswap list --json`.
public struct ClaudeSwapAccount: Equatable, Sendable {
    public var number: Int
    public var email: String
    public var organizationName: String?
    public var organizationUUID: String?
    public var isActive: Bool
    /// "ok", "relogin_required", "token_expired", …
    public var usageStatus: String
    /// Nil when the account has no 5-hour limit: claude-swap leaves `fiveHour` out then.
    public var fiveHour: RateLimitWindow?
    public var sevenDay: RateLimitWindow?
    public var usageFetchedAt: Date?
    public var isDisabled: Bool
    public var alias: String? = nil
    /// This account's own switch-away point, when it has one.
    public var threshold: Double? = nil
    public var loginExpiresAt: Date? = nil
    /// Why its usage couldn't be read, if so.
    public var usageError: String? = nil
    /// When it's expected to run out at its current pace, and whether it lasts to its reset.
    public var projectedExhaustionAt: Date? = nil
    public var willLastToReset: Bool? = nil
    /// Weekly limits of single models (`usage.scoped`).
    public var models: [RateLimitWindow] = []

    public var needsLogin: Bool { usageStatus == "relogin_required" || usageStatus == "token_expired" }
    public var name: String { alias ?? email }

    /// Every limit it reports, as `ClaudeAccount.windows` orders them.
    public var windows: [RateLimitWindow] { [fiveHour, sevenDay].compactMap { $0 } + models }

    /// Whether any of these accounts has a 5-hour limit; nil while none has been read. Each
    /// account can differ: some plans no longer have one.
    public static func anyHasFiveHourLimit(_ accounts: [ClaudeSwapAccount]) -> Bool? {
        if accounts.contains(where: { $0.fiveHour != nil }) { return true }
        return accounts.contains { $0.sevenDay != nil || !$0.models.isEmpty } ? false : nil
    }
}

/// claude-swap's JSON (schema version 1).
public enum ClaudeSwapJSON {
    public static func accounts(from data: Data) -> [ClaudeSwapAccount]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["accounts"] as? [[String: Any]]
        else { return nil }
        return rows.compactMap { row in
            guard let number = row["number"] as? Int, let email = row["email"] as? String else { return nil }
            let usage = row["usage"] as? [String: Any]
            return ClaudeSwapAccount(
                number: number, email: email,
                organizationName: (row["organizationName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                organizationUUID: (row["organizationUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isActive: row["active"] as? Bool ?? false,
                usageStatus: row["usageStatus"] as? String ?? "unavailable",
                fiveHour: window(usage?["fiveHour"], minutes: 300),
                sevenDay: window(usage?["sevenDay"], minutes: 10_080),
                usageFetchedAt: (row["usageFetchedAt"] as? String).flatMap(Format.date(iso8601:)),
                isDisabled: row["disabled"] as? Bool ?? false,
                alias: (row["alias"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                threshold: row["threshold"] as? Double,
                loginExpiresAt: (row["loginExpiresAt"] as? String).flatMap(Format.date(iso8601:)),
                usageError: row["usageError"] as? String,
                projectedExhaustionAt: ((usage?["sevenDay"] as? [String: Any])?["projectedExhaustionAt"] as? String).flatMap(Format.date(iso8601:)),
                willLastToReset: (usage?["sevenDay"] as? [String: Any])?["willLastToReset"] as? Bool,
                models: (usage?["scoped"] as? [Any] ?? []).compactMap { scoped in
                    guard let name = (scoped as? [String: Any])?["name"] as? String, !name.isEmpty else { return nil }
                    return window(scoped, minutes: 10_080, model: name)
                })
        }
    }

    private static func window(_ value: Any?, minutes: Int, model: String? = nil) -> RateLimitWindow? {
        guard let value = value as? [String: Any], let used = value["pct"] as? Double else { return nil }
        return RateLimitWindow(usedPercent: used, windowMinutes: minutes,
                               resetsAt: (value["resetsAt"] as? String).flatMap(Format.date(iso8601:)), model: model)
    }

    /// `cswap switch … --json`: whether it switched, and what it said (or the error).
    public static func switchResult(from data: Data) -> (switched: Bool, message: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] {
            return (false, error["message"] as? String ?? "claude-swap couldn't switch")
        }
        guard let switched = object["switched"] as? Bool else { return nil }
        return (switched, object["message"] as? String ?? "")
    }
}

public enum CodexAccounts {
    /// The Codex accounts used here, the one in use first. Only those with a saved login can be
    /// switched to.
    public static func list(book: AccountBook, switching: Bool, now: Date) -> [ClaudeAccount] {
        AccountList.fromBook(book, kind: .codex, now: now, name: \.email) { entry in
            switching && entry.hasSavedLogin ? .liveIsland : nil
        }
    }
}

public enum ClaudeAccounts {
    /// The Claude accounts to show. With claude-swap managing accounts, exactly its list, in its
    /// order: it holds the logins and switches them. What LiveIsland saw of an account (its
    /// plan, a fresher reading for the one in use) fills in. Without claude-swap, the accounts
    /// Claude Code has used here, with their limits.
    public static func merge(book: AccountBook, claudeSwap: [ClaudeSwapAccount]?, switcher: ClaudeAccount.Switcher?,
                             now: Date) -> [ClaudeAccount] {
        if let claudeSwap, !claudeSwap.isEmpty { return AccountList.fromSwitcher(claudeSwap, book: book, now: now) }
        return AccountList.fromBook(book, kind: .claude, now: now, name: \.displayName) { _ in
            switcher == .claudeSwap ? nil : switcher
        }
    }
}

/// One account as a switcher (claude-swap, ccswap) lists it. Both show accounts the same way:
/// exactly the switcher's, the one in use first, with what LiveIsland saw of each filling in.
protocol SwitcherRow {
    var number: Int { get }
    var email: String { get }
    /// Nil for a personal account, and always for ccswap, which doesn't say.
    var organizationUUID: String? { get }
    var isActive: Bool { get }
    /// When the switcher read its usage.
    var readingAt: Date? { get }
    /// The account as the switcher reports it, as `known` (LiveIsland's own entry) names it.
    func account(known: ClaudeAccountIdentity?, now: Date) -> ClaudeAccount
}

/// How the island lists accounts, for Claude Code and Codex alike.
enum AccountList {
    /// The accounts the book knows, the one in use first, then by `name`.
    static func fromBook(_ book: AccountBook, kind: AgentKind, now: Date, name: (ClaudeAccountIdentity) -> String,
                         switcher: (AccountBook.Entry) -> ClaudeAccount.Switcher?) -> [ClaudeAccount] {
        book.entries.map { key, entry in
            ClaudeAccount(identity: entry.identity, kind: kind, isActive: key == book.activeKey,
                          fiveHour: entry.fiveHour, sevenDay: entry.sevenDay, limitsObservedAt: entry.limitsObservedAt,
                          switcher: switcher(entry))
                .current(at: now)
        }
        .sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let order = name(lhs.identity).localizedCaseInsensitiveCompare(name(rhs.identity))
            return order != .orderedSame ? order == .orderedAscending : lhs.id < rhs.id
        }
    }

    /// Exactly the switcher's accounts, the one in use first, then in its order. The book's
    /// entry for each (matched as `AccountBook.entry` explains) fills in who it is, and its
    /// reading of the account in use when that's newer.
    static func fromSwitcher<Row: SwitcherRow>(_ rows: [Row], book: AccountBook, now: Date) -> [ClaudeAccount] {
        var claimed: [String: Set<String>] = [:]
        for row in rows {
            if let organization = row.organizationUUID { claimed[row.email.lowercased(), default: []].insert(organization) }
        }
        return rows.map { row -> (number: Int, account: ClaudeAccount) in
            let known = book.entry(email: row.email, organization: row.organizationUUID, isActive: row.isActive,
                                   claimedOrganizations: claimed[row.email.lowercased()] ?? [])
            var account = row.account(known: known?.identity, now: now)
            account.takeFresherReading(from: known, than: row.readingAt)
            return (row.number, account.current(at: now))
        }
        .sorted { lhs, rhs in lhs.account.isActive != rhs.account.isActive ? lhs.account.isActive : lhs.number < rhs.number }
        .map(\.account)
    }
}

extension ClaudeAccount {
    /// Claude Code's status line and Codex's sessions report the account in use as it works;
    /// a switcher polls every few minutes. The newer reading of the account in use wins. A
    /// newer report of the week without 5 hours means the plan has no 5-hour limit (any
    /// more), so the switcher's older 5-hour number must not linger.
    mutating func takeFresherReading(from known: AccountBook.Entry?, than readAt: Date?) {
        guard isActive, let known, let observed = known.limitsObservedAt, observed > (readAt ?? .distantPast),
              known.fiveHour != nil || known.sevenDay != nil
        else { return }
        fiveHour = known.sevenDay != nil ? known.fiveHour : known.fiveHour ?? fiveHour
        sevenDay = known.sevenDay ?? sevenDay
        limitsObservedAt = observed
    }
}

extension ClaudeSwapAccount: SwitcherRow {
    var readingAt: Date? { usageFetchedAt }

    func account(known: ClaudeAccountIdentity?, now: Date) -> ClaudeAccount {
        var identity = known ?? ClaudeAccountIdentity(accountUUID: "", email: email, organizationUUID: organizationUUID,
                                                      organizationName: organizationName)
        identity.email = known?.email ?? email.lowercased()
        if let alias { identity.name = alias }
        var account = ClaudeAccount(identity: identity, isActive: isActive, fiveHour: fiveHour, sevenDay: sevenDay,
                                    limitsObservedAt: usageFetchedAt ?? now, switcher: .claudeSwap,
                                    needsLogin: needsLogin, claudeSwapNumber: number)
        account.models = models
        return account
    }
}
