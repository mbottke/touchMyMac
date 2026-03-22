//
//  SettingsView.swift
//  TouchMyMac
//
//  Created by Sebastian Hueber on 03.02.23.
//

import SwiftUI
import TouchUpCore

struct SettingsView: View {
    
    @ObservedObject var model: TouchMyMac
    
    static let diagnosticsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
    
    var welcomeBanner: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to TouchMyMac")
                    .font(.largeTitle)
                Text("TouchMyMac converts USB HID data from touchscreen devices to mouse events.\nInjecting mouse events requires Accessibility access. You can allow this by clicking the button below.")
            }
            
            HStack {
                Spacer()
                Button {
                    model.grantAccessibilityAccess()
                } label: {
                    
                    Text("Grant Accessibility Access")
                }
                .buttonStyle(BorderedProminentButtonStyle())
            }
        }
    }
    
    var top: some View {
        Group {
            Toggle(model.uiLabels(for: \.isPublishingMouseEventsEnabled).title, isOn: $model.isPublishingMouseEventsEnabled)
            
            let id_: Binding<UInt> = Binding {return (model.connectedTouchscreen?.id) ?? 0}
            set: { value in
                model.connectedTouchscreen = model.connectedScreens.first(where:{$0.id == value})
                model.rememeberCues()
            }

            Picker(model.uiLabels(for: \.connectedTouchscreen).title, selection: id_) {
                ForEach(model.connectedScreens) {
                    Text($0.name).tag($0.id)
                }
            }
        }
    }
    
    
    var gestureSettings: some View {
        Group {
            Toggle(isOn: $model.isSecondaryClickEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isSecondaryClickEnabled))
            }
            
            Toggle(isOn: $model.isMagnificationEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isMagnificationEnabled))
            }
        }
    }
    
    
    var parameterSettings: some View {
        Group {
            Slider(value: $model.holdDuration, in: 0.0...0.16, step: 0.02){
                SettingsExplanationLabel(labels: model.uiLabels(for: \.holdDuration))
            }
            
            Slider(value: $model.doubleClickDistance, in: 0...8, step: 1) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.doubleClickDistance))
            }
        }
    }

    var scrollSettings: some View {
        Group {
            Toggle(isOn: $model.isScrollInertiaEnabled) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.isScrollInertiaEnabled))
            }

            let amount: Binding<Double> = Binding {
                Double(model.scrollInertiaVelocityMultiplier)
            } set: { value in
                model.scrollInertiaVelocityMultiplier = CGFloat(value)
            }

            Slider(value: amount, in: 0.5...2.0, step: 0.05) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.scrollInertiaVelocityMultiplier))
            }
            .disabled(!model.isScrollInertiaEnabled)

            let decel: Binding<Double> = Binding {
                Double(model.scrollInertiaDecelerationPerFrame)
            } set: { value in
                model.scrollInertiaDecelerationPerFrame = CGFloat(value)
            }

            Slider(value: decel, in: 0.85...0.99, step: 0.005) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.scrollInertiaDecelerationPerFrame))
            }
            .disabled(!model.isScrollInertiaEnabled)
        }
    }
    
    
    var troubleshootingSettings: some View {
        Group {
            let errorResistance_ = Binding {Double(model.errorResistance)} set: {
                model.errorResistance = NSInteger(Int($0)) }
            
            Slider(value: errorResistance_ , in: 0...10, step: 1) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.errorResistance))
            }
            
            Toggle(isOn: $model.ignoreOriginTouches) {
                SettingsExplanationLabel(labels: model.uiLabels(for: \.ignoreOriginTouches))
            }
            
            Button(action: {
                (NSApp.delegate as? AppDelegate)?.showDebugOverlay()
            }, label: {
                HStack {
                    Text("Open Fullscreen Test Environment")
                    Spacer()
                    Image(systemName: "arrow.up.forward.app.fill")
                }
                
            })
            .foregroundColor(.accentColor)
            .buttonStyle(PlainButtonStyle())
            
            diagnosticsPanel
            
        }
    }
    
    var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Diagnostics")
                .font(.headline)
            
            Text("Status: \(model.suggestedBlocker())")
                .foregroundColor(.secondary)
                .font(.caption)
            
            Group {
                Text("Accessibility (Cached): \(model.isAccessibilityAccessGranted ? "Granted" : "Missing")")
                Text("Accessibility (Live): \(model.accessibilityTrustedNow ? "Granted" : "Missing")")
                Text("Input Enabled: \(model.isPublishingMouseEventsEnabled ? "Yes" : "No")")
                Text("Connection: \(String(describing: model.connectionState))")
                Text("Connected Screens: \(model.connectedScreens.count)")
                Text("Assigned Screen: \(model.connectedTouchscreen?.name ?? "(Auto)")")
                Text("Touch Reports: \(model.touchUpdateCount)")
                Text("Last Active Touches: \(model.lastActiveTouchCount)")
                Text("Gesture Decisions: \(model.gestureDecisionCount)")
                Text("Current Gesture: \(model.currentGestureName)")
                Text("Current Action: \(model.currentActionName)")
                Text("Last Gesture -> Action: \(model.lastGestureName) -> \(model.lastActionName)")
                Text("Input Frame: \(model.inputProcessFrameID)")
                Text("Input Active Touches: \(model.inputActiveTouchCount)")
                Text("3F Session: \(model.threeFingerTracking ? "Active" : "Idle")")
                Text("3F Triggered: \(model.threeFingerTriggered ? "Yes" : "No")")
                Text("3F Touches/Upward: \(model.threeFingerTouchCount)/\(model.threeFingerUpwardTouchCount)")
                Text(String(format: "3F Travel V/H: %.1f / %.1f mm", model.threeFingerVerticalTravelMM, model.threeFingerHorizontalTravelMM))
                Text("HID Connect/Disconnect: \(model.hidConnectCount)/\(model.hidDisconnectCount)")
                Text("Last Touch Update: \(formatDate(model.lastTouchUpdateAt))")
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            
            HStack {
                Button("Restart Input Pipeline") {
                    model.restartInputPipeline()
                }
                Button("Refresh Touch Connection") {
                    model.refreshTouchConnection()
                }
                Button("Reset Diagnostics") {
                    model.resetDiagnostics()
                }
                Button("Test Click") {
                    model.sendTestClickAtCursor()
                }
                Button("Test Scroll") {
                    model.sendTestScroll()
                }
            }
            .buttonStyle(.borderless)
            .foregroundColor(.accentColor)
            
            if !model.diagnosticsEvents.isEmpty {
                Divider()
                ForEach(Array(model.diagnosticsEvents.prefix(8))) { event in
                    Text("[\(formatDate(event.time))] \(event.message)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            if !model.recentGestureEvents.isEmpty {
                Divider()
                Text("Recent Gesture Stream")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(Array(model.recentGestureEvents.prefix(10))) { event in
                    Text("[\(formatDate(event.time))] \(event.message)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
    
    func formatDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        return Self.diagnosticsDateFormatter.string(from: date)
    }
    
    
    var footer: some View {
        HStack {
            Spacer()
            VStack {
                if let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("TouchMyMac v\(versionString)")
                        .font(.title2)
                }

                Text("Touch input for macOS")
                    .font(.footnote)
                
                Link(destination: URL(string: "https://github.com/shueber/TouchMyMac")!, label: {
                    Label("GitHub", systemImage: "link")
                        .foregroundColor(.accentColor)
                })
            }
            .padding(.vertical)
            Spacer()
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        
    }
    
    var container: some View {
        if #available(macOS 13.0, *) {
            return Form {
                if !model.isAccessibilityAccessGranted {
                    Section {
                        welcomeBanner
                    } footer: {
                        Rectangle()
                            .frame(width:0, height:0)
                            .foregroundColor(.clear)
                    }

                }
                
                Section {
                    top
                }

                Section("Gestures") {
                    gestureSettings
                }
                
                Section("Parameters") {
                    parameterSettings
                }

                Section("Scroll") {
                    scrollSettings
                }

                Section {
                    troubleshootingSettings
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    footer
                }



            }
            .formStyle(.grouped)

        } else {
            return List {
                LegacySection {
                    top
                }
                
                LegacySection(title: "Gestures") {
                    gestureSettings
                }
                
                LegacySection(title: "Parameters") {
                    parameterSettings
                }

                LegacySection(title: "Scroll") {
                    scrollSettings
                }
                
                LegacySection(title: "Troubleshooting") {
                    troubleshootingSettings
                }
                
                footer
                
            }
            .toggleStyle(.switch)
            
        }
    }
    
    
    
    var body: some View {
        container
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 350,  maxHeight: .infinity)
        
    }
}


struct LegacySection<Content: View>: View {
    var title: String? = nil
    var content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading) {
            if let title = title {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 12)
            }
            
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .foregroundColor(.secondary.opacity(0.1))
                    .shadow(radius: 1)
                    
                    
                
                VStack(alignment: .leading, spacing: 16, content: content)
                    .padding(12)
            }
            
        }
        .padding(.bottom)
    }
}


struct SettingsExplanationLabel: View {
    
    let labels: (title:String, description:String)
    
    var body: some View {
        VStack(alignment:.leading, spacing: 4) {
            Text(labels.title)
            Text(labels.description)
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }
}



struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(model: TouchMyMac())
    }
}
