import Foundation
import Testing
@testable import FolioTemplating

@Suite("Whitespace control")
struct WhitespaceTests {
    private var trimming: TemplateEnvironment {
        var environment = TemplateEnvironment.standard
        environment.trimBlocks = true
        environment.lstripBlocks = true
        return environment
    }

    @Test func minusModifiersStripAdjacentWhitespace() throws {
        #expect(try render("a  {{- 'x' -}}  c") == "axc")
        #expect(try render("a \n {{- 'x' }} c") == "ax c")
        #expect(try render("a {{ 'x' -}} \n c") == "a xc")
        #expect(try render("{% for x in [1, 2] -%}\n  {{ x }}\n{%- endfor %}") == "12")
        #expect(try render("a\n{#- comment -#}\nb") == "ab")
    }

    @Test func defaultsKeepWhitespaceButDropOneTrailingNewline() throws {
        #expect(try render("{% if true %}\nyes\n{% endif %}\n") == "\nyes\n")
        #expect(try render("a\n") == "a")
        #expect(try render("a\n\n") == "a\n")
    }

    @Test func keepTrailingNewline() throws {
        var environment = TemplateEnvironment.standard
        environment.keepTrailingNewline = true
        #expect(try render("a\n", environment: environment) == "a\n")
    }

    @Test func trimBlocksRemovesNewlineAfterBlockTags() throws {
        var environment = TemplateEnvironment.standard
        environment.trimBlocks = true
        #expect(try render("{% if true %}\nyes\n{% endif %}\nafter", environment: environment) == "yes\nafter")
        // Variable tags are not affected.
        #expect(try render("{{ 'a' }}\nb", environment: environment) == "a\nb")
        // Comments are.
        #expect(try render("{# c #}\nb", environment: environment) == "b")
        // Only one newline is removed.
        #expect(try render("{% if true %}\n\nx{% endif %}", environment: environment) == "\nx")
    }

    @Test func lstripBlocksRemovesIndentBeforeBlockTags() throws {
        let source = "<div>\n    {% if true %}\n    yes\n    {% endif %}\n</div>"
        #expect(try render(source, environment: trimming) == "<div>\n    yes\n</div>")
        // Text before the tag on the same line blocks the strip.
        #expect(try render("x  {% if true %}y{% endif %}", environment: trimming) == "x  y")
        // Indentation at the very start of the template is stripped.
        #expect(try render("   {% if true %}y{% endif %}", environment: trimming) == "y")
        // Variable tags are not affected.
        #expect(try render("a\n   {{ 'b' }}", environment: trimming) == "a\n   b")
    }

    @Test func plusModifiersDisableTrimming() throws {
        #expect(try render("{% if true +%}\nyes{% endif %}", environment: trimming) == "\nyes")
        #expect(try render("  {%+ if true %}x{% endif %}", environment: trimming) == "  x")
    }

    @Test func lstripAfterTrimmedLine() throws {
        // The newline after the first tag is trimmed, so the indent before `if` starts a line.
        let source = "{% for x in 'ab' %}\n  {% if true %}{{ x }}{% endif %}\n{% endfor %}"
        #expect(try render(source, environment: trimming) == "ab")
        let withVariable = "{% for x in 'ab' %}\n  {{ x }}\n{% endfor %}"
        #expect(try render(withVariable, environment: trimming) == "  a\n  b\n")
    }

    @Test func carriageReturnsAreNormalised() throws {
        #expect(try render("a\r\nb\rc") == "a\nb\nc")
    }

    @Test func rawBlockWhitespace() throws {
        let source = "  {% raw %}\n{{ x }}\n  {% endraw %}\nend"
        #expect(try render(source, environment: trimming) == "\n{{ x }}\nend")
    }
}
