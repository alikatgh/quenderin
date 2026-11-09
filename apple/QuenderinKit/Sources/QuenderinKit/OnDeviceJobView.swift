#if canImport(SwiftUI)
import SwiftUI

/// The first-open card for model jobs, the checkup, practice questions, and local tools.
public struct OnDeviceJobCard: View {
    private let conversationID: String
    private let chatModel: ModelEntry
    private let onSelectChat: (ModelEntry) -> Void
    private let guidanceNotes: Int
    private let skillCount: Int
    @State private var book = JobStore.loadBook()
    @State private var desk = JobStore.loadDesk()
    @State private var installed: [ModelEntry] = []
    @State private var sheet: JobSheet?
    @State private var checkup: Checkup?
    @State private var practice: PracticeScore?
    @State private var serverName = ""
    @State private var serverAddress = ""
    #if os(macOS)
    @State private var serverCommand = ""
    #endif
    @State private var toolNote = ""
    @State private var perceptionNote = ""
    @Environment(\.colorScheme) private var scheme

    public init(conversationID: String, chatModel: ModelEntry, guidanceNotes: Int, skillCount: Int, onSelectChat: @escaping (ModelEntry) -> Void) {
        self.conversationID = conversationID
        self.chatModel = chatModel
        self.guidanceNotes = guidanceNotes
        self.skillCount = skillCount
        self.onSelectChat = onSelectChat
    }

    private var roles: ConversationRoles {
        book.roles(conversationID: conversationID, chatFallback: chatModel.id)
    }

