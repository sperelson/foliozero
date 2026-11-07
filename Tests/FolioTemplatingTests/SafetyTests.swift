import Foundation
import Testing
@testable import FolioTemplating

@Suite("Safety limits")
struct SafetyTests {
    @Test func defaults() {
        let environment = TemplateEnvironment.standard
        #expect(environment.maxOutputLength == 64_000)
        #expect(environment.maxLoopIterations == 10_000)
        #expect(environment.strictUndefined == false)
    }

    @Test func rangeIsCappedByTheIterationLimit() throws {
        #expect(runtimeError("{% for i in range(20000) %}{% endfor %}")?.contains("range") == true)
        #expect(try render("{{ range(10000) | length }}") == "10000")
    }

    @Test func loopIterationsAreCountedAcrossTheWholeRender() throws {
        var environment = TemplateEnvironment.standard
        environment.maxLoopIterations = 10
        #expect(try render("{% for i in range(10) %}{% endfor %}", environment: environment) == "")
        let nested = "{% for i in range(3) %}{% for j in range(3) %}{% endfor %}{% endfor %}"
        let message = try #require(runtimeError(nested, environment: environment))
        #expect(message.contains("10 loop iterations"))
        let sequential = "{% for i in range(6) %}{% endfor %}{% for i in range(6) %}{% endfor %}"
        #expect(runtimeError(sequential, environment: environment) != nil)
    }

