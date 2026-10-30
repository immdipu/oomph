import Testing
@testable import Oomph

struct AutoEqTests {
    private let hd600 = AutoEq.Headphone(name: "Sennheiser HD 600", source: "oratory1990",
                                         path: "oratory1990/over-ear/Sennheiser%20HD%20600")

    /// The shape of AutoEq's results/INDEX.md: names and folders can hold parentheses.
    @Test func readsTheResultsIndex() {
        let index = """
            # Index
            This is a list of all equalization profiles. Target is in parentheses if there are results with multiple targets
            from the same source.

            - [1MORE Aero (ANC Off)](./HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)) by HypetheSonics on GRAS RA0045
            - [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600) by oratory1990
            """
        #expect(AutoEq.parseIndex(index) == [
            AutoEq.Headphone(name: "1MORE Aero (ANC Off)", source: "HypetheSonics on GRAS RA0045",
                             path: "HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)"),
            hd600,
        ])
    }

    @Test func pointsAtEachResultsParametricEQ() {
        #expect(hd600.parametricEQ.absoluteString
                == "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD%20600/Sennheiser%20HD%20600%20ParametricEQ.txt")
        let aure = AutoEq.Headphone(name: "AüR Audio Aure", source: "Kazi", path: "Kazi/in-ear/A%C3%BCR%20Audio%20Aure")
        #expect(aure.parametricEQ.absoluteString.hasSuffix("/Kazi/in-ear/A%C3%BCR%20Audio%20Aure/A%C3%BCR%20Audio%20Aure%20ParametricEQ.txt"))
        #expect(aure.isInEar && !hd600.isInEar)
    }

    /// People type models the way they say them: any word order, no spaces, no accents.
    @Test func searchMatchesEveryWordAnyWay() {
        let names = ["Apple AirPods", "Apple AirPods Pro", "Apple AirPods Pro 2", "AüR Audio Aure", "Denon AH-D600", "Sennheiser HD 600"]
        let all = names.map { AutoEq.Headphone(name: $0, source: "x", path: "x/in-ear/\($0)") }
        func found(_ query: String) -> [String] { AutoEq.search(query, in: all).map(\.name) }
        #expect(found("pro airpods") == ["Apple AirPods Pro", "Apple AirPods Pro 2"])
        // Models whose words start like the query's come first.
        #expect(found("hd600") == ["Sennheiser HD 600", "Denon AH-D600"])
        #expect(found("aur aure") == ["AüR Audio Aure"])
        #expect(found("  ") == names)
    }
}
