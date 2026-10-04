import AppKit

// Developer check: `ClipboardX --fetch-test <url>` fetches one link preview with the real fetcher, prints it and exits.
if let i = CommandLine.arguments.firstIndex(of: "--fetch-test"), i + 1 < CommandLine.arguments.count, let url = URL(string: CommandLine.arguments[i + 1]) {
    Task {
        do {
            let link = try await CompositeLinkFetcher(primary: SystemLinkFetcher(), fallback: WebPageLinkFetcher()).fetch(url)
            print("title=\(link.title ?? "nil") icon=\(link.iconData?.count ?? 0) bytes image=\(link.imageData?.count ?? 0) bytes")
        } catch { print("fetch failed: \(error)") }
        exit(0)
    }
    RunLoop.main.run()
}

let app = CXApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