    private var names: [String: String] {
        var map = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0.label) })
        map[chatModel.id] = chatModel.label
        return map
    }

    public var body: some View {
        let palette = QuenderinPalette.of(scheme)
        VStack(alignment: .leading, spacing: 10) {
            Text(OnDeviceCopy.title)
                .font(.headline)
                .foregroundStyle(palette.onSurface)
            roleRow(.chat, palette: palette)
            roleRow(.checker, palette: palette)
            roleRow(.perception, palette: palette)
            Text(OnDeviceCopy.card)
                .font(.footnote)
                .foregroundStyle(palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            Text(OnDeviceCopy.checkerRuns)
                .font(.footnote)
                .foregroundStyle(palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                jobButton(OnDeviceCopy.doctorButton, palette: palette) { sheet = .doctor }
                jobButton(OnDeviceCopy.practiceButton, palette: palette) { sheet = .practice }
                jobButton(OnDeviceCopy.toolsButton, palette: palette) { sheet = .tools }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.onSurfaceVariant.opacity(0.18), lineWidth: 1))
        .onAppear {
            installed = ModelManager(storage: OnboardingModel.defaultModelStorage(), activeModelID: chatModel.id).installed().map(\.model)
            syncSeat()
        }
        .sheet(item: $sheet) { which in
            NavigationStack {
                ScrollView { sheetBody(which, palette: palette).padding(20) }
                    .navigationTitle(which.title)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
            }
            .quenderinSheetWindowCanvas()
        }
    }

    private func roleRow(_ role: ModelRole, palette: QuenderinPalette) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(roleLabel(role))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.onSurface)
                .frame(width: 118, alignment: .leading)
            Text(roleTitle(role: role, roles: roles, names: names))
                .font(.subheadline)
                .foregroundStyle(palette.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(OnDeviceCopy.change) { sheet = .role(role) }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .combine)
    }

    private func roleLabel(_ role: ModelRole) -> String {
        switch role {
        case .chat: return "Chat"
        case .checker: return "Check"
        case .perception: return OnDeviceCopy.photos
        }
    }

    private func jobButton(_ title: String, palette: QuenderinPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(palette.primary)
    }

    @ViewBuilder
    private func sheetBody(_ which: JobSheet, palette: QuenderinPalette) -> some View {
        switch which {
        case .role(let role):
            rolePicker(role, palette: palette)
        case .doctor:
            doctorBody(palette: palette)
        case .practice:
            practiceBody(palette: palette)
        case .tools:
            toolsBody(palette: palette)
        case .perception:
            perceptionBody(palette: palette)
        }
    }

    private func rolePicker(_ role: ModelRole, palette: QuenderinPalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if role != .chat {
                Button(role == .checker ? OnDeviceCopy.shape : OnDeviceCopy.notLoaded) {
                    assign(role, nil)
                }
                .buttonStyle(.bordered)
            }
            if installed.isEmpty {
                Text("Only the open chat model is on this device. Nothing will be downloaded.")
                    .font(.footnote)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            ForEach(pickerModels, id: \.id) { entry in
                Button(entry.label) {
                    if role == .chat { onSelectChat(entry) }
                    assign(role, entry.id)
                }
                .buttonStyle(.bordered)
            }
            Text(OnDeviceCopy.notInference)
                .font(.footnote)
                .foregroundStyle(palette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pickerModels: [ModelEntry] {
        var models = installed
        if !models.contains(where: { $0.id == chatModel.id }) { models.insert(chatModel, at: 0) }
        return models
    }

    private func doctorBody(palette: QuenderinPalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(OnDeviceCopy.runCheckup) { checkup = makeCheckup() }
                .buttonStyle(.borderedProminent)
            if let checkup {
                Text(checkup.summary).font(.body.weight(.semibold))
                ForEach(checkup.rows, id: \.name) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.subheadline.weight(.semibold))
                        Text(row.detail).font(.footnote).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
            }
            Text(OnDeviceCopy.notInference).font(.footnote).foregroundStyle(palette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func practiceBody(palette: QuenderinPalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(OnDeviceCopy.runPractice) {
                Task { practice = await PracticeQuestions.scoreLive() }
            }
            .buttonStyle(.borderedProminent)
            if let practice {
                Text(practice.tally).font(.body.weight(.semibold))
                Text(practice.summary).font(.footnote)
                ForEach(Array(practice.lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.prompt).font(.subheadline.weight(.semibold))
                        Text("\(line.outcome): \(line.detail)").font(.footnote).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
            }
            Text(OnDeviceCopy.notInference).font(.footnote).foregroundStyle(palette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolsBody(palette: QuenderinPalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(LocalPace.builtinIDs).sorted(), id: \.self) { id in
                Toggle(builtinLabel(id), isOn: Binding(
                    get: { LocalPace.isOn(id) },
                    set: { LocalPace.setOn(id, $0) }
                ))
            }
            Text(desk.servers.isEmpty ? OnDeviceCopy.noServers : "Local servers stay on this device.")
                .font(.footnote)
                .foregroundStyle(palette.onSurfaceVariant)
            TextField("Name", text: $serverName)
            TextField("Local address", text: $serverAddress)
            #if os(macOS)
            TextField("Command on this Mac", text: $serverCommand)
            #endif
            Button("Add") { addServer() }
                .buttonStyle(.bordered)
            if !toolNote.isEmpty {
                Text(toolNote).font(.footnote).foregroundStyle(palette.onSurfaceVariant)
            }
            ForEach(desk.servers, id: \.id) { server in
                VStack(alignment: .leading, spacing: 6) {
                    Text(server.name).font(.subheadline.weight(.semibold))
                    Button(OnDeviceCopy.lookUp) { lookUp(server) }
                        .buttonStyle(.bordered)
                    ForEach(desk.toolsOf(serverID: server.id), id: \.name) { tool in
                        Toggle(tool.title, isOn: Binding(
                            get: { desk.isOn(serverID: server.id, tool: tool.name) },
                            set: { desk.setOn(serverID: server.id, tool: tool.name, on: $0); JobStore.save(desk) }
                        ))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func perceptionBody(palette: QuenderinPalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(roleTitle(role: .perception, roles: roles, names: names))
                .font(.body.weight(.semibold))
            Text("This screen is the only place photos and speech load. Chat did not load them.")
                .font(.footnote)
                .foregroundStyle(palette.onSurfaceVariant)
            Button(OnDeviceCopy.look) {
                PerceptionSeat.open(modelID: roles.perceptionModelID)
                perceptionNote = PerceptionSeat.look("sample")
            }
            .buttonStyle(.bordered)
            Button(OnDeviceCopy.listen) {
                PerceptionSeat.open(modelID: roles.perceptionModelID)
                perceptionNote = PerceptionSeat.listen("clip")
            }
            .buttonStyle(.bordered)
            if !perceptionNote.isEmpty { Text(perceptionNote).font(.footnote) }
            Text(OnDeviceCopy.notInference).font(.footnote).foregroundStyle(palette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { PerceptionSeat.open(modelID: roles.perceptionModelID) }
        .onDisappear { PerceptionSeat.close() }
    }

    private func makeCheckup() -> Checkup {
        let ids = Set(installed.map(\.id)).union([chatModel.id])
        return deviceCheckup(DeviceFacts(
            chatModelID: roles.chatModelID,
            chatLabel: names[roles.chatModelID] ?? roles.chatModelID,
            chatOnDevice: ids.contains(roles.chatModelID),
            checkerModelID: roles.checkerModelID,
            checkerOnDevice: roles.checkerModelID.map { ids.contains($0) } ?? false,
            perceptionModelID: roles.perceptionModelID,
            perceptionOnDevice: roles.perceptionModelID.map { ids.contains($0) } ?? false,
            perceptionOpen: false,
            guidanceNotes: guidanceNotes,
            guidanceReadable: true,
            skillCount: skillCount,
            skillsReadable: true,
            builtinOn: Dictionary(uniqueKeysWithValues: LocalPace.builtinIDs.map { ($0, LocalPace.isOn($0)) }),
            serverCount: desk.servers.count,
            toolsOff: desk.offNames()
        ))
    }

    private func assign(_ role: ModelRole, _ modelID: String?) {
        book.assign(conversationID: conversationID, role: role, modelID: modelID, chatFallback: chatModel.id)
        JobStore.save(book)
        syncSeat()
        if role == .perception { sheet = .perception } else { sheet = nil }
    }

    private func syncSeat() {
        let current = roles
        RoleSeat.shared.selectChecker(modelID: current.checkerModelID)
        if !RoleSeat.shared.perceptionState().open {
            RoleSeat.shared.setPerception(modelID: current.perceptionModelID, open: false, perceive: nil)
        }
    }

    private func addServer() {
        #if os(macOS)
        let command = serverCommand.nilIfBlank
        let allow = true
        #else
        let command: String? = nil
        let allow = false
        #endif
        switch desk.add(name: serverName, address: serverAddress.nilIfBlank, command: command, allowCommand: allow) {
        case .ok:
            toolNote = ""
            serverName = ""
            serverAddress = ""
            #if os(macOS)
            serverCommand = ""
            #endif
            JobStore.save(desk)
        case .rejected(let message):
            toolNote = message
        }
    }

    private func lookUp(_ server: LocalServer) {
        let transport: McpTransport
        if let command = server.command, !command.isEmpty {
            #if os(macOS)
            transport = StdioMcp(command: command)
            #else
            toolNote = OnDeviceCopy.macCommand
            return
            #endif
        } else if let address = server.address {
            transport = HttpMcp(address: address)
        } else {
            toolNote = OnDeviceCopy.needTarget
            return
        }
        Task {
            let tools = await Task.detached { McpClient(transport: transport).listTools() }.value
            if tools.isEmpty {
                toolNote = OnDeviceCopy.serverSilent
            } else {
                desk.remember(serverID: server.id, tools: tools)
                toolNote = "Found \(tools.count)."
                JobStore.save(desk)
            }
        }
    }

    private func builtinLabel(_ id: String) -> String {
        switch id {
        case "calculator": return "Calculator"
        case "units": return "Units"
        case "date": return "Dates"
        default: return id
        }
    }
}

private enum JobSheet: Identifiable {
    case role(ModelRole)
    case doctor, practice, tools, perception
    var id: String {
        switch self {
        case .role(let role): return "role-\(role.rawValue)"
        case .doctor: return "doctor"
        case .practice: return "practice"
        case .tools: return "tools"
        case .perception: return "perception"
        }
    }
    var title: String {
        switch self {
        case .role(.chat): return "Chat"
        case .role(.checker): return "Check"
        case .role(.perception): return OnDeviceCopy.photos
        case .doctor: return OnDeviceCopy.doctorButton
        case .practice: return OnDeviceCopy.practiceButton
        case .tools: return OnDeviceCopy.toolsButton
        case .perception: return OnDeviceCopy.photos
        }
    }
}

public enum JobStore {
    private static let rolesKey = "quenderin.onDeviceRoles"
    private static let toolsKey = "quenderin.onDeviceTools"

    public static func loadBook() -> ModelRoleBook { ModelRoleBook.decode(UserDefaults.standard.string(forKey: rolesKey) ?? "") }
    public static func save(_ book: ModelRoleBook) { UserDefaults.standard.set(book.encode(), forKey: rolesKey) }
    public static func loadDesk() -> LocalToolDesk { LocalToolDesk.decode(UserDefaults.standard.string(forKey: toolsKey) ?? "") }
    public static func save(_ desk: LocalToolDesk) { UserDefaults.standard.set(desk.encode(), forKey: toolsKey) }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
