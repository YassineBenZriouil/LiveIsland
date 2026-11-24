import LiveIslandCore
import SwiftUI
import os

@main
struct LiveIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel().environmentObject(appDelegate.model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    private var island: IslandController?
    private var lyrics: LyricsWindowController?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        let island = IslandController(model: model)
        island.show()
        self.island = island
        let lyrics = LyricsWindowController(model: model)
        lyrics.start()
        self.lyrics = lyrics
        // `kill` and `pkill` send SIGTERM: quit properly, so the media adapter goes too.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    /// liveisland:// links, e.g. from Shortcuts: open[/media|agents|activity|accounts[/claude|codex]], close,
    /// settings[/general|island|media|agents|accounts[/claude|codex][/accounts|automatic|console]|updates|about], update[/install], timer/<minutes>,
    /// switch/best, switch/<n>, switch/codex/best, switch/codex/<n>,
    /// move (the island follows the pointer until ⌘), move/top (back on the top edge),
    /// lyrics[/open|close] (Sing With Me's window; while it's off, opening only asks).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "liveisland" {
            Logger(subsystem: "com.aissam.liveisland", category: "url").notice("Open \(url.absoluteString, privacy: .public)")
            let parts = [url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }
            let detail = parts.dropFirst().first?.lowercased()
            switch parts.first?.lowercased() {
            case "open":
                // open/accounts/codex picks the Codex list.
                if let kind = parts.dropFirst(2).first.flatMap({ AgentKind(rawValue: $0.lowercased()) }) { model.accountsKind = kind }
                model.expand(on: detail.flatMap { IslandTab(rawValue: $0.capitalized) })
            case "close": model.collapse()
            case "move":
                if detail == "top" { model.islandPlacement = nil } else { model.beginMovingIsland() }
            case "update":
                // update and update/install both check now and show Software Update, where
                // Update Now waits for the person's tap: any web page can open a link, so a
                // link never installs on its own.
                model.openSettings(.updates)
                Task { await model.updater.check() }
            case "switch":
                // switch/best, switch/<n> for Claude (claude-swap's numbers); switch/codex/best,
                // switch/codex/<n> for Codex (ccswap's).
                if detail == "codex" {
                    switchCodex(to: LinkValue.switchTarget(parts.dropFirst(2).first))
                } else {
                    switchClaude(to: LinkValue.switchTarget(detail))
                }
            // settings/accounts/codex/console picks the tool and the tab; settings/codex is
            // what 1.7 called the Codex page.
            case "settings":
                let rest = parts.dropFirst(2).joined(separator: "/")
                if detail == "codex" {
                    model.openSettings(.accounts, anchor: "codex" + (rest.isEmpty ? "" : "/" + rest))
                } else {
                    model.openSettings(detail.flatMap(SettingsSection.init(rawValue:)) ?? .general, anchor: rest.isEmpty ? nil : rest)
                }
            case "lyrics":
                switch LinkValue.lyricsAction(detail) {
                case .toggle: model.toggleLyrics()
                case .open: model.openLyrics()
                case .close: model.closeLyrics()
                case nil: break
                }
            case "timer":
                // At most a day: "inf" or "1e20" would otherwise reach the clock.
                if let minutes = parts.dropFirst().first.flatMap(LinkValue.timerMinutes) { model.startTimer(minutes: minutes) }
            default: break
            }
        }
    }

    /// The same switch as the island's buttons, so it's announced in the notch. Without a known
    /// account (the list not read yet), claude-swap picks or takes the number itself, and says
    /// in the console if it can't.
    private func switchClaude(to target: LinkValue.SwitchTarget?) {
        switch target {
        case .best:
            if let best = model.bestAccount { model.switchAccount(best) } else { Task { await model.claudeSwap.switchToBest() } }
        case .number(let number):
            if let account = model.accounts.first(where: { $0.claudeSwapNumber == number }) {
                model.switchAccount(account)
            } else {
                Task { await model.claudeSwap.switchTo(number) }
            }
        case nil: break
        }
    }

    /// Codex goes through ccswap, the same way.
    private func switchCodex(to target: LinkValue.SwitchTarget?) {
        switch target {
        case .best:
            if let best = model.bestCodexAccount { model.switchAccount(best) } else { Task { await model.codexSwap.switchToBest() } }
        case .number(let number):
            if let account = model.codexAccounts.first(where: { $0.ccswapNumber == number }) {
                model.switchAccount(account)
            } else {
                Task { _ = await model.codexSwap.switchTo(number) }
            }
        case nil: break
        }
    }
}
