import Foundation

// Keep the GUI entry point synchronous. Calling App.main() from a top-level
// async MainActor job holds that executor for the lifetime of the AppKit loop:
// SwiftUI buttons, .task and deferred termination then never get to run.
let arguments = Array(CommandLine.arguments.dropFirst())
if let output = ResumeFrozenCommand.run(arguments, endAfter: ResumeFrozenCommand.endProcess) {
    for line in output.lines { print(line) }
    exit(output.status)
}
if arguments == ["--power-helper"] { PowerBrokerDaemon.run() }
if arguments == ["--local-gui-self-test"] { LocalGUIEventLoopProbe.run() }
if arguments.first?.hasPrefix("--local-") == true {
    // One-shot asynchronous commands own a run loop without blocking the
    // MainActor in a synchronous App.main() call. No GUI is launched here.
    Task { @MainActor in
        if let status = await LocalDiagnostics.run(arguments) { exit(status) }
        if let status = await LocalPowerCommand.run(arguments) { exit(status) }
        exit(2)
    }
    RunLoop.main.run()
    exit(1)
}
InsomniaApp.main()
