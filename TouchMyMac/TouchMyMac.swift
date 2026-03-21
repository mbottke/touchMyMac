//
//  Model.swift
//  TouchMyMac
//
//  Created by Sebastian Hueber on 03.02.23.
//

import AppKit
import Combine
import TouchUpCore

struct DiagnosticsEvent: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
}

class TouchMyMac: NSObject, ObservableObject {
    
    let touchManager: TUCTouchInputManager
    @Published var touches = [TUCTouch]()
    
    
    var observers = [AnyCancellable]()
    
    
    @Published var isPublishingMouseEventsEnabled = true
    
    @Published var connectionState: ConnectionState = .disconnected
    
    
    
    @Published var holdDuration: TimeInterval = 0.1
    @Published var doubleClickDistance: CGFloat = 3 //mm
    @Published var errorResistance: NSInteger = 0 // num of Reports to wait before cancelling a touch
    @Published var ignoreOriginTouches: Bool = false
    
    
    
    @Published var isSecondaryClickEnabled = false
    @Published var isMagnificationEnabled = false
    @Published var isClickWindowToFrontEnabled = false

    @Published var isScrollInertiaEnabled = true
    @Published var scrollInertiaDecelerationPerFrame: CGFloat = 0.95
    @Published var scrollInertiaVelocityMultiplier: CGFloat = 1.0
    
    
    
    @Published var connectedScreens = [TUCScreen]()
    var connectedTouchscreen: TUCScreen?
    
    var lastDateUSBAdded: Date?
    var lastDateScreenAdded: Date?
    var idOfLastAddedScreen: UInt?
    
    let hotPlugTimeInterval: TimeInterval = 10
    
    
    @Published var isAccessibilityAccessGranted = false
    @Published var touchUpdateCount: Int = 0
    @Published var lastTouchUpdateAt: Date?
    @Published var lastActiveTouchCount: Int = 0
    @Published var gestureDecisionCount: Int = 0
    @Published var lastGestureName: String = "-"
    @Published var lastActionName: String = "-"
    @Published var lastGestureDecisionAt: Date?
    @Published var currentGestureName: String = "-"
    @Published var currentActionName: String = "-"
    @Published var recentGestureEvents: [DiagnosticsEvent] = []
    @Published var hidConnectCount: Int = 0
    @Published var hidDisconnectCount: Int = 0
    @Published var diagnosticsEvents: [DiagnosticsEvent] = []
    
    private var lastGestureLogAt: Date?
    private var lastGestureSignature: String = ""
    
    // MARK: - Attempt to automatically determine touch screen
    
    
    
    var identificationCues: (name:String, id:UInt) {
        get {
            let name = UserDefaults.standard.string(forKey: "touchscreenNameCue") ?? "Digital"
            let id   = UserDefaults.standard.integer(forKey: "touchscreenIDCue")
            return (name, UInt(id))
        }
    }
    
