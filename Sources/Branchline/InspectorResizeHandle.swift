import SwiftUI

struct InspectorResizeHandle: View {
    @Binding var width: Double
    var maximum: Double
    @LocalState private var initial: Double?
    @LocalState private var hovering = false
    var body: some View {
        Rectangle().fill(hovering ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07))
            .frame(width: 6).contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if initial == nil { initial = min(width, maximum) }
                    width = min(maximum, max(260, (initial ?? width) - value.translation.width))
                }.onEnded { _ in initial = nil })
            .accessibilityLabel("调整详情宽度")
            .accessibilityValue("\(Int(width))")
            .accessibilityAdjustableAction { direction in
                width = min(maximum, max(260, width + (direction == .increment ? 30 : -30)))
            }
    }
}
