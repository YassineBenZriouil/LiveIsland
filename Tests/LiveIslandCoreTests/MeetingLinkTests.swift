import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Meeting links")
struct MeetingLinkTests {
    @Test func zoomInTheLocation() {
        // As Zoom's Calendar add-in writes it.
        let link = MeetingLink.find(url: nil, location: "https://us02web.zoom.us/j/81234567890?pwd=QWxhZGRpbjpvcGVuIHNlc2FtZQ.1", notes: nil)
        #expect(link?.service == .zoom)
        #expect(link?.url.absoluteString == "https://us02web.zoom.us/j/81234567890?pwd=QWxhZGRpbjpvcGVuIHNlc2FtZQ.1")
    }

    @Test func meetInTheEventURL() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")
        let link = MeetingLink.find(url: url, location: "Room 4B", notes: nil)
        #expect(link == MeetingLink(service: .meet, url: url!))
    }

    @Test func meetInGoogleNotes() {
        let notes = """
        Join with Google Meet: https://meet.google.com/xyz-abcd-efg
        Or dial: ‪(US) +1 555-010-0199‬ PIN: ‪123 456 789‬#
        More phone numbers: https://tel.meet/xyz-abcd-efg?pin=1234567890
        """
        #expect(MeetingLink.find(url: nil, location: nil, notes: notes)?.url.absoluteString == "https://meet.google.com/xyz-abcd-efg")
    }

    @Test func teamsInOutlookNotes() {
        let notes = """
        ________________________________________________________________________________
        Microsoft Teams meeting
        Join on your computer, mobile app or room device
        Click here to join the meeting<https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjQ5ZjFmYzMtZTU2Ny00YjEx%40thread.v2/0?context=%7b%22Tid%22%3a%2272f988bf-86f1-41af-91ab-2d7cd011db47%22%2c%22Oid%22%3a%22d1e4c1f0-0000-0000-0000-000000000000%22%7d>
        Meeting ID: 123 456 789 012
        Passcode: aB3cD4
        Download Teams<https://www.microsoft.com/en-us/microsoft-teams/download-app> | Join on the web<https://www.microsoft.com/microsoft-teams/join-a-meeting>
        Learn More<https://aka.ms/JoinTeamsMeeting> | Meeting options<https://teams.microsoft.com/meetingOptions/?organizerId=d1e4c1f0>
        ________________________________________________________________________________
        """
        let link = MeetingLink.find(url: nil, location: "Microsoft Teams Meeting", notes: notes)
        #expect(link?.service == .teams)
        #expect(link?.url.absoluteString.hasPrefix("https://teams.microsoft.com/l/meetup-join/19%3ameeting_") == true)
        #expect(link?.url.absoluteString.hasSuffix("%7d") == true)
    }

    @Test func teamsBehindSafeLinks() {
        let notes = "Join: <https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_abc%2540thread.v2%2F0&data=05%7C01%7C&sdata=xyz&reserved=0>"
        let link = MeetingLink.find(url: nil, location: nil, notes: notes)
        #expect(link?.service == .teams)
        #expect(link?.url.host == "teams.microsoft.com")
    }

    @Test func webexInvite() {
        let notes = "Join meeting\nhttps://acme.webex.com/acme/j.php?MTID=m1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d\nMeeting number: 2650 123 4567"
        #expect(MeetingLink.find(url: nil, location: nil, notes: notes)?.service == .webex)
        #expect(MeetingLink.find(url: nil, location: "https://acme.webex.com/meet/jdoe", notes: nil)?.service == .webex)
    }

    @Test func linkWithoutAScheme() {
        #expect(MeetingLink.find(url: nil, location: "zoom.us/j/81234567890", notes: nil)?.service == .zoom)
    }

    @Test func eventURLWinsOverNotes() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")
        let link = MeetingLink.find(url: url, location: nil, notes: "Backup: https://us02web.zoom.us/j/81234567890")
        #expect(link?.service == .meet)
    }

    @Test func aNonMeetingEventURLFallsBackToTheNotes() {
        let url = URL(string: "https://docs.google.com/document/d/1AbC/edit")
        let link = MeetingLink.find(url: url, location: "Room 4B", notes: "Call: https://us02web.zoom.us/j/81234567890")
        #expect(link?.service == .zoom)
    }

    @Test func pagesThatAreNotMeetings() {
        #expect(MeetingLink.find(url: URL(string: "https://zoom.us/"), location: "https://meet.google.com/", notes: nil) == nil)
        #expect(MeetingLink.first(in: "Download Teams<https://www.microsoft.com/en-us/microsoft-teams/download-app>") == nil)
        #expect(MeetingLink.first(in: "Notes in https://zoom.us.example.com/j/123") == nil)
        #expect(MeetingLink.first(in: "Lunch with the team at the usual place") == nil)
        #expect(MeetingLink.find(url: nil, location: nil, notes: nil) == nil)
    }

    @Test func otherSchemesAreIgnored() {
        #expect(MeetingLink.recognize(URL(string: "zoommtg://zoom.us/join?confno=81234567890")!) == nil)
    }
}