    func rememeberCues() {
        if let connectedTouchscreen = self.touchscreen() {
            UserDefaults.standard.set(connectedTouchscreen.name, forKey: "touchscreenNameCue")
            UserDefaults.standard.set(connectedTouchscreen.id,   forKey: "touchscreenIDCue")
        }
    }
    
    
    /**
     returns true, if the screen list contained the preferred screen which is now assigned the touch screen.
     if screen list empty, it removes the assigned touch screen.
     */
    @discardableResult func identifyPreferredOrNoScreen() -> Bool {
        let cues = identificationCues
        
        
        if connectedScreens.count == 0 {
            self.connectedTouchscreen = nil
            self.connectionState = .uncertain
            print("OH NO SCREEN")
            return true
        }
        
       
        
        if let perfectMatch = connectedScreens.first(where: { $0.matching(name: cues.name, id: cues.id) == 1}) {
            self.connectedTouchscreen = perfectMatch
            self.connectionState = lastDateUSBAdded == nil ? .connectedPreferred : .connectedHotPlug
            print("PREFERRED SCREEN FOUND")
            return true
        }
        
        return false
    }
    
    
    @discardableResult func identifyHotPlug() -> Bool {
        // if the USB cable of a touch screen was plugged in within last 10 seconds, assign this to the touchscreen
        
        // no need to hot plug during existing connection
        if self.connectionState.isConnected {
            print("HOTPLUG SKIPPED")
            return false
        }
        
        if let lastDateUSBAdded, let lastDateScreenAdded, let idOfLastAddedScreen {
            if Date().timeIntervalSince(lastDateUSBAdded) < hotPlugTimeInterval
                && Date().timeIntervalSince(lastDateScreenAdded) < hotPlugTimeInterval {
                
                
                if let screen = self.connectedScreens.first(where: {$0.id == idOfLastAddedScreen}) {
                    self.connectedTouchscreen = screen
                    let cues = identificationCues
                    let match = screen.matching(name: cues.name, id: cues.id)
                    self.connectionState = match == 1 ? .connectedPreferred : .connectedHotPlug
                    print("HOTPLUG SUCCESS")
                    return true
                }
                
                print("HOTPLUG FAIL")
            }
        }
        
        return false
    }
    
    
    @objc func screenParametersDidChange() {
        // identify which screen is newly added.
        let oldScreenList = self.connectedScreens
        self.connectedScreens = TUCScreen.allScreens() as! [TUCScreen]
        
        // a new screen appeared!
        if connectedScreens.count > oldScreenList.count {
            self.lastDateScreenAdded = Date()
            
            let new = connectedScreens.first { s in
                !(oldScreenList.contains(where: {$0.id == s.id}))
            }
            if let new {
                self.idOfLastAddedScreen = new.id
                identifyHotPlug()
            }
        }
        
        // search for the preferred screen, also important if user rearranged screens (and screen numbers)
        if !self.identifyPreferredOrNoScreen() {
            self.connectedTouchscreen = self.connectedScreens.last
        }
    }
    
    
    func checkAccessibilityAccessGranted() {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        self.isAccessibilityAccessGranted = AXIsProcessTrustedWithOptions([checkOptPrompt: true] as CFDictionary?)
    }
    
    var accessibilityTrustedNow: Bool {
        AXIsProcessTrusted()
    }
    
