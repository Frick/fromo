import FromoCore
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            TabView {
                general.tabItem { Label("General", systemImage: "gearshape") }
                timer.tabItem { Label("Timer", systemImage: "timer") }
                breaks.tabItem { Label("Breaks", systemImage: "list.bullet") }
                hours.tabItem { Label("Work Hours", systemImage: "clock") }
                nags.tabItem { Label("Nags", systemImage: "bell") }
                sounds.tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
                sketchybar.tabItem { Label("SketchyBar", systemImage: "menubar.rectangle") }
            }
        }
        .frame(minWidth: 1040, minHeight: 580)
    }

    private var general: some View {
        Form {
            Toggle("Launch at login", isOn: model.binding(\.general.launchAtLogin))
            if model.loginStatus == .requiresApproval {
                Text("Launch at login needs approval.")
                Button("Open Login Items") { model.openLoginItems() }
            }
            NumberSetting("Daily goal", value: model.binding(\.timer.dailyGoal), minimum: 0)
        }.formStyle(.grouped)
    }

    private var timer: some View {
        Form {
            NumberSetting("Work (minutes)", value: model.binding(\.timer.workMinutes))
            NumberSetting("Short break (minutes)", value: model.binding(\.timer.shortBreakMinutes))
            NumberSetting("Long break (minutes)", value: model.binding(\.timer.longBreakMinutes))
            NumberSetting("Work sessions per long break", value: model.binding(\.timer.longBreakEvery))
            NumberSetting("Extend (minutes)", value: model.binding(\.timer.extendMinutes))
            NumberSetting("Lunch (minutes)", value: model.binding(\.timer.lunchMinutes))
        }.formStyle(.grouped)
    }

    private var breaks: some View {
        Form {
            StringListSetting(title: "Short breaks", path: \.breaks.short, newValue: "New task", model: model)
            StringListSetting(title: "Long breaks", path: \.breaks.long, newValue: "New task", model: model)
            StringListSetting(title: "Other answers", path: \.breaks.other, newValue: "Other", model: model)
        }.formStyle(.grouped)
    }

    private var hours: some View {
        Form {
            ForEach(Array(WorkHoursEditor.days.enumerated()), id: \.element) { index, day in
                WorkHoursSetting(day: day, title: WorkHoursEditor.names[index], model: model)
            }
        }.formStyle(.grouped)
    }

    private var nags: some View {
        Form {
            Toggle("Enable nags", isOn: model.binding(\.nags.enabled))
            NumberSetting("Interval (minutes)", value: model.binding(\.nags.intervalMinutes))
            NumberSetting("Idle threshold (minutes)", value: model.binding(\.nags.idleThresholdMinutes), minimum: 0)
            Section("Meeting detection") {
                Toggle("Camera in use", isOn: model.binding(\.meetings.camera))
                Toggle("Microphone in use", isOn: model.binding(\.meetings.microphone))
            }
            StringListSetting(title: "Unused timer messages", path: \.nags.unused, newValue: "New message", model: model)
            StringListSetting(title: "Waiting messages", path: \.nags.waiting, newValue: "New message", model: model)
        }.formStyle(.grouped)
    }

    private var sounds: some View {
        Form {
            SoundSetting(title: "Work ends", path: \.sounds.workEnd, model: model)
            SoundSetting(title: "Break ends", path: \.sounds.breakEnd, model: model)
            SoundSetting(title: "Lunch ends", path: \.sounds.lunchEnd, model: model)
            SoundSetting(title: "Nag", path: \.sounds.nag, model: model)
            Toggle("Mute sounds during meetings", isOn: model.binding(\.sounds.muteInMeeting))
        }.formStyle(.grouped)
    }

    private var sketchybar: some View {
        Form {
            Toggle("Enable SketchyBar integration", isOn: model.binding(\.sketchybar.enabled))
            TextField("Binary path (blank = auto)", text: model.binding(\.sketchybar.path))
            TextField("Event name", text: model.binding(\.sketchybar.event))
            Button("Send Test Trigger") { model.sendTestTrigger() }
        }.formStyle(.grouped)
    }
}

