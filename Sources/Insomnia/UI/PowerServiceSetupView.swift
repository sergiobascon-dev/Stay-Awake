import AppKit
import SwiftUI
import ServiceManagement

/// Owned by the settings root, not a transparent Section: Form may extract
/// Section content without running lifecycle modifiers attached to that Section.
@MainActor
@Observable
final class PowerServiceSetup {
    private(set) var status = SMAppService.Status.notRegistered
    private(set) var busy = false
    private(set) var ready = false
    private(set) var message: String?

    private let readStatus: () -> SMAppService.Status
    private let validate: () throws -> Void
    private let register: () throws -> Void
    private let probe: () async throws -> Void

    init(
        readStatus: @escaping () -> SMAppService.Status = { SMAppService.daemon(plistName: PowerBrokerPolicy.daemonPlist).status },
        validate: @escaping () throws -> Void = { _ = try PowerBrokerPolicy.requirement() },
        register: @escaping () throws -> Void = { try SMAppService.daemon(plistName: PowerBrokerPolicy.daemonPlist).register() },
        probe: @escaping () async throws -> Void = { try await PowerBrokerRPC.send("status") }
    ) {
        self.readStatus = readStatus
        self.validate = validate
        self.register = register
        self.probe = probe
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await inspect()
    }

    private func inspect() async {
        ready = false
        status = readStatus()
        do {
            try validate()
            switch status {
            case .enabled:
                try await probe()
                ready = true
                message = "El servicio responde y su identidad está verificada. Esta comprobación no inicia ninguna sesión."
            case .requiresApproval:
                message = "Autoriza Stay Awake en General > Ítems de inicio y extensiones. Después vuelve aquí y pulsa Comprobar."
            case .notRegistered:
                message = "Pulsa Configurar servicio para solicitar la autorización de macOS."
            default:
                message = "macOS no encuentra el servicio. Conserva la aplicación instalada y revisa el diagnóstico antes de reinstalar."
            }
        } catch { message = error.localizedDescription }
    }

    func registerService() async {
        guard !busy else { return }
        busy = true
        ready = false
        message = "Solicitando autorización a macOS…"
        defer { busy = false }
        do {
            try validate()
            try register()
            await inspect()
        } catch {
            status = readStatus()
            // SMAppService may report EPERM while the native approval is
            // pending, or an approval may complete just as register returns.
            // Only an authenticated probe can establish readiness.
            if status == .requiresApproval || status == .enabled { await inspect() }
            else { message = "No se pudo configurar el servicio: \(error.localizedDescription)" }
        }
    }
}

/// Registration is explicit. Opening settings only reads status and verifies
/// identity; it never starts a session or changes an energy preference.
struct PowerServiceSetupView: View {
    let setup: PowerServiceSetup

    var body: some View {
        Section("Servicio de energía") {
            Label(setup.ready ? "Disponible" : "Configuración pendiente",
                  systemImage: setup.ready ? "checkmark.shield" : "shield.lefthalf.filled")
            Text("Permite mantener el Mac activo con la tapa cerrada y restaurar los ajustes al finalizar. macOS te pedirá autorización para habilitarlo.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = setup.message {
                Text(message).font(.caption).textSelection(.enabled)
            }
            HStack {
                if setup.status == .requiresApproval {
                    Button("Abrir Ajustes del Sistema") { SMAppService.openSystemSettingsLoginItems() }
                } else if setup.status != .enabled {
                    Button("Configurar servicio") { Task { await setup.registerService() } }
                        .disabled(setup.busy)
                }
                Button("Comprobar") { Task { await setup.refresh() } }.disabled(setup.busy)
                if setup.busy { ProgressView().controlSize(.small) }
            }
        }
    }
}
