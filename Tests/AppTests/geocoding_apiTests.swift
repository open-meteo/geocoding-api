import Vapor
import XCTest

@testable import App

final class geocoding_apiTests: XCTestCase {

    func testUnicodeNormalisation() {
        let a = "Rügen caractères spéciaux contrairement à la langue française".folding(
            options: .diacriticInsensitive,
            locale: nil
        ).lowercased()
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

    func testZugspitze() throws {
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
        XCTAssertEqual(names.alternativesPreferred[2_760_454]!.count, 21)
        XCTAssertEqual(
            names.languages,
            [
                "ja", "nl", "pt", "sk", "sv", "tr", "it", "fa", "uk", "bar", "ko", "he", "mr", "be",
                "ka", "pnb", "lt", "ru", "zh", "ar", "mk",
            ]
        )
        XCTAssertEqual(
            names.alternativesPreferred[2_760_454]![
                Int32(names.languages.firstIndex(of: "nl")!)
            ]!,
            "Zugspitze"
        )
    }

    func testTallinn() throws {
        let logger = Logger(label: "test")
        let data = """
            343021\t588409\t\tKolyvan\t\t\t\t\t\t
            343022\t588409\t\tRevel'\t\t\t\t\t\t
            343023\t588409\t\tKallinn\t\t\t\t\t\t
            343024\t588409\t\tTallin\t\t\t\t\t\t
            343025\t588409\tfi\tRääveli\t\t\t\t1\t\t
            343026\t588409\t\tTallina\t\t\t\t\t\t
            343027\t588409\t\tReval\t\t\t\t1\t1219\t1918
            343028\t588409\t\tTalinas\t\t\t\t\t\t
            343029\t588409\t\tTallinna\t\t\t\t\t\t
            1565777\t588409\teo\tTalino\t\t\t\t\t\t
            1649593\t588409\tel\tΤαλλίν\t\t\t\t\t\t
            1649731\t588409\tes\tTallin\t\t\t\t\t\t
            1894605\t588409\tfr\tTallinn\t\t\t\t\t\t
            1894606\t588409\tde\tTallinn\t1\t\t\t\t\t
            1894607\t588409\ten\tTallinn\t\t\t\t\t\t
            1894608\t588409\tpl\tTallinn\t\t\t\t\t\t
            1894609\t588409\taf\tTallinn\t\t\t\t\t\t
            1894610\t588409\tam\tታሊን\t\t\t\t\t\t
            1894611\t588409\tar\tتالين\t\t\t\t\t\t
            1894612\t588409\tbe\tТалін\t\t\t\t\t\t
            1894613\t588409\tbg\tТалин\t\t\t\t\t\t
            1894614\t588409\tbr\tTallinn\t\t\t\t\t\t
            1894615\t588409\tca\tTallinn\t\t\t\t\t\t
            1894616\t588409\tco\tTallinn\t\t\t\t\t\t
            1894617\t588409\tcs\tTallinn\t\t\t\t\t\t
            1894618\t588409\tda\tTallinn\t\t\t\t\t\t
            1894619\t588409\tet\tTallinn\t1\t\t\t\t\t
            1894620\t588409\teu\tTallinn\t\t\t\t\t\t
            1894621\t588409\tfi\tTallinna\t1\t\t\t\t\t
            1894622\t588409\tfy\tTallin\t\t\t\t\t\t
            1894623\t588409\tga\tTaillinn\t\t\t\t\t\t
            1894624\t588409\tgl\tTalín\t\t\t\t\t\t
            1894625\t588409\the\tטאלין\t\t\t\t\t\t
            1894626\t588409\thr\tTallinn\t\t\t\t\t\t
            1894627\t588409\thu\tTallinn\t\t\t\t\t\t
            1894628\t588409\thy\tՏալլին\t\t\t\t\t\t
            1894629\t588409\tia\tTallinn\t\t\t\t\t\t
            1894630\t588409\tid\tTallinn\t\t\t\t\t\t
            1894631\t588409\tio\tTallinn\t\t\t\t\t\t
            1894632\t588409\tit\tTallinn\t\t\t\t\t\t
            1894633\t588409\tja\tタリン\t\t\t\t\t\t
            1894634\t588409\tka\tტალინი\t\t\t\t\t\t
            1894635\t588409\tko\t탈린\t\t\t\t\t\t
            1894636\t588409\tla\tCastrum Danorum\t\t\t\t\t\t
            1894637\t588409\tlb\tTallinn\t\t\t\t\t\t
            1894638\t588409\tlt\tTalinas\t\t\t\t\t\t
            1894639\t588409\tlv\tTallina\t\t\t\t\t\t
            1894640\t588409\tro\tТалин\t\t\t\t\t\t
            1894641\t588409\tnds\tRevel\t\t\t\t\t\t
            1894642\t588409\tnl\tTallinn\t\t\t\t\t\t
            1894643\t588409\tnn\tTallinn\t\t\t\t\t\t
            1894644\t588409\tno\tTallinn\t\t\t\t\t\t
            1894645\t588409\tpt\tTallinn\t\t\t\t\t\t
            1894646\t588409\trmy\tTallinn\t\t\t\t\t\t
            1894647\t588409\tro\tTalin\t\t\t\t\t\t
            1894648\t588409\tru\tТаллин\t\t\t\t\t\t
            1894649\t588409\tsk\tTallinn\t\t\t\t\t\t
            1894650\t588409\tsq\tTalini\t\t\t\t\t\t
            1894651\t588409\tsr\tТалин\t\t\t\t\t\t
            1894652\t588409\tsv\tTallinn\t1\t\t\t\t\t
            1894653\t588409\ttg\tТаллин\t\t\t\t\t\t
            1894654\t588409\tth\tทาลลินน์\t\t\t\t\t\t
            1894655\t588409\ttr\tTallinn\t\t\t\t\t\t
            1894656\t588409\ttt\tТаллинн\t\t\t\t\t\t
            1894657\t588409\tudm\tТаллин\t\t\t\t\t\t
            1894658\t588409\tuk\tТаллінн\t\t\t\t\t\t
            1894659\t588409\tyi\tטאלין\t\t\t\t\t\t
            1894660\t588409\tzh\t塔林\t\t\t\t\t\t
            1980143\t588409\tbs\tTalin\t\t\t\t\t\t
            1980144\t588409\tel\tΤαλίν\t1\t\t\t\t\t
            1980145\t588409\tpms\tTàllin\t\t\t\t\t\t
            1980146\t588409\tqu\tTallin\t\t\t\t\t\t
            2080520\t588409\tiata\tTLL\t\t\t\t\t\t
            2920074\t588409\tlink\thttps://en.wikipedia.org/wiki/Tallinn\t\t\t\t\t\t
            5463083\t588409\tel\tΤαλιν\t\t\t\t\t\t
            7119670\t588409\tsv\tReval\t\t\t\t1\t1219\t1918
            8187316\t588409\tkoi\tТаллинн\t\t\t\t\t\t
            8187317\t588409\tmzn\tتالین\t\t\t\t\t\t
            8187318\t588409\tgn\tTalin\t\t\t\t\t\t
            8187319\t588409\tmdf\tТаллинн\t\t\t\t\t\t
            8187320\t588409\tml\tടാലിൻ\t\t\t\t\t\t
            8187321\t588409\tfa\tتالین\t\t\t\t\t\t
            8187322\t588409\tarz\tتالين\t\t\t\t\t\t
            8187323\t588409\thbs\tTalin\t\t\t\t\t\t
            8187324\t588409\tsl\tTalin\t\t\t\t\t\t
            8187325\t588409\tmk\tТалин\t\t\t\t\t\t
            8187326\t588409\tmr\tतालिन\t\t\t\t\t\t
            8187327\t588409\tos\tТаллин\t\t\t\t\t\t
            8187328\t588409\thi\tताल्लिन\t\t\t\t\t\t
            8187329\t588409\tce\tТаллин\t\t\t\t\t\t
            8187330\t588409\tur\tتالین\t\t\t\t\t\t
            8187331\t588409\tky\tТаллин\t\t\t\t\t\t
            8187332\t588409\tckb\tتاڵین\t\t\t\t\t\t
            8187333\t588409\ttpi\tTalin\t\t\t\t\t\t
            8187334\t588409\tmhr\tТаллинн\t\t\t\t\t\t
            8187335\t588409\tmyv\tТаллин ош\t\t\t\t\t\t
            8187336\t588409\tcv\tТаллин\t\t\t\t\t\t
            8187337\t588409\tug\tتاللىن\t\t\t\t\t\t
            8187338\t588409\tmrj\tТаллинн\t\t\t\t\t\t
            8187339\t588409\tbo\tཏཱལ་་ལིན།\t\t\t\t\t\t
            8187340\t588409\tpa\tਤਾਲਿਨ\t\t\t\t\t\t
            8187341\t588409\tta\tதாலின்\t\t\t\t\t\t
            8187342\t588409\tbn\tতাল্লিন\t\t\t\t\t\t
            8187343\t588409\tkv\tТаллинн\t\t\t\t\t\t
            8187344\t588409\tht\tTalin\t\t\t\t\t\t
            8187345\t588409\tsah\tТаллинн\t\t\t\t\t\t
            8187346\t588409\tpnb\tٹالن\t\t\t\t\t\t
            8187347\t588409\tkk\tТаллинн\t\t\t\t\t\t
            8187348\t588409\two\tTalin\t\t\t\t\t\t
            8187349\t588409\tltg\tTalins\t\t\t\t\t\t
            8331419\t588409\tsv\tLindanäs\t\t\t\t1\t\t
            8697248\t588409\tba\tТаллин\t\t\t\t\t\t
            8697249\t588409\tsgs\tTalins\t\t\t\t\t\t
            8697250\t588409\tdiq\tTalin\t\t\t\t\t\t
            8697251\t588409\tvep\tTallidn\t\t\t\t\t\t
            8697252\t588409\tyue\t塔林\t\t\t\t\t\t
            11320393\t588409\tlrc\tتالین\t\t\t\t\t\t
            11320394\t588409\tmn\tТаллин\t\t\t\t\t\t
            11947298\t588409\tde\tReval\t\t\t\t1\t1219\t1918
            13750318\t588409\tunlc\tEETLL\t\t\t\t\t\t
            13901148\t588409\tru\tТаллинн\t\t\t\t\t\t
            15325983\t588409\twkdt\tQ1770\t\t\t\t\t\t
            16401504\t588409\ten\tRevel\t\t\t\t1\t1219\t1918
            17418615\t588409\tet\tTallinna linn\t\t\t\t\t\t
            20445808\t588409\thyw\tԹալլին\t\t\t\t\t\t
            """.data(using: .utf8)!

        let names = AlternateNames(data: data, logger: logger)
        XCTAssertEqual(names.alternativesPreferred.count, 1)
        XCTAssertEqual(names.alternativesPreferred[588409]!.count, 106)
        XCTAssertEqual(
            names.languages,
            [
                "", "eo", "el", "es", "fr", "de", "en", "pl", "af", "am", "ar", "be", "bg", "br",
                "ca", "co", "cs", "da", "et", "eu", "fi", "fy", "ga", "gl", "he", "hr", "hu", "hy",
                "ia", "id", "io", "it", "ja", "ka", "ko", "la", "lb", "lt", "lv", "ro", "nds", "nl",
                "nn", "no", "pt", "rmy", "ru", "sk", "sq", "sr", "sv", "tg", "th", "tr", "tt",
                "udm", "uk", "yi", "zh", "bs", "pms", "qu", "iata", "koi", "mzn", "gn", "mdf", "ml",
                "fa", "arz", "hbs", "sl", "mk", "mr", "os", "hi", "ce", "ur", "ky", "ckb", "tpi",
                "mhr", "myv", "cv", "ug", "mrj", "bo", "pa", "ta", "bn", "kv", "ht", "sah", "pnb",
                "kk", "wo", "ltg", "ba", "sgs", "diq", "vep", "yue", "lrc", "mn", "unlc", "hyw",
            ]
        )
        XCTAssertEqual(
            names.alternativesPreferred[588409]![
                Int32(names.languages.firstIndex(of: "en")!)
            ]!,
            "Tallinn"
        )
    }

    func testExample() throws {
        let logger = Logger(label: "test")
        let names = AlternateNames(data: "".data(using: .utf8)!, logger: logger)
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
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(1_000_000), 1.0)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(2_000_000), 1.0)
        XCTAssertEqual(GeocodingDatabase.Geonames.populationToRank(10_000_000), 1.0)
    }
}
