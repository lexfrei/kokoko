import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func rowDragChecks() {
        let token = RowDragToken(id: 12)
        let other = RowDragToken(id: 13)
        check(token.matches(token.payload), "row drag: matches its versioned payload")
        for text in ["12", "hello", other.payload, token.payload + "\n", token.payload.replacingOccurrences(of: ":12", with: ":65536"),
                     token.payload.replacingOccurrences(of: ":12", with: ":13"), token.payload.replacingOccurrences(of: ":1:", with: ":2:")] {
            check(!token.matches(text), "row drag: rejects foreign or malformed payload")
        }
        var context = RowDragContext()
        context.begin(token)
        eq(context.active, token, "row drag: begin installs the current token")
        eq(context.claim(target: 13, busy: false), token, "row drag: claims a different target")
        eq(context.active, nil, "row drag: claim clears the context before asynchronous loading")
        eq(context.claim(target: 13, busy: false), nil, "row drag: replay cannot claim again")
        for reason in ["cancel", "Finder export", "session end"] {
            context.begin(token)
            context.end(token)
            eq(context.claim(target: 13, busy: false), nil, "row drag: \(reason) invalidates the token")
        }
        context.begin(token)
        context.begin(other)
        context.end(token)
        eq(context.active, other, "row drag: an old session ending does not clear a newer one")
        eq(context.claim(target: 14, busy: false), other, "row drag: new session replaces old token")
        context.begin(token)
        eq(context.claim(target: 12, busy: false), nil, "row drag: self drop is refused")
        eq(context.active, nil, "row drag: self drop consumes the session")
        context.begin(token)
        eq(context.claim(target: 13, busy: true), nil, "row drag: busy drop is refused")
        eq(context.active, nil, "row drag: busy drop consumes the session")
    }
}
