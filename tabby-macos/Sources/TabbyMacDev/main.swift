// Development entry point: `swift run TabbyMacDev` (macOS only).
// The shipping app is built from project.yml, whose target uses App/main.swift.
#if canImport(AppKit)
import TabbyApp

MainActor.assumeIsolated {
    TabbyAppMain.run()
}
#else
print("TabbyMac runs on macOS only.")
#endif
