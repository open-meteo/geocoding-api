/**
 boot:
 - read geoname & alternate txt file
 - do we need a preprocess step?? sqlite? just use sql lite fulltext search?
 - initialse id hash table
 - initilaise search tree (transfer special chacters like å to a, ß to s. Preverse spaces for "New york"... index fuzzy with "New yrk"?
 
 multi pass:
 - first load countries, then admin1, then admin2, admin3?
 */

import Foundation
import Vapor


extension GeocodingDatabase.SearchTree {
    public func search(_ search: Substring, results: PriorityQueue, onlyExact: Bool = false, factor: Float = 1.5, geonames: [Int32: GeocodingDatabase.Geoname]) {
        guard let next = search.first else {
            /// search string finished, append everything afterwards
            for id in ids {
                results.insert(id: id, priority: factor + geonames[id]!.ranking)
            }
            if onlyExact {
                return
            }
            for b in buffer {
                results.insert(id: b.id, priority: factor / Float(b.remaining.count + 1) + geonames[b.id]!.ranking)
            }
            for b in branches {
                b.value.search(search, results: results, onlyExact: onlyExact, factor: factor / 2, geonames: geonames)
            }
            return
        }
        for b in buffer {
            if b.remaining == search {
                results.insert(id: b.id, priority: factor + geonames[b.id]!.ranking)
                continue
            }
            if onlyExact {
                continue
            }
            if b.remaining.starts(with: search) {
                results.insert(id: b.id, priority: factor / Float(b.remaining.count + 1) + geonames[b.id]!.ranking)
            }
        }
        branches[String(next)]?.search(search.dropFirst(), results: results, onlyExact: onlyExact, geonames: geonames)
    }
}

/**
 Similar to SearchTree, but mutable. While creating the database, it is used to add entries
 */
final class SearchTreeLoader {
    /// fully matching IDs
    var ids = [Int32]()
    
    var branches = [String: SearchTreeLoader]()
    
    /// keep up to 4096 entries before node split
    var buffer = [GeocodingDatabase.PartialName]()
    
    public func add(_ str: String, id: Int32) {
        let stripped = str.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        self.addInternal(Substring(stripped), id: id)
    }
        
    private func addInternal(_ str: Substring, id: Int32) {
        guard let charOrg = str.first else {
            if !ids.contains(id) {
                ids.append(id)
            }
            return
        }
        let char = String(charOrg)
        if branches.isEmpty {
            var p = GeocodingDatabase.PartialName()
            p.remaining = String(str)
            p.id = id
            buffer.append(p)
            if buffer.count >= 4096 {
                for e in buffer {
                    let char = String(e.remaining.first!)
                    if branches[char] == nil {
                        branches[char] = Self.init()
                    }
                    branches[char]?.addInternal(e.remaining.dropFirst(), id: e.id)
                }
                buffer.removeAll()
            }
            return
        }
        if branches[char] == nil {
            branches[char] = Self.init()
        }
        branches[char]?.addInternal(str.dropFirst(), id: id)
    }
    
    /// Convert to immutable SearchTree structure
    public func immutable() -> GeocodingDatabase.SearchTree {
        var s = GeocodingDatabase.SearchTree()
        s.branches = branches.mapValues({$0.immutable()})
        s.ids = ids
        s.buffer = buffer
        return s
    }
}


/// Order search results by priority
public final class PriorityQueue {
    public var queue: [(id: Int32, priority: Float)]
    
    public init(length: Int) {
        queue = [(Int32, Float)](repeating: (0, 0), count: length)
    }
    
    public func insert(id: Int32, priority: Float) {
        // if duplicate id, remove it and then insert like regular
        if let duplicate = queue.firstIndex(where: {$0.id == id}) {
            if queue[duplicate].priority >= priority {
                return
            }
            if duplicate < queue.count-1 {
                // remove it from queue
                queue[duplicate..<queue.count-1] = queue[duplicate+1..<queue.count]
            }
        }
        guard let pos = queue.firstIndex(where: {
            if $0.priority == priority {
                return $0.id > id
            }
            return $0.priority <= priority
        }) else {
            return
        }
        if pos < queue.count - 1 {
            queue[pos+1..<queue.count] = queue[pos ..< queue.count-1]
        }
        queue[pos] = (id, priority)
    }
}