@MainActor
private struct NumberSetting: View {
    let title: String
    @Binding var value: Int
    let minimum: Int
    init(_ title: String, value: Binding<Int>, minimum: Int = 1) {
        self.title = title; _value = value; self.minimum = minimum
    }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number.grouping(.never))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 110)
            Stepper(title, value: $value, in: minimum...(Int.max / 60)).labelsHidden().fixedSize()
        }
    }
}

@MainActor
private struct StringListSetting: View {
    let title: String
    let path: WritableKeyPath<Config, [String]>
    let newValue: String
    @ObservedObject var model: SettingsModel
    private var values: [String] { model.config[keyPath: path] }
    var body: some View {
        Section(title) {
            List {
                ForEach(Array(values.enumerated()), id: \.offset) { index, _ in
                    HStack {
                        TextField("Item", text: Binding(get: {
                            let values = model.config[keyPath: path]
                            return values.indices.contains(index) ? values[index] : ""
                        }, set: { text in
                            model.edit { config in
                                if config[keyPath: path].indices.contains(index) { config[keyPath: path][index] = text }
                            }
                        }))
                        Button {
                            model.edit { SettingsLists.remove(&$0[keyPath: path], at: IndexSet(integer: index)) }
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                .onMove { source, destination in
                    model.edit { SettingsLists.move(&$0[keyPath: path], from: source, to: destination) }
                }
                .onDelete { source in model.edit { SettingsLists.remove(&$0[keyPath: path], at: source) } }
            }
            .frame(height: CGFloat(min(max(values.count, 1), 5) * 30 + 12))
            Button { model.edit { $0[keyPath: path].append(newValue) } } label: { Label("Add", systemImage: "plus") }
        }
    }
}

@MainActor
private struct WorkHoursSetting: View {
    let day: String
    let title: String
    @ObservedObject var model: SettingsModel
    private var enabled: Bool { !(model.config.workHours[day] ?? []).isEmpty }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func time(_ index: Int) -> Binding<Date> {
        Binding(get: {
            let parts = WorkHoursEditor.time(index: index, day: day, config: model.config)
            return calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: parts.hour, minute: parts.minute))!
        }, set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            model.edit { WorkHoursEditor.setTime(hour: parts.hour!, minute: parts.minute!, index: index, day: day, in: &$0) }
        })
    }
    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { enabled }, set: { enabled in
                model.edit { WorkHoursEditor.setEnabled(enabled, day: day, in: &$0) }
            })).frame(width: 140, alignment: .leading)
            if enabled {
                DatePicker("Start", selection: time(0), displayedComponents: [.hourAndMinute])
                DatePicker("End", selection: time(1), displayedComponents: [.hourAndMinute])
            }
        }.environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
    }
}

@MainActor
private struct SoundSetting: View {
    let title: String
    let path: WritableKeyPath<Config, String>
    @ObservedObject var model: SettingsModel
    private let chooseFile = "__choose_file__"
    private var current: String { model.config[keyPath: path] }
    var body: some View {
        HStack {
            Picker(title, selection: Binding(get: { current }, set: { value in
                if value == chooseFile { model.chooseSoundFile(path) }
                else { model.edit { $0[keyPath: path] = value } }
            })) {
                Text("None").tag("")
                ForEach(model.soundNames, id: \.self) { Text($0).tag($0) }
                if !current.isEmpty && !model.soundNames.contains(current) {
                    Text(URL(fileURLWithPath: current).lastPathComponent).tag(current)
                }
                Text("Choose File…").tag(chooseFile)
            }
            Button("Preview") { model.preview(current) }.disabled(current.isEmpty)
        }
    }
}
