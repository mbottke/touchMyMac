//
//  DebugView.swift
//  TouchMyMac
//
//  Created by Sebastian Hueber on 11.02.23.
//

import SwiftUI
import AppKit
import TouchUpCore

struct DebugView: View {
    
    @ObservedObject var model: TouchMyMac
    
    let closeAction: ()->Void
    
    var pixelsPerMM: CGFloat
    
    init(model: TouchMyMac, closeAction: @escaping ()->Void) {
        self.model = model
        self.pixelsPerMM = model.touchscreen()?.pixelsPerMM() ?? 30
        self.closeAction = closeAction
    }
    
    func colorForPhase(_ phase: NSTouch.Phase) -> Color {
        switch phase {
        case .stationary:
            return Color.yellow
            
        case .began:
            return Color.blue
            
        case .ended:
            return Color.red
    
        case .cancelled:
            return Color.orange
            
        default:
            return Color.green
        }
    }
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { context in
        ZStack(alignment: .bottom) {
            
            Rectangle()
                .foregroundColor(Color(white: 0.1))
                .frame(maxWidth:.infinity, maxHeight: .infinity)
                .overlay(GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        
                        
                        ForEach(model.touches, id:\.uuid) { point in
                            let ageMs = Int(context.date.timeIntervalSince(point.lastUpdatedAt) * 1000)

                            Circle()
                                .foregroundColor(colorForPhase(point.phase))
                                .border(Color.gray, width: point.confidenceFlag ? 5 : 0)
                                .opacity(point.isActive() ? 1 : 0.5)
                                .frame(width: 16 * pixelsPerMM, height: 16 * pixelsPerMM)
                                .position(x: geo.size.width * point.location.x,
                                          y: geo.size.height * point.location.y)

                            Text("\(point.contactID)\nS:\(point.isOnSurface ? 1 : 0)  V:\(point.confidenceFlag ? 1 : 0)\nA:\(ageMs)ms")
                                .multilineTextAlignment(.center)
                                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .background(Color.black.opacity(0.45))
                                .cornerRadius(6)
                            .position(x: geo.size.width * point.location.x,
                                      y: geo.size.height * point.location.y)
                            
                        }
                        
                        
                    }
                })
            
            
            Button(action: {
                closeAction()
            }, label: {
                HStack {
                    Text("Close overlay with ")
                    Label("W", systemImage: "command.square.fill")
                    Text("or by mouse-clicking here")
                }
                .font(.largeTitle)
                .modify {
                    if #available(macOS 13.0, *) {
                        $0.fontDesign(.rounded)
                    } else { $0 }
                }
            })
            .foregroundColor(.gray)
            .buttonStyle(.borderless)
            .keyboardShortcut(KeyEquivalent("w"), modifiers: [.command])
            .padding(.bottom, 140)
        }
        }
        
            
    }
}

struct DebugView_Previews: PreviewProvider {
    static var previews: some View {
        DebugView(model: TouchMyMac(), closeAction: {})
    }
}


extension View {
    func modify<T: View>(@ViewBuilder _ modifier: (Self) -> T) -> some View {
        return modifier(self)
    }
}