    @Test func outputLengthIsCapped() throws {
        var environment = TemplateEnvironment.standard
        environment.maxOutputLength = 10
        #expect(try render("0123456789", environment: environment) == "0123456789")
        #expect(runtimeError("{% for i in range(100) %}ab{% endfor %}", environment: environment)?
            .contains("exceeds the maximum length of 10") == true)
        #expect(runtimeError("01234567890", environment: environment) != nil)
    }

    @Test func intermediateStringsAreCapped() throws {
        #expect(runtimeError("{{ 'x' * 100000000 }}") != nil)
        #expect(runtimeError("{{ 'x' | center(100000000) }}") != nil)
        #expect(runtimeError("{{ '%999999999s' | format('x') }}") != nil)
        #expect(runtimeError("{{ 'x' | indent(100000000) }}") != nil)
        let doubling = "{% set ns = namespace(s='x') %}{% for i in range(100) %}"
            + "{% set ns.s = ns.s ~ ns.s %}{% endfor %}{{ ns.s | length }}"
        #expect(runtimeError(doubling) != nil)
        // A captured block is capped even if it is never printed.
        #expect(runtimeError("{% set big %}{% for i in range(9000) %}0123456789{% endfor %}{% endset %}") != nil)
    }

    @Test func listsAreCapped() throws {
        #expect(runtimeError("{{ [0] * 100000000 }}") != nil)
        let doubling = "{% set ns = namespace(l=[0]) %}{% for i in range(100) %}"
            + "{% set ns.l = ns.l + ns.l %}{% endfor %}{{ ns.l | length }}"
        #expect(runtimeError(doubling) != nil)
    }

    @Test func deeplyNestedValuesAreRefused() throws {
        let wrapping = "{% set ns = namespace(l=[]) %}{% for i in range(10000) %}{% set ns.l = [ns.l] %}{% endfor %}{{ ns.l }}"
        #expect(runtimeError(wrapping)?.contains("nested too deeply") == true)
        let selfWrapping = "{% set ns = namespace() %}{% for i in range(10000) %}{% set ns.inner = ns %}{% endfor %}"
        #expect(runtimeError(selfWrapping)?.contains("nested too deeply") == true)
        let dicts = "{% set ns = namespace(d={}) %}{% for i in range(10000) %}{% set ns.d = {'k': ns.d} %}{% endfor %}"
        #expect(runtimeError(dicts)?.contains("nested too deeply") == true)
    }

    @Test func intermediateDataIsBudgeted() throws {
        // 10,000 distinct 60 KB strings would need 600 MB; the render stops early instead.
        let big = TemplateValue.string(String(repeating: "x", count: 60_000))
        let source = "{% set ns = namespace(l=[]) %}{% for i in range(10000) %}"
            + "{% set ns.l = ns.l + [big ~ i] %}{% endfor %}{{ ns.l | length }}"
        #expect(runtimeError(source, ["big": big])?.contains("intermediate data") == true)
        let upper = "{% for i in range(10000) %}{% set x = big | upper %}{% endfor %}"
        #expect(runtimeError(upper, ["big": big])?.contains("intermediate data") == true)
        // Ordinary use of a large value is fine.
        #expect(try render("{{ big | upper | truncate(5) }}", ["big": big]) == "XX...")
    }

    @Test func formatWidthFromArgumentsIsCapped() {
        #expect(runtimeError("{{ '%*s' | format(100000000, 'x') }}") != nil)
        #expect(runtimeError("{{ '%.*f' | format(100000000, 1.5) }}") != nil)
    }

    @Test func integerOverflowIsAnError() throws {
        #expect(runtimeError("{{ 2 ** 100 }}")?.contains("overflow") == true)
        #expect(runtimeError("{{ 9223372036854775807 + 1 }}")?.contains("overflow") == true)
        #expect(try render("{{ 2 ** 62 }}") == "4611686018427387904")
    }

    @Test func deepNestingIsASyntaxErrorNotACrash() throws {
        let parens = String(repeating: "(", count: 5000) + "1" + String(repeating: ")", count: 5000)
        #expect(syntaxError("{{ \(parens) }}")?.message.contains("nested too deeply") == true)
        let chain = "{{ " + Array(repeating: "1", count: 5000).joined(separator: " + ") + " }}"
        #expect(syntaxError(chain)?.message.contains("nested too deeply") == true)
        let blocks = String(repeating: "{% if true %}", count: 5000) + String(repeating: "{% endif %}", count: 5000)
        #expect(syntaxError(blocks)?.message.contains("nested too deeply") == true)
        let minus = "{{ " + String(repeating: "-", count: 5000) + "1 }}"
        #expect(syntaxError(minus)?.message.contains("nested too deeply") == true)
    }

    @Test func nestingUpToTheLimitWorks() throws {
        let parens = String(repeating: "(", count: 22) + "1" + String(repeating: ")", count: 22)
        #expect(try render("{{ \(parens) }}") == "1")
        let lists = String(repeating: "[", count: 22) + "1" + String(repeating: "]", count: 22)
        #expect(try render("{{ \(lists) | length }}") == "1")
        let mixed = String(repeating: "1 + (", count: 22) + "1" + String(repeating: ")", count: 22)
        #expect(try render("{{ \(mixed) }}") == "23")
        let blocks = String(repeating: "{% if true %}", count: 24) + "x" + String(repeating: "{% endif %}", count: 24)
        #expect(try render(blocks) == "x")
        let loops = String(repeating: "{% for i in items %}", count: 24) + "x" + String(repeating: "{% endfor %}", count: 24)
        #expect(try render(loops, ["items": [1]]) == "x")
        // Left-deep chains are evaluated without recursion.
        let chain = "{{ " + Array(repeating: "1", count: 99).joined(separator: " + ") + " }}"
        #expect(try render(chain) == "99")
        let filters = "{{ 'x'" + String(repeating: " | upper", count: 99) + " }}"
        #expect(try render(filters) == "X")
        #expect(syntaxError(String(repeating: "{% if true %}", count: 25) + String(repeating: "{% endif %}", count: 25))?
            .message.contains("nested too deeply") == true)
    }

    @Test func nestingAtTheLimitFitsInASmallStack() throws {
        // Worst cases at the limit must run on a 256 KB stack: half of a Swift concurrency thread's.
        let sources = [
            "{{ " + String(repeating: "(", count: 23) + "1" + String(repeating: ")", count: 23) + " }}",
            "{{ " + String(repeating: "[", count: 23) + "1" + String(repeating: "]", count: 23) + " }}",
            "{{ " + String(repeating: "1 + (", count: 23) + "1" + String(repeating: ")", count: 23) + " }}",
            "{{ " + String(repeating: "not ", count: 23) + "1 }}",
            String(repeating: "{% if true %}", count: 24) + "x" + String(repeating: "{% endif %}", count: 24),
            String(repeating: "{% for i in 'a' %}", count: 12) + "{{ " + String(repeating: "(", count: 11) + "1"
                + String(repeating: ")", count: 11) + " }}" + String(repeating: "{% endfor %}", count: 12),
        ]
        for source in sources {
            let outcome = runOnThread(stackSize: 256 * 1024) { () -> String in
                do { return try render(source) } catch { return "error: \(error)" }
            }
            #expect(!outcome.hasPrefix("error"), "\(outcome)")
        }
    }

    @Test func templatesAreSendableAndReusable() async throws {
        let template = try Template("{{ n * 2 }}")
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for n in 0..<8 {
                group.addTask { try template.render(["n": .int(n)]) }
            }
            var collected: [String] = []
            for try await result in group { collected.append(result) }
            return collected.sorted()
        }
        #expect(results == ["0", "10", "12", "14", "2", "4", "6", "8"])
    }
}

/// Runs `body` on a new thread with the given stack size and waits for the result.
private func runOnThread(stackSize: Int, _ body: @escaping @Sendable () -> String) -> String {
    final class ResultBox: @unchecked Sendable {
        var value = ""
    }
    let box = ResultBox()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.stackSize = stackSize
    thread.start()
    done.wait()
    return box.value
}
