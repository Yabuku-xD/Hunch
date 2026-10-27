import AppKit
import SpotCore

// Single instance: an exclusive, non-blocking flock. A second launch asks the running copy to show its panel and exits.
let lockFD = open(NSTemporaryDirectory() + "dev.betterspotlight.lock", O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

// Before any ggml/llama call: no Metal residency sets. Homebrew ggml otherwise starts a per-device keep-alive loop
// that never stops once the model has loaded (measured 13–17% CPU with the panel hidden and the model idle) and
// whose destructor aborts at exit. For a 300M-parameter embedder residency buys nothing measurable.
setenv("GGML_METAL_NO_RESIDENCY", "1", 0)

let arguments = ProcessInfo.processInfo.arguments

#if DEBUG
let environment = ProcessInfo.processInfo.environment
let fixtureEngine = environment["BS_FIXTURE"].flatMap(PreviewEngine.init(fixture:))
let backend: SearchBackend? = fixtureEngine == nil ? SearchBackend() : nil
let engine: any SearchEngine = fixtureEngine ?? backend!.engine
let launch = AppDelegate.Launch(
    showPanel: arguments.contains("--show"),
    query: arguments.firstIndex(of: "--query").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil },
    showActions: environment["BS_SHOW_ACTIONS"] == "1",
    showSettings: environment["BS_SHOW_SETTINGS"] == "1",
    measure: arguments.contains("--measure"))
#else
let backend: SearchBackend? = SearchBackend()
let engine: any SearchEngine = backend!.engine
let launch = AppDelegate.Launch()
#endif

let app = NSApplication.shared
let delegate = AppDelegate(engine: engine, backend: backend, launch: launch)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
