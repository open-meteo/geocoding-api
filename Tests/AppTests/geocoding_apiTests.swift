import XCTest
@testable import App
import Vapor

final class geocoding_apiTests: XCTestCase {
    
    func testUnicodeNormalisation() {
        let a = "Rügen caractères spéciaux contrairement à la langue française".folding(options: .diacriticInsensitive, locale: nil).lowercased()
        XCTAssertEqual(a, "rugen caracteres speciaux contrairement a la langue francaise")
    }
    
    func testPriorityQueue() {
        let q = PriorityQueue(length: 5)
        q.insert(id: 1, priority: 0.5)
        q.insert(id: 2, priority: 0.6)
        q.insert(id: 3, priority: 0.6)
        // insert a duplicate with a higher priority
        q.insert(id: 3, priority: 0.7)
        q.insert(id: 3, priority: 0.6)
        q.insert(id: 4, priority: 0.6)
        q.insert(id: 5, priority: 0.6)
        q.insert(id: 6, priority: 0.8)
        q.insert(id: 7, priority: 0.0)
        XCTAssertEqual(q.queue[0].id, 6)
        XCTAssertEqual(q.queue[1].id, 3)
        XCTAssertEqual(q.queue[2].id, 2)
        XCTAssertEqual(q.queue[3].id, 4)
        XCTAssertEqual(q.queue[4].id, 5)
    }
    
    func testExample() throws {
        let logger = Logger(label: "test")
        let data = """
            1639953\t2760454\tja\tツークシュピッツェ\t\t\t\t\t\t
            1639954\t2760454\tnl\tZugspitze\t\t\t\t\t\t
            1639955\t2760454\tpt\tZugspitze\t\t\t\t\t\t
            1639956\t2760454\tsk\tZugspitze\t\t\t\t\t\t
            1639957\t2760454\tsv\tZugspitze\t\t\t\t\t\t
            1639958\t2760454\ttr\tZugspitze Dağı\t\t\t\t\t\t
            1904539\t2760454\tit\tZugspitze\t\t\t\t\t\t
            2957082\t2760454\tlink\thttps://en.wikipedia.org/wiki/Zugspitze\t\t\t\t\t\t
            3052258\t2760454\tlink\thttps://ru.wikipedia.org/wiki/%D0%A6%D1%83%D0%B3%D1%88%D0%BF%D0%B8%D1%82%D1%86%D0%B5\t\t\t\t\t\t
            8199248\t2760454\tfa\tتسوگ‌اشپیتسه\t\t\t\t\t\t
            8199249\t2760454\tuk\tЦугшпітце\t\t\t\t\t\t
            8199250\t2760454\tbar\tZugspitz\t\t\t\t\t\t
            8199251\t2760454\tko\t추크슈피체 산\t\t\t\t\t\t
            8199252\t2760454\the\tצוגשפיצה\t\t\t\t\t\t
            8199253\t2760454\tmr\tत्सुगस्पिट्से\t\t\t\t\t\t
            8199254\t2760454\tbe\tГара Цугшпіцэ\t\t\t\t\t\t
            8199255\t2760454\tka\tცუგშპიცე\t\t\t\t\t\t
            8199256\t2760454\tpnb\tسوگسپتزے\t\t\t\t\t\t
            8199257\t2760454\tlt\tCūgšpicė\t\t\t\t\t\t
            8199258\t2760454\tru\tЦугшпитце\t\t\t\t\t\t
            8199259\t2760454\tzh\t楚格峰\t\t\t\t\t\t
            11324584\t2760454\tar\tقمة تسوغشبيتسه\t\t\t\t\t\t
            11324585\t2760454\tmk\tЦугшпице\t\t\t\t\t\t
            15440607\t2760454\twkdt\tQ3375\t\t\t\t\t
            """.data(using: .utf8)!
        
        let names = AlternateNames(data: data, logger: logger)
        XCTAssertEqual(names.alternativesPreferred.count, 1)
        XCTAssertEqual(names.alternativesPreferred[2760454]?.count, 21)
        
        let data2 = """
            1529666\tBahnhof Grenzau\tBahnhof Grenzau\tBahnhof Grenzau,Grenzau\t50.45663\t7.66505\tS\tRSTN\tDE\t\t08\t00\t07143\t07143032\t0\t\t232\tEurope/Berlin\t2020-10-14
            2038682\tBahnhof Annaburg\tBahnhof Annaburg\tAnnaburg,Bahnhof Annaburg,Bahnhof Annaburg West\t51.72858\t13.03311\tS\tRSTN\tDE\t\t11\t\t\t\t0\t\t77\tEurope/Berlin\t2020-10-14
            2657946\tWyhlen\tWyhlen\tWyhlen\t47.54729\t7.69331\tP\tPPLX\tDE\t\t01\t083\t08336\t08336105\t0\t\t269\tEurope/Berlin\t2020-11-12
            2658739\tSchiener Bach\tSchiener Bach\tSchiener Bach\t47.6802\t8.86131\tH\tSTM\tDE\tDE,CH\t00\t\t\t\t0\t\t512\tEurope/Zurich\t2015-09-06
            2659829\tLunkenbach\tLunkenbach\tLunckenbach,Lunkenbach\t47.68136\t8.84938\tH\tSTM\tDE\tDE,CH\t00\t\t\t\t0\t\t462\tEurope/Zurich\t2015-09-06
            2744273\tWitte Venn\tWitte Venn\tWitte Veen,Witte Venn\t52.15\t6.88333\tH\tMRSH\tDE\t\t00\t\t\t\t0\t\t40\tEurope/Amsterdam\t2014-08-05
            2744666\tWesterwoldsche A\tWesterwoldsche A\tWesterwoldsche A,Westerwoldsche Aa,Westerwoldse Aa\t53.23333\t7.2\tH\tSTMC\tDE\t\t00\t\t\t\t0\t\t-1\tEurope/Amsterdam\t2014-08-05
            2745605\tHoge Veenkanal\tHoge Veenkanal\tHoge Veenkanal,Verlangde Hoogeveensche Vaart,Verlengde Hoogeveensche Vaart,Verlengde Hoogeveense Vaart\t52.73333\t6.51667\tH\tCNL\tDE\t\t00\t\t\t\t0\t\t12\tEurope/Amsterdam\t2014-08-05
            """.data(using: .utf8)!
        
        let geonames = GeocodingDatabase.Geonames(data: data2, alternativeNames: names, logger: logger)
        XCTAssertEqual(geonames.geonames.count, 1)
        
        /*let tree = SearchTree.load(geonames: geonames)
        let res = tree.search(Substring("Bahn"))
        XCTAssertEqual(res, [1529666, 2038682])*/
    }
    
    func testPopulationRanking() {
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(0), 0)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(10), 0.038468935)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(1000), 0.03920805)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(10000), 0.046580374)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(50000), 0.09806819)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(100000), 0.22813433)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(200000), 0.6859223)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(500000), 0.9988663)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(1000000), 1.0)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(2000000), 1.0)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(10000000), 1.0)
    }
}
