import Testing
@testable import FolioCore

@Suite struct BarcodeLogicTests {
    func code(_ page: Int, _ value: String) -> FoundBarcode { FoundBarcode(page: page, value: value, format: "qrcode") }

    @Test func separatorPagesAreDroppedByDefault() {
        let logic = BarcodeLogic()
        let pages = logic.separationPages([code(2, "PATCHT")])
        #expect(pages == [2: false])
        #expect(BarcodeLogic.splitPlan(pageCount: 5, separationPages: pages) == [[0, 1], [3, 4]])
    }

    @Test func retainedSeparatorStartsNextDocument() {
        let logic = BarcodeLogic(retainSplitPages: true)
        let pages = logic.separationPages([code(0, "PATCHT"), code(3, "PATCHT")])
        #expect(pages == [3: true]) // first page never splits when retaining
        #expect(BarcodeLogic.splitPlan(pageCount: 5, separationPages: pages) == [[0, 1, 2], [3, 4]])
    }

    @Test func leadingSeparatorPageDisappears() {
        let pages = BarcodeLogic().separationPages([code(0, "PATCHT")])
        #expect(BarcodeLogic.splitPlan(pageCount: 3, separationPages: pages) == [[1, 2]])
    }

    @Test func asnBarcodes() {
        let logic = BarcodeLogic(enableSplitting: false, enableASN: true)
        #expect(logic.asn([code(0, "ASN 00123")]) == 123)
        #expect(logic.asn([code(0, "nothing")]) == nil)
        // ASN on a later page splits there and keeps the page.
        #expect(logic.separationPages([code(0, "ASN1"), code(2, "ASN2")]) == [2: true])
    }

    @Test func tagBarcodesWithMapping() {
        let logic = BarcodeLogic(enableTags: true)
        #expect(logic.tagNames([code(0, "TAG:invoice"), code(1, "tag:Receipt,TAG:invoice"), code(2, "PATCHT")]) == ["invoice", "Receipt"])
        let custom = BarcodeLogic(enableTags: true, tagMapping: ["ASN12.*": "JOHN", "^CUST-(\\d+)$": "customer-\\g<1>"])
        #expect(custom.tagNames([code(0, "ASN1234"), code(0, "CUST-42")]) == ["JOHN", "customer-42"])
        let splitting = BarcodeLogic(enableSplitting: false, enableTags: true, tagSplit: true)
        let pages = splitting.separationPages([code(2, "TAG:invoice"), code(4, "TAG:receipt")])
        #expect(BarcodeLogic.splitPlan(pageCount: 6, separationPages: pages) == [[0, 1], [2, 3], [4, 5]])
    }
}
