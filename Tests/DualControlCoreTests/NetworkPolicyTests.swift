import Testing

@testable import DualControlCore

@Test(
    arguments: [
        ("PyPI.org", "pypi.org"),
        ("pypi.org.", "pypi.org"),
        ("a-b.example.com", "a-b.example.com"),
        ("xn--caf-dma.example", "xn--caf-dma.example"),
    ]
)
func hostNamesAreNormalized(_ raw: String, _ expected: String) {
    #expect(NetworkHost.normalized(raw) == expected)
}

@Test(
    arguments: [
        "", ".", "localhost", "pypi", "1.2.3.4", "127.0.0.1", "0x7f.1", "2130706433.com.1", "[::1]", "::1",
        "-a.example.com", "a-.example.com", "a..example.com", "a_b.example.com", "café.example", "a b.example.com",
        "user@pypi.org", "pypi.org:443", "*.example.com", "pypi.org\u{0}", String(repeating: "a", count: 64) + ".com",
        String(repeating: "abcdefghi.", count: 26) + "com",
    ]
)
func badHostNamesAreRefused(_ raw: String) {
    #expect(NetworkHost.normalized(raw) == nil)
}

@Test func theDefaultListIsTheVerifiedMinimum() {
    #expect(
        NetworkPolicy.defaultHosts == [
            "pypi.org", "files.pythonhosted.org", "github.com", "codeload.github.com",
            "release-assets.githubusercontent.com", "dl.espressif.com", "components.espressif.com",
            "components-file.espressif.com",
        ]
    )
    #expect(NetworkPolicy.defaultHosts.allSatisfy { NetworkHost.normalized($0) == $0 })
}

@Test func defaultHostsAreAllowedOnlyOnTheirPort() {
    let policy = NetworkPolicy()
    #expect(policy.decide(.connect, host: "pypi.org", port: 443).isAllowed)
    #expect(policy.decide(.connect, host: "PyPI.org.", port: 443).ruleID == "network.allowlist")
    #expect(policy.decide(.forward(path: "/simple/"), host: "pypi.org", port: 80).isAllowed)
    #expect(policy.decide(.connect, host: "pypi.org", port: 22).ruleID == "network.port")
    #expect(policy.decide(.connect, host: "pypi.org", port: 80).ruleID == "network.port")
    #expect(policy.decide(.forward(path: "/"), host: "pypi.org", port: 443).ruleID == "network.port")
}

@Test func otherHostsAreDeniedWithSomethingTheOwnerCanAllow() {
    let policy = NetworkPolicy()
    let denied = policy.decide(.connect, host: "Example.com", port: 443)
    #expect(!denied.isAllowed)
    #expect(denied.ruleID == "network.not-allowed")
    #expect(denied.allowableHost == "example.com")
    // Subdomains of allowed hosts are other hosts.
    #expect(policy.decide(.connect, host: "evil.github.com", port: 443).ruleID == "network.not-allowed")
    #expect(policy.decide(.connect, host: "github.com.evil.com", port: 443).ruleID == "network.not-allowed")
    // Addresses and junk can never be allowed with a click.
    let literal = policy.decide(.connect, host: "140.82.112.3", port: 443)
    #expect(literal.ruleID == "network.bad-host")
    #expect(literal.allowableHost == nil)
}

@Test func ownerHostsAreAllowedForTheSessionOrAlways() {
    var policy = NetworkPolicy(ownerHosts: ["mirror.example.org"])
    #expect(policy.decide(.connect, host: "mirror.example.org", port: 443).ruleID == "network.owner-host")
    let session = policy.add("Example.COM", always: false)
    #expect(session == "example.com")
    #expect(policy.decide(.connect, host: "example.com", port: 443).ruleID == "network.session-host")
    let literal = policy.add("1.2.3.4", always: true)
    let builtIn = policy.add("pypi.org", always: true)
    #expect(literal == nil && builtIn == nil)
    let always = policy.add("example.com", always: true)
    #expect(always == "example.com")
    #expect(policy.decide(.connect, host: "example.com", port: 443).ruleID == "network.owner-host")
    #expect(policy.sessionHosts.isEmpty)
    let removed = policy.remove("example.com")
    let again = policy.remove("example.com")
    #expect(removed && !again)
    #expect(policy.decide(.connect, host: "example.com", port: 443).ruleID == "network.not-allowed")
}

@Test(
    arguments: [
        "/espressif/esp-idf.git/git-receive-pack",
        "/espressif/esp-idf.git/info/refs?service=git-receive-pack",
        "/espressif/esp-idf.git/info/refs?x=1&service=git-receive-pack",
        "/espressif/esp-idf.git/git%2Dreceive-pack",
        "/espressif/esp-idf.git/GIT-RECEIVE-PACK",
        "/espressif/esp-idf.git/info/refs?service=git%2dreceive%2Dpack",
        "/a/git-receive-pack/",
        "/a/git-receive-pack;x",
        "/a/git-receive-pack%00",
        "/a/info/refs?service=git-receive-pack%00",
    ]
)
func gitPushIsRefusedOnPlainHTTP(_ path: String) {
    let decision = NetworkPolicy().decide(.forward(path: path), host: "github.com", port: 80)
    #expect(decision.ruleID == "network.git-push")
    #expect(decision.allowableHost == nil)
}

