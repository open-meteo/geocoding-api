import Foundation
import Vapor


protocol QuadTreeElement {
    var latitude: Float {get}
    var longitude: Float {get}
}

extension QuadTreeElement {
    /// Aproximated distance
    @inlinable func distanceKilometers(latitude: Float, longitude: Float) -> Float {
        return sqrt(powf(self.latitude - latitude, 2) + powf(self.longitude - longitude, 2)) / 360 * 40030
    }
}

extension GeocodingDatabase.Geoname: QuadTreeElement {}

/**
 Order all points in tiles of latitude and longitudes
 */
extension GeocodingDatabase.GeoTree {
    public init<T: QuadTreeElement>(elements: [Int32: T], depth: Int? = nil, logger: Logger? = nil) {
        let maxDepth = depth ?? Int(log2f(Float(elements.count / 2000)) / log2f(2))
        
        var ordered: [Int32] = elements.map{$0.0}
        /// Store the left hand side value of each tile
        var values = [Float]()
        let totalTiles = (0..<maxDepth).reduce(0, {$0 + Int(pow(2, Double($1)))}) * 2
        
        values.reserveCapacity(totalTiles)
        
        /// Itterate through all points, split in half, order by latigude, split in half, order by longitude
        var doLatitude = true
        for z in 0..<maxDepth {
            /// Number of tiles at this level
            let tileCount = Int(pow(2, Double(z)))
            let pointsPerTile = ordered.count.divideCeiled(by: tileCount)
            logger?.info("level \(z) / \(maxDepth), tiles=\(tileCount), pointsPerTile=\(pointsPerTile)")
            for i in 0..<tileCount {
                let range = pointsPerTile * i ..< min(pointsPerTile * (i+1), ordered.count)
                if doLatitude {
                    ordered[range].sort(by: {elements[$0]!.latitude < elements[$1]!.latitude})
                    values.append(elements[ordered[range.lowerBound]]!.latitude)
                    values.append(elements[ordered[range.upperBound-1]]!.latitude)
                } else {
                    ordered[range].sort(by: {elements[$0]!.longitude < elements[$1]!.longitude})
                    values.append(elements[ordered[range.lowerBound]]!.longitude)
                    values.append(elements[ordered[range.upperBound-1]]!.longitude)
                }
            }
            doLatitude = !doLatitude
        }
        
        self.ordered = ordered
        self.values = values
        assert(values.count == totalTiles)
    }
    
    public func maxDepth() -> Int {
        var sum = 0
        for z in 0..<1000 {
            sum += Int(pow(2, Double(z)))
            if sum * 2 == values.count {
                return z+1
            }
        }
        fatalError()
    }
    
    public func knn<T: QuadTreeElement>(latitude: Float, longitude: Float, count: Int, maxDistanceKilometer: Float, elements: [Int32: T]) -> [(id: Int32, distance: Float)] {
        
        let deltaLat = (maxDistanceKilometer / (6371 * .pi * 2)) * 360
        let deltaLon = asin(sin(maxDistanceKilometer / 6371) / cos(latitude.degreeToRadians)).radiansToDegree
        
        let queue = DistanceQueue(length: count)
        let searchLatitudeRange = latitude - deltaLat ... latitude + deltaLat
        let searchLongitudeRange = longitude - deltaLon ... longitude + deltaLon
        let maxDepth = maxDepth()
        //print("maxDepth=\(maxDepth), searchLatitudeRange=\(searchLatitudeRange), searchLongitudeRange=\(searchLongitudeRange)")
        
        let tilesPerDepth = (0..<maxDepth).map { z in
            Int(pow(2, Double(z)))
        }
        let valuesOffsets = (0..<maxDepth).map { z in
            (0..<z).reduce(0, { $0 + Int(pow(2, Double($1)))*2})
        }
        
        var z = 0
        var tileIndex = 0
        var indexAtDepth = [Int](repeating: 0, count: maxDepth)
        var checkedLeftHalf = [Bool](repeating: false, count: maxDepth)
        
        /// Recurively search
        while(true) {
            //print("z=\(z) tileIndex=\(tileIndex)")
            // For each tile, we can check if the bound match, if yes, go down one layer and check left/right half
            if tileIndex == tilesPerDepth[z] {
                // go up
                guard z > 1 else {
                    //print("search finished")
                    break
                }
                //print("go up again, because end reached")
                tileIndex = indexAtDepth[z-1]
                z = z-1
                continue
            }
            
            // mark this tile as searched
            indexAtDepth[z] = tileIndex + 1
            
            let valueOffset = valuesOffsets[z] + tileIndex * 2
            let valueRange = values[valueOffset] ... values[valueOffset+1]
            let doLatitude = z % 2 == 0
            
            //print("z=\(z) tileIndex=\(tileIndex) doLatitude=\(doLatitude) valueOffset=\(valueOffset) valueRange=\(valueRange)")
            
            // check if value range matches
            if valueRange.overlaps(doLatitude ? searchLatitudeRange : searchLongitudeRange) {
                if z != maxDepth - 1 {
                    //print("matched, going down")
                    // go down
                    z = z+1
                    tileIndex = tileIndex * 2
                    checkedLeftHalf[z] = false
                    continue
                }
                // perform search
                let pointsPerTile = ordered.count.divideCeiled(by: tilesPerDepth[z])
                let range = pointsPerTile * tileIndex ..< min(pointsPerTile * (tileIndex+1), ordered.count)
                //print("matched, adding values, range=\(range)")
                for i in ordered[range] {
                    let distance = elements[i]!.distanceKilometers(latitude: latitude, longitude: longitude)
                    guard distance <= maxDistanceKilometer else {
                        continue
                    }
                    queue.insert(id: i, priority: distance)
                }
            }
            
            if checkedLeftHalf[z] {
                // go up
                //print("go up again")
                tileIndex = indexAtDepth[z-1]
                z = z-1
            } else {
                // check right half
                //print("check right half")
                checkedLeftHalf[z] = true
                tileIndex += 1
            }
        }
        return queue.queue
    }
}

extension Float {
    @inlinable var radiansToDegree: Float {
        return self * 180 / .pi
    }
    @inlinable var degreeToRadians: Float {
        return self / 180 * .pi
    }
}

public final class DistanceQueue {
    public var queue: [(id: Int32, distance: Float)]
    
    public init(length: Int) {
        queue = [(Int32, Float)](repeating: (0, 1000000000), count: length)
    }
    
    public func insert(id: Int32, priority: Float) {
        guard let pos = queue.firstIndex(where: {
            if $0.distance == priority {
                return $0.id < id
            }
            return $0.distance >= priority
        }) else {
            return
        }
        if pos < queue.count - 1 {
            queue[pos+1..<queue.count] = queue[pos ..< queue.count-1]
        }
        queue[pos] = (id, priority)
    }
}

extension Int {
    func divideCeiled(by divisor: Int) -> Int{
        let div = self / divisor
        let remainig = self % divisor
        return remainig == 0 ? div : div + 1
    }
}