    func grantAccessibilityAccess() {
        self.touchManager.triggerSystemAccessibilityAccessAlert()
        (NSApp.delegate as? AppDelegate)?.settingsWindow.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.checkAccessibilityAccessGranted()
        }
        addDiagnosticsEvent("Requested Accessibility access prompt")
    }
    
    
    override init() {
        self.touchManager = TUCTouchInputManager()
        
        super.init()
        
        self.screenParametersDidChange()
        
        self.touchManager.delegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(TouchMyMac.screenParametersDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        initPreferences()
        
        checkAccessibilityAccessGranted()
        addDiagnosticsEvent("Initialized model")
    }
    
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func resetDiagnostics() {
        touchUpdateCount = 0
        lastTouchUpdateAt = nil
        lastActiveTouchCount = 0
        gestureDecisionCount = 0
        lastGestureName = "-"
        lastActionName = "-"
        lastGestureDecisionAt = nil
        currentGestureName = "-"
        currentActionName = "-"
        recentGestureEvents = []
        lastGestureLogAt = nil
        lastGestureSignature = ""
        hidConnectCount = 0
        hidDisconnectCount = 0
        diagnosticsEvents = []
        addDiagnosticsEvent("Diagnostics reset")
    }
    
    func restartInputPipeline() {
        touchManager.stop()
        touchManager.start()
        addDiagnosticsEvent("Restarted HID input pipeline")
    }
    
    func refreshTouchConnection() {
        addDiagnosticsEvent("Refreshing touch connection...")
        connectionState = .uncertain
        
        // Rebuild HID connection and then refresh screen mapping to avoid stale assignment.
        touchManager.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.touchManager.start()
            self.screenParametersDidChange()
            self.checkAccessibilityAccessGranted()
            self.addDiagnosticsEvent("Touch connection refresh requested")
        }
    }
    
    func addDiagnosticsEvent(_ message: String) {
        diagnosticsEvents.insert(DiagnosticsEvent(message: message), at: 0)
        if diagnosticsEvents.count > 40 {
            diagnosticsEvents.removeLast(diagnosticsEvents.count - 40)
        }
    }
    
    func gestureDisplayName(_ gesture: TUCCursorGesture) -> String {
        switch gesture {
        case .TUCCursorGestureTouchDown: return "Touch Down"
        case .TUCCursorGestureTap: return "Tap"
        case .TUCCursorGestureLongPress: return "Long Press"
        case .TUCCursorGestureDrag: return "Drag (1 Finger)"
        case .TUCCursorGestureHoldAndDrag: return "Hold + Drag"
        case .TUCCursorGestureTapSecondFinger: return "Second-Finger Tap"
        case .TUCCursorGestureTwoFingerDrag: return "Two-Finger Drag"
        case .TUCCursorGesturePinch: return "Pinch"
        default: return "Unknown (\(gesture.rawValue))"
        }
    }
    
    func actionDisplayName(_ action: TUCCursorAction) -> String {
        switch action {
        case .none: return "None"
        case .move: return "Move Cursor"
        case .moveClickIfNeeded: return "Move + Bring To Front"
        case .pointAndClick: return "Point and Click"
        case .drag: return "Drag"
        case .click: return "Click"
        case .secondaryClick: return "Secondary Click"
        case .scroll: return "Scroll"
        case .magnify: return "Magnify"
        @unknown default: return "Unknown"
        }
    }
    
    func addGestureEventIfNeeded(gestureName: String, actionName: String) {
        let signature = "\(gestureName)->\(actionName)"
        let now = Date()
        let shouldLog: Bool
        if signature != lastGestureSignature {
            shouldLog = true
        } else if let lastGestureLogAt {
            shouldLog = now.timeIntervalSince(lastGestureLogAt) >= 0.25
        } else {
            shouldLog = true
        }
        
        if shouldLog {
            recentGestureEvents.insert(DiagnosticsEvent(message: "\(gestureName) -> \(actionName)"), at: 0)
            if recentGestureEvents.count > 24 {
                recentGestureEvents.removeLast(recentGestureEvents.count - 24)
            }
            lastGestureSignature = signature
            lastGestureLogAt = now
        }
    }
    
    func suggestedBlocker() -> String {
        if !accessibilityTrustedNow {
            return "Accessibility permission is not active."
        }
        if !isPublishingMouseEventsEnabled {
            return "Mouse event publishing is OFF."
        }
        if !connectionState.isConnected {
            return "No touchscreen HID connection detected."
        }
        if touchUpdateCount == 0 {
            return "No touch reports received yet."
        }
        return "Touch reports are flowing. If output still fails, inspect diagnostics and restart input pipeline."
    }
    
    func sendTestClickAtCursor() {
        let loc = NSEvent.mouseLocation
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: loc, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: loc, mouseButton: .left) else {
            addDiagnosticsEvent("Failed to build test click events")
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        addDiagnosticsEvent("Posted test click at cursor")
    }
    
    func sendTestScroll() {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -80, wheel2: 0, wheel3: 0) else {
            addDiagnosticsEvent("Failed to build test scroll event")
            return
        }
        event.post(tap: .cghidEventTap)
        addDiagnosticsEvent("Posted test scroll event")
    }
    
}


// MARK: - Loading, Saving and Syncing Settings with Framework
extension TouchMyMac {
    
