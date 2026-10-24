// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

@main struct ContinuityTests {
    @MainActor static func main() async {
        var failures = 0
        func expect(_ value: Bool, _ message: String) {
            if !value { failures += 1; print("FAIL: \(message)") }
        }
        for scenario in ["success", "connection", "quit", "cancel", "expired", "dim"] {
            var events: [String] = []
            var active = true
            var model: ContinuityWorkflow!
            model = ContinuityWorkflow(hooks: .init(
                isAvailable: { active },
                connect: { _ in
                    events.append("connect")
                    if scenario == "connection" { throw ContinuityFailure.connection }
                },
                quitApps: { _ in events.append("quit"); return scenario != "quit" },
                wait: { seconds in
                    events.append("wait:\(seconds)")
                    if scenario == "cancel" { model.cancel() }
                    if scenario == "expired" { active = false }
                },
                dim: { events.append("dim"); return scenario != "dim" },
                restore: { events.append("restore") }
            ))
            await model.run(hotspot: "Test iPhone", apps: ["com.test.app"])
            switch scenario {
            case "success":
                expect(events == ["connect", "quit"] + Array(repeating: "wait:1", count: 5) + ["dim"], "five full seconds after connection and quit before dimming")
                expect(model.phase == .active, "success remains active")
                model.cancel()
                expect(events.last == "restore", "return restores brightness")
            case "connection": expect(events == ["connect"] && model.phase == .failed(.connection), "connection failure must not quit apps or dim")
            case "quit": expect(events == ["connect", "quit"] && model.phase == .failed(.quit), "refused quit must not dim")
            case "cancel", "expired": expect(!events.contains("dim") && model.phase == .idle, "cancellation/session expiry prevents delayed dim")
            case "dim": expect(model.phase == .failed(.brightness), "failed brightness write is not success")
            default: break
            }
        }
        // A cancelled connection can finish after a newer operation. Its late
        // completion must not quit apps, dim, or overwrite the new operation.
        var continuation: CheckedContinuation<Void, Never>?
        var connections = 0
        var quits = 0
        let stale = ContinuityWorkflow(hooks: .init(
            isAvailable: { true },
            connect: { _ in
                connections += 1
                if connections == 1 { await withCheckedContinuation { continuation = $0 } }
            },
            quitApps: { _ in quits += 1; return true },
            wait: { _ in }, dim: { true }, restore: { }
        ))
        let first = Task { await stale.run(hotspot: "phone", apps: []) }
        while continuation == nil { await Task.yield() }
        await stale.run(hotspot: "phone", apps: [])
        expect(connections == 1, "double click cannot start two connections")
        stale.cancel()
        await stale.run(hotspot: "phone", apps: [])
        continuation?.resume()
        await first.value
        expect(quits == 1 && stale.phase == .active, "late cancelled response cannot affect new handoff")

        print("Continuity workflow: \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
