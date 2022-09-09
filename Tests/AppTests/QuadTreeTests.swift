import XCTest
@testable import App

struct Point: QuadTreeElement {
    let latitude: Float
    let longitude: Float
}

final class QuadTreeTests: XCTestCase {
    func testInsert() {
        return
        var points: [Int32: Point] = [:]
        for i in 0..<256 {
            points[Int32(i)] = Point(latitude: Float(i)/10, longitude: Float(i)/10)
        }
        let tree = GeocodingDatabase.GeoTree(elements: points, depth: 5)
        print(tree.ordered)
        print(tree.values)
        
        let res = tree.knn(latitude: 0.72, longitude: 0.71, count: 5, maxDistanceKilometer: 500, elements: points)
        print(res)
        XCTAssertEqual(res[0].id, 7)
        XCTAssertEqual(res[0].distance, 2.486387)
        XCTAssertEqual(res[1].id, 8)
        XCTAssertEqual(res[1].distance, 13.3895855)

        //return
        for i in 0..<200 {
            let res = tree.knn(latitude: Float(i)/10+0.02, longitude: Float(i)/10+0.01, count: 5, maxDistanceKilometer: 500, elements: points)
            print(res)
            XCTAssertEqual(res[0].id, Int32(i))
            XCTAssertNotEqual(res[1].id, Int32(i))
        }
    }
}