    func initPreferences() {
        let defaults = UserDefaults.standard
        
        defaults.register(defaults: [
            "holdDuration" : 0.1,
            "doubleClickDistance" : 8,
            "errorResistance" : 4,
            "ignoreOriginTouches" : true,
            "isSecondaryClickEnabled" : true,
            "isMagnificationEnabled" : true,
            "isClickWindowToFrontEnabled" : false,
            "isScrollInertiaEnabled" : true,
            "scrollInertiaDecelerationPerFrame" : 0.95,
            "scrollInertiaVelocityMultiplier" : 1.0
        ])
        
        holdDuration = defaults.double(forKey: "holdDuration")
        doubleClickDistance = defaults.double(forKey: "doubleClickDistance")
        errorResistance = defaults.integer(forKey: "errorResistance")
        ignoreOriginTouches = defaults.bool(forKey: "ignoreOriginTouches")
        defaults.removeObject(forKey: "primaryInteractionMode")
        
        
        self.observers = [
            $isPublishingMouseEventsEnabled.assign(to: \.postMouseEvents, on: touchManager),
            $holdDuration.assign(to: \.holdDuration, on: touchManager),
            $doubleClickDistance.assign(to: \.doubleClickTolerance, on: touchManager),
            $errorResistance.assign(to: \.errorResistance, on: touchManager),
            $ignoreOriginTouches.assign(to: \.ignoreOriginTouches, on: touchManager),
            $isScrollInertiaEnabled.assign(to: \.scrollInertiaEnabled, on: touchManager),
            $scrollInertiaDecelerationPerFrame.assign(to: \.scrollInertiaDecelerationPerFrame, on: touchManager),
            $scrollInertiaVelocityMultiplier.assign(to: \.scrollInertiaVelocityMultiplier, on: touchManager)
        ]
        
        
        
        isSecondaryClickEnabled = defaults.bool(forKey: "isSecondaryClickEnabled")
        isMagnificationEnabled = defaults.bool(forKey: "isMagnificationEnabled")
        isClickWindowToFrontEnabled = defaults.bool(forKey: "isClickWindowToFrontEnabled")

        isScrollInertiaEnabled = defaults.bool(forKey: "isScrollInertiaEnabled")
        scrollInertiaDecelerationPerFrame = CGFloat(defaults.double(forKey: "scrollInertiaDecelerationPerFrame"))
        scrollInertiaVelocityMultiplier = CGFloat(defaults.double(forKey: "scrollInertiaVelocityMultiplier"))
        touchManager.scrollInertiaEnabled = isScrollInertiaEnabled
        touchManager.scrollInertiaDecelerationPerFrame = scrollInertiaDecelerationPerFrame
        touchManager.scrollInertiaVelocityMultiplier = scrollInertiaVelocityMultiplier
    }
    
    
    func savePreferences() {
        let defaults = UserDefaults.standard
        
        defaults.set(holdDuration, forKey: "holdDuration")
        defaults.set(doubleClickDistance, forKey: "doubleClickDistance")
        defaults.set(errorResistance, forKey: "errorResistance")
        defaults.set(ignoreOriginTouches, forKey: "ignoreOriginTouches")
        
        defaults.set(isSecondaryClickEnabled, forKey: "isSecondaryClickEnabled")
        defaults.set(isMagnificationEnabled, forKey: "isMagnificationEnabled")
        defaults.set(isClickWindowToFrontEnabled, forKey: "isClickWindowToFrontEnabled")

        defaults.set(isScrollInertiaEnabled, forKey: "isScrollInertiaEnabled")
        defaults.set(Double(scrollInertiaDecelerationPerFrame), forKey: "scrollInertiaDecelerationPerFrame")
        defaults.set(Double(scrollInertiaVelocityMultiplier), forKey: "scrollInertiaVelocityMultiplier")
    }
    
}



extension TouchMyMac: TUCTouchDelegate {
    func touchesDidChange() {
        self.touches = self.touchManager.touchSet.allObjects as! [TUCTouch]
        self.touchUpdateCount += 1
        self.lastTouchUpdateAt = Date()
        self.lastActiveTouchCount = touches.filter { $0.isActive() }.count
    }
    
    
    func touchscreen() -> TUCScreen? {
        self.connectedTouchscreen ?? self.connectedScreens.last
    }

    
    func action(for gesture: TUCCursorGesture) -> TUCCursorAction {
        let action: TUCCursorAction
        switch gesture {
        case .TUCCursorGestureTouchDown:
            action = isClickWindowToFrontEnabled ? .moveClickIfNeeded : .move
            
        case .TUCCursorGestureTap:
            action = .click
            
        case .TUCCursorGestureLongPress:
            action = .click
            
        case .TUCCursorGestureDrag:
            action = .scroll
            
        case .TUCCursorGestureHoldAndDrag:
            action = .drag
            
        case .TUCCursorGestureTapSecondFinger:
            action = isSecondaryClickEnabled ? .secondaryClick : .none
            
        case .TUCCursorGestureTwoFingerDrag:
            action = .scroll
            
        case .TUCCursorGesturePinch:
            action = isMagnificationEnabled ? .magnify : .none
            
        default:
            action = .none
        }
        
        gestureDecisionCount += 1
        lastGestureDecisionAt = Date()
        let gestureName = gestureDisplayName(gesture)
        let actionName = actionDisplayName(action)
        lastGestureName = gestureName
        lastActionName = actionName
        currentGestureName = gestureName
        currentActionName = actionName
        addGestureEventIfNeeded(gestureName: gestureName, actionName: actionName)
        
        return action
    }
    
    
    
