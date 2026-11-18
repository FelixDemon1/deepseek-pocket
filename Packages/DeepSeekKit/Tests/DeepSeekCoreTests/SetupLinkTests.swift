import Foundation
import Testing
@testable import DeepSeekCore

@Suite("One-Tap Setup Link (deepseekgo://setup)")
struct SetupLinkTests {

    @Test("Parses base / key / model / name from an operator invite link")
    func parsesFullLink() throws {
        let raw = "deepseekgo://setup?base=https%3A%2F%2Fgw.example.com%2Fv1&key=dsg_abc123&model=deepseek-reasoner&name=%E5%85%AC%E7%9B%8A%E7%BD%91%E5%85%B3"
        let url = try #require(URL(string: raw))
        let link = try #require(SetupLink.parse(url))

        #expect(link.baseURL.absoluteString == "https://gw.example.com/v1")
        #expect(link.apiKey == "dsg_abc123")
        #expect(link.model == "deepseek-reasoner")
        #expect(link.name == "公益网关")
    }

    @Test("Anonymous / keyless link is valid — free public gateways need no token")
    func parsesKeylessLink() throws {
        let url = try #require(URL(string: "deepseekgo://setup?base=http://192.168.1.9:8787/v1"))
        let link = try #require(SetupLink.parse(url))
        #expect(link.apiKey.isEmpty)
        #expect(link.model == "deepseek-chat")
    }

    @Test("Aliases and bare hostnames are accepted")
    func normalizesBareHost() throws {
        let url = try #require(URL(string: "dshgo://config?endpoint=gw.example.com/v1&token=dsg_x"))
        let link = try #require(SetupLink.parse(url))
        #expect(link.baseURL.absoluteString == "https://gw.example.com/v1")
        #expect(link.apiKey == "dsg_x")
    }

    @Test("Rejects non-setup hosts, non-HTTP schemes and empty base")
    func rejectsBadLinks() throws {
        let notSetup = try #require(URL(string: "deepseekgo://ask?q=hi"))
        #expect(SetupLink.parse(notSetup) == nil)

        let wrongScheme = try #require(URL(string: "https://setup?base=gw.example.com"))
        #expect(SetupLink.parse(wrongScheme) == nil)

        let fileScheme = try #require(URL(string: "deepseekgo://setup?base=file%3A%2F%2F%2Fetc%2Fpasswd"))
        #expect(SetupLink.parse(fileScheme) == nil)

        let missingBase = try #require(URL(string: "deepseekgo://setup?key=dsg_x"))
        #expect(SetupLink.parse(missingBase) == nil)
    }

    @Test("appURL round-trips through the parser")
    func roundTrips() throws {
        let original = SetupLink(
            baseURL: try #require(URL(string: "https://gw.example.com/v1")),
            apiKey: "dsg_roundtrip",
            model: "deepseek-chat",
            name: "自建网关"
        )
        let url = try #require(original.appURL)
        let parsed = try #require(SetupLink.parse(url))
        #expect(parsed == original)
    }
}
