import Foundation

public enum RouteColors {
    // A separate identifier range preserves every legacy color, including the
    // previously generated colors beyond the original twelve.
    private static let swatchBase = 1_000_000
    public static let swatchIDs = Array(swatchBase..<(swatchBase + 64))
    public static func swatchName(_ id: Int) -> String {
        guard swatchIDs.contains(id) else { return "原有颜色" }
        let offset = id - swatchBase
        let families = ["红", "橙", "黄", "绿", "青", "蓝", "靛", "紫"]
        return "\(families[offset % 8])色 · 明度 \(offset / 8 + 1)"
    }
    // Keep the first six identifiers compatible with existing workspaces.
    public static let palette: [(Double, Double, Double)] = [
        (0.05, 0.39, 0.88), (0.63, 0.18, 0.77), (0.00, 0.52, 0.51),
        (0.82, 0.37, 0.04), (0.29, 0.29, 0.72), (0.43, 0.46, 0.50),
        (0.80, 0.17, 0.25), (0.25, 0.53, 0.12), (0.71, 0.19, 0.49),
        (0.43, 0.34, 0.20), (0.08, 0.48, 0.71), (0.53, 0.48, 0.02)
    ]
    public static func isValid(_ index: Int) -> Bool { (0..<(swatchBase + 64)).contains(index) }
    public static func rgb(_ index: Int) -> (Double, Double, Double) {
        if palette.indices.contains(index) { return palette[index] }
        if swatchIDs.contains(index) {
            let offset = index - swatchBase
            let hues: [Double] = [0, 30, 55, 110, 170, 205, 245, 285]
            let hue = hues[offset % 8] / 60
            let lightness = 0.24 + Double(offset / 8) * 0.075
            let chroma = (1 - abs(2 * lightness - 1)) * 0.72
            let x = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
            let m = lightness - chroma / 2
            let parts: (Double, Double, Double)
            switch Int(hue) { case 0: parts = (chroma,x,0); case 1: parts = (x,chroma,0); case 2: parts = (0,chroma,x); case 3: parts = (0,x,chroma); case 4: parts = (x,0,chroma); default: parts = (chroma,0,x) }
            return (parts.0 + m, parts.1 + m, parts.2 + m)
        }
        let hue = (Double(index) * 0.618033988749895).truncatingRemainder(dividingBy: 1) * 6
        let c = 0.57, x = c * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1)), m = 0.12
        let parts: (Double, Double, Double)
        switch Int(hue) { case 0: parts = (c,x,0); case 1: parts = (x,c,0); case 2: parts = (0,c,x); case 3: parts = (0,x,c); case 4: parts = (x,0,c); default: parts = (c,0,x) }
        return (parts.0 + m, parts.1 + m, parts.2 + m)
    }
    public static func choose(excluding used: Set<Int>) -> Int {
        var candidates = swatchIDs.filter { !used.contains($0) }
        if candidates.isEmpty {
            // Extend the palette instead of recycling an occupied identifier.
            candidates = Array((64..<swatchBase).lazy.filter { !used.contains($0) }.prefix(64))
        }
        func separation(_ index: Int) -> Double {
            let a = rgb(index)
            return used.map { other in
                let b = rgb(other)
                return 0.30 * pow(a.0-b.0,2) + 0.59 * pow(a.1-b.1,2) + 0.11 * pow(a.2-b.2,2)
            }.min() ?? 1
        }
        // Keep several distinct choices available rather than oscillating between
        // the one or two colors within a narrow distance threshold.
        let ranked = candidates.sorted { separation($0) > separation($1) }
        return ranked.prefix(max(8, ranked.count / 3)).randomElement() ?? candidates.first ?? 0
    }
}

extension Workspace {
    public func occupiedRouteColors(excluding id: UUID? = nil) -> Set<Int> {
        Set(projects.filter { $0.id != id && $0.status != .archived }.map(\.color) + branches.filter { $0.id != id && $0.status != .archived }.map(\.color))
    }
    public func availableRouteColor(excluding id: UUID? = nil) -> Int {
        RouteColors.choose(excluding: occupiedRouteColors(excluding: id))
    }
}
