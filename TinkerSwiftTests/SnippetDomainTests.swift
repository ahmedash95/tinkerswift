import Foundation
import XCTest
@testable import TinkerSwift

@MainActor
final class SnippetDomainTests: XCTestCase {
    func testAddSnippetRejectsEmptyTitleOrContent() {
        let service = SnippetCatalogService()
        let base: [WorkspaceSnippetItem] = []

        let emptyTitle = service.add(
            title: "   ",
            content: "return 1;",
            sourceProjectID: "local:/tmp/project",
            to: base
        )
        XCTAssertEqual(emptyTitle, [])

        let emptyContent = service.add(
            title: "Snippet",
            content: "   \n",
            sourceProjectID: "local:/tmp/project",
            to: base
        )
        XCTAssertEqual(emptyContent, [])
    }

    func testUpdateSnippetKeepsSourceProjectImmutable() {
        let service = SnippetCatalogService()
        let original = WorkspaceSnippetItem(
            id: "snippet-1",
            title: "Old",
            content: "return 1;",
            sourceProjectID: "local:/tmp/project-a",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let updated = service.update(
            id: original.id,
            title: "New",
            content: "return 2;",
            in: [original],
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].sourceProjectID, "local:/tmp/project-a")
        XCTAssertEqual(updated[0].title, "New")
        XCTAssertEqual(updated[0].content, "return 2;")
    }

    func testSnippetsAreOrderedNewestFirst() {
        let service = SnippetCatalogService()
        let older = WorkspaceSnippetItem(
            id: "old",
            title: "Older",
            content: "return 'old';",
            sourceProjectID: "local:/tmp/project",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = WorkspaceSnippetItem(
            id: "new",
            title: "Newer",
            content: "return 'new';",
            sourceProjectID: "local:/tmp/project",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let sorted = service.sorted([older, newer])
        XCTAssertEqual(sorted.map(\.id), ["new", "old"])
    }
}
