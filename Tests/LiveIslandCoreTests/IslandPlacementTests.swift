import CoreGraphics
import Testing
@testable import LiveIslandCore

@Suite("Island placement")
struct IslandPlacementTests {
    /// A 1920×1080 display to the right of the main one.
    let screen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    let pill = CGSize(width: 200, height: 24)
    let canvas = CGSize(width: 760, height: 370)

    func geometry(_ x: Double, _ y: Double) -> FloatingGeometry {
        FloatingGeometry(placement: IslandPlacement(x: x, y: y), screen: screen, pill: pill, canvas: canvas)
    }

    @Test func savesAndRestores() {
        let placement = IslandPlacement(x: 0.25, y: 0.75)
        #expect(IslandPlacement(saved: placement.saved) == placement)
        #expect(IslandPlacement(saved: nil) == nil)
        #expect(IslandPlacement(saved: "") == nil)
        #expect(IslandPlacement(saved: "left") == nil)
        #expect(IslandPlacement(saved: "nan,0.5") == nil)
        #expect(IslandPlacement(saved: "3,-1") == IslandPlacement(x: 1, y: 0))
    }

    @Test func remembersWhereItWasDroppedAsAFractionOfTheDisplay() {
        let placement = IslandPlacement(center: CGPoint(x: 1512 + 480, y: 270), in: screen)
        #expect(placement == IslandPlacement(x: 0.25, y: 0.25))
    }

    @Test func thePillSitsWhereItWasPlaced() {
        let middle = geometry(0.5, 0.5)
        #expect(middle.pill.midX == screen.midX)
        #expect(middle.pill.midY == screen.midY)
    }

    @Test func nearTheTopItOpensDownward() {
        let top = geometry(0.5, 0.9)
        #expect(top.opensDown)
        let open = top.island(size: CGSize(width: 680, height: 300))
        #expect(open.maxY == top.pill.maxY)
        #expect(top.window.contains(open))
    }

    @Test func nearTheBottomItOpensUpward() {
        let bottom = geometry(0.5, 0.05)
        #expect(!bottom.opensDown)
        let open = bottom.island(size: CGSize(width: 680, height: 300))
        #expect(open.minY == bottom.pill.minY)
        #expect(bottom.window.contains(open))
    }

    @Test func inACornerTheOpenIslandSlidesBackOntoTheScreen() {
        for (x, y) in [(0.0, 1.0), (1.0, 1.0), (0.0, 0.0), (1.0, 0.0)] {
            let corner = geometry(x, y)
            #expect(screen.contains(corner.pill))
            #expect(screen.contains(corner.window))
            let open = corner.island(size: CGSize(width: 680, height: 300))
            #expect(screen.contains(open))
            #expect(corner.window.contains(open))
        }
    }

    @Test func theIdlePillStaysOnThePillWhereThereIsRoom() {
        let corner = geometry(0, 1)
        #expect(corner.island(size: pill) == corner.pill)
    }

    @Test func aScreenShorterThanTheWindowStillKeepsThePillOnItsEdge() {
        let short = FloatingGeometry(placement: IslandPlacement(x: 0.5, y: 0.5),
                                     screen: CGRect(x: 0, y: 0, width: 1000, height: 300), pill: pill, canvas: canvas)
        #expect(short.island(size: pill).maxY <= short.window.maxY)
        #expect(short.island(size: pill).minY >= short.window.minY)
    }
}
