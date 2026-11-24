import Foundation

/// The video call link of a calendar event, so the island can offer to join it.
///
/// Invites put the link in different places: Google Calendar fills the event's URL or
/// location with a Meet link, Zoom's add-in writes it into the location, and Outlook puts
/// Teams and Webex links in the notes, often wrapped in angle brackets or in a Safe Links
/// redirect. So every field is searched, the event's own URL first.
public struct MeetingLink: Equatable, Sendable {
    public enum Service: String, Sendable {
        case zoom, meet, teams, webex

        /// The name shown on the Join button.
        public var name: String {
            switch self {
            case .zoom: return "Zoom"
            case .meet: return "Google Meet"
            case .teams: return "Teams"
            case .webex: return "Webex"
            }
        }
    }

    public var service: Service
    public var url: URL

    public init(service: Service, url: URL) {
        self.service = service
        self.url = url
    }

    /// The first meeting link in the event's URL, then its location, then its notes.
    public static func find(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        if let url, let link = recognize(url) { return link }
        for text in [location, notes] {
            if let text, let link = first(in: text) { return link }
        }
        return nil
    }

    /// The first meeting link written anywhere in some text.
    public static func first(in text: String) -> MeetingLink? {
        // Cheap check first: notes can be long, and most events have no call at all.
        let lowered = text.lowercased()
        guard ["zoom", "meet.google", "teams.", "webex", "safelinks"].contains(where: lowered.contains) else { return nil }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        var found: MeetingLink?
        detector.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if let url = match?.url, let link = recognize(url) {
                found = link
                stop.pointee = true
            }
        }
        return found
    }

    /// The meeting a link joins, or nil when it isn't one (a Zoom home page, a Google Doc).
    public static func recognize(_ url: URL) -> MeetingLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("safelinks.protection.outlook.com") {
            // Outlook rewrites links to go through its scanner; the real one is `url=`.
            guard let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
                let innerURL = URL(string: inner), innerURL.host?.lowercased().hasSuffix("safelinks.protection.outlook.com") == false
            else { return nil }
            return recognize(innerURL)
        }
        let path = url.path.lowercased()
        guard let service = service(host: host, path: path) else { return nil }
        return MeetingLink(service: service, url: url)
    }

    private static func service(host: String, path: String) -> Service? {
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("zoom.us") || on("zoomgov.com") {
            // Meetings (/j/), personal rooms (/my/), webinars (/w/) and the web client.
            let joins = ["/j/", "/my/", "/s/", "/w/", "/wc/"]
            return joins.contains(where: path.hasPrefix) ? .zoom : nil
        }
        if host == "meet.google.com" {
            // A meeting code such as /abc-defg-hij, or a /lookup/ nickname; not the home page.
            return path.count > 1 ? .meet : nil
        }
        if on("teams.microsoft.com") || on("teams.live.com") || on("teams.microsoft.us") {
            let joins = ["/l/meetup-join/", "/meet/", "/l/meet/"]
            return joins.contains(where: path.hasPrefix) ? .teams : nil
        }
        if on("webex.com") {
            // Personal rooms (/meet/name), invites (/j.php?MTID=), and the join service.
            let joins = ["/meet/", "/j.php", "/join/", "/wbxmjs/joinservice"]
            return joins.contains(where: path.contains) ? .webex : nil
        }
        return nil
    }
}