@Test(
    arguments: [
        "/espressif/esp-idf.git/info/refs?service=git-upload-pack",
        "/espressif/esp-idf.git/git-upload-pack",
        "/espressif/esp-idf",
        "/receive-pack-notes",
    ]
)
func gitFetchIsAllowedOnPlainHTTP(_ path: String) {
    #expect(NetworkPolicy().decide(.forward(path: path), host: "github.com", port: 80).isAllowed)
}

@Test(
    arguments: [
        [0, 0, 0, 0], [0, 1, 2, 3], [127, 0, 0, 1], [127, 255, 1, 1], [10, 0, 0, 1], [172, 16, 0, 1],
        [172, 31, 255, 255], [192, 168, 1, 1], [169, 254, 169, 254], [100, 64, 0, 1], [224, 0, 0, 251],
        [255, 255, 255, 255], [240, 0, 0, 1],
    ] as [[UInt8]]
)
func localAndPrivateIPv4AddressesAreRefused(_ address: [UInt8]) {
    #expect(NetworkAddress.isForbidden(address))
}

@Test(arguments: [[140, 82, 112, 3], [151, 101, 0, 223], [172, 32, 0, 1], [100, 128, 0, 1]] as [[UInt8]])
func publicIPv4AddressesAreAllowed(_ address: [UInt8]) {
    #expect(!NetworkAddress.isForbidden(address))
}

@Test func ipv6AddressesAreCheckedToo() {
    func v6(_ head: [UInt8], tail: [UInt8] = []) -> [UInt8] {
        head + [UInt8](repeating: 0, count: 16 - head.count - tail.count) + tail
    }
    #expect(NetworkAddress.isForbidden(v6([])))
    #expect(NetworkAddress.isForbidden(v6([], tail: [1])))
    #expect(NetworkAddress.isForbidden(v6([0xFE, 0x80])))
    #expect(NetworkAddress.isForbidden(v6([0xFD, 0x12])))
    #expect(NetworkAddress.isForbidden(v6([0xFF, 0x02])))
    // IPv4-mapped and NAT64-style embeddings of a forbidden IPv4 address.
    #expect(NetworkAddress.isForbidden(v6([], tail: [0xFF, 0xFF, 127, 0, 0, 1])))
    #expect(NetworkAddress.isForbidden(v6([0x00, 0x64, 0xFF, 0x9B], tail: [10, 0, 0, 1])))
    #expect(!NetworkAddress.isForbidden(v6([], tail: [0xFF, 0xFF, 140, 82, 112, 3])))
    #expect(!NetworkAddress.isForbidden(v6([0x26, 0x06, 0x50, 0xC0], tail: [1])))
    // Neither 4 nor 16 bytes: refused.
    #expect(NetworkAddress.isForbidden([1, 2, 3]))
}

@Test func theEndpointPutsTheTokenOnlyInTheProxyURL() throws {
    let endpoint = try #require(ProxyEndpoint(port: 50123, token: String(repeating: "ab", count: 32)))
    let url = "http://dc:" + String(repeating: "ab", count: 32) + "@127.0.0.1:50123"
    #expect(endpoint.url == url)
    let variables = endpoint.variables
    for name in ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"] {
        #expect(variables[name] == url)
    }
    #expect(variables["NO_PROXY"] == "localhost,127.0.0.1,::1")
    #expect(variables["no_proxy"] == "localhost,127.0.0.1,::1")
    // Git must not store the proxy token with a credential helper.
    #expect(variables["GIT_CONFIG_COUNT"] == "1")
    #expect(variables["GIT_CONFIG_KEY_0"] == "credential.http://127.0.0.1:50123.helper")
    #expect(variables["GIT_CONFIG_VALUE_0"] == "")
    #expect(variables.count == 11)
    #expect(endpoint.authorization == "Basic " + "dc:\(String(repeating: "ab", count: 32))".base64)
    #expect(!endpoint.description.contains("abab"))
    // Tokens must be long random hex; port 0 is not a port.
    #expect(ProxyEndpoint(port: 50123, token: "short") == nil)
    #expect(ProxyEndpoint(port: 0, token: String(repeating: "ab", count: 32)) == nil)
    #expect(ProxyEndpoint(port: 1, token: String(repeating: "zz", count: 32)) == nil)
}

@Test func freshTokensDiffer() {
    let a = ProxyEndpoint.newToken()
    let b = ProxyEndpoint.newToken()
    #expect(a != b)
    #expect(a.count == 64)
    #expect(ProxyEndpoint(port: 1, token: a) != nil)
}

extension String {
    fileprivate var base64: String {
        let table = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        let bytes = Array(utf8)
        var out = ""
        var index = 0
        while index < bytes.count {
            let chunk = Array(bytes[index..<min(index + 3, bytes.count)])
            let value = chunk.enumerated().reduce(0) { $0 | Int($1.element) << (16 - 8 * $1.offset) }
            for position in 0..<4 {
                out.append(position <= chunk.count ? table[(value >> (18 - 6 * position)) & 63] : "=")
            }
            index += 3
        }
        return out
    }
}