    func touchscreenDidConnect() {
        hidConnectCount += 1
        addDiagnosticsEvent("Touchscreen HID connected")
        self.lastDateScreenAdded = Date()
        
        if !self.identifyHotPlug() {
            if self.connectionState.isConnected {
                self.connectionState = .uncertain
            }
        }
        
        self.identifyPreferredOrNoScreen()
    }
    
    func touchscreenDidDisconnect() {
        hidDisconnectCount += 1
        addDiagnosticsEvent("Touchscreen HID disconnected")
        self.connectionState = .disconnected
    }
}


extension TouchMyMac {
    func uiLabels<T>(for keyPath: KeyPath<TouchMyMac, T>) -> (title:String, description:String) {
        switch keyPath {
        case \.isPublishingMouseEventsEnabled:
            return("Control Mouse with Touch",
                   "Turns the driver on or off.")
            
        case \.connectedTouchscreen:
            return("Assign Mouse Events to",
                   "Specifies which screen should receive the touch events.")
            
        case \.isSecondaryClickEnabled:
            return("Secondary Click",
                   "While your pointing finger is resting on the screen, tap another finger in proximity to it to generate a secondary click event at the location of the first finger.")
            
        case \.isMagnificationEnabled:
            return("Magnification",
                   "Pinch two fingers to increase or decrease the size of the content. (EXPERIMENTAL)")
            
        case \.isClickWindowToFrontEnabled:
            return("Bring Windows to Front",
                   "When touching a window that is not frontmost, bring it to front first. (EXPERIMENTAL)")
            
        case \.holdDuration:
            return("Hold Duration",
                   "How long do you have to hold finger to initiate hold&drag")
            
        case \.doubleClickDistance:
            return("Double Click Zone",
                   "How many mm can two taps be apart from each other to qualify double click")
            
        case \.ignoreOriginTouches:
            return("Ignore Origin Touches",
                   "If your touchscreen randomly sends coordinate (0,0) in its datastream, toggle this option to make input more stable.")
            
        case \.errorResistance:
            return("Error Resistance",
                   "If your touchscreen is really unreliable at reporting touches, increase this slider to make inputs more stable at the cost of higher latency in detecting liftoffs.")

        case \.isScrollInertiaEnabled:
            return("Scroll Inertia",
                   "Keeps scrolling for a short time after you lift your finger (iPad-like).")

        case \.scrollInertiaDecelerationPerFrame:
            return("Decay Speed",
                   "Higher values decay slower; lower values decay faster.")

        case \.scrollInertiaVelocityMultiplier:
            return("Inertia Amount",
                   "Scales the starting speed of inertial scrolling.")
            
        default:
            return("\(keyPath)", "")
        }
    }
}


enum ConnectionState: Int {
    case uncertain
    case disconnected
    case connectedHotPlug // connected as result from hot plugging within a few seconds
    case connectedPreferred // connected with stored cues matching perfectly
    
    var image: NSImage? {
        let image: NSImage?
        
        switch self {
        case .uncertain:
            image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        case .disconnected:
            image = NSImage(systemSymbolName: "rectangle.badge.xmark", accessibilityDescription: nil)
        default:
            image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: nil)
        }

        image?.isTemplate = true
        
        return image
    }
    
    var isConnected: Bool {
        return self == .connectedPreferred || self == .connectedHotPlug
    }
}
                 
                 
extension TUCScreen: Identifiable {
    func matching(name:String, id:UInt) -> Float {
        let sameName = self.name == name
        let sameID = self.id == id
        
        if sameName && sameID { return 1 }
        else if sameName { return 0.5 }
        else if sameID { return 0.2 }
        else { return 0}
    }
}
