import KokokoLibrary

extension KokokoCoreChecks {
    static func errorLineChecks() {
        func line(_ messages: [String], _ events: (inout ErrorLine) -> Void) -> String? {
            var line = ErrorLine(messages)
            events(&line)
            return line.text
        }
        eq(line([]) { $0.report("device watch: x", deviceIsCurrent: true) }, "device watch: x",
           "error line: a message outside an operation is the line when it is empty")
        eq(line(["upload: a"]) { $0.report("bin: x", deviceIsCurrent: true) }, "upload: a; bin: x",
           "error line: a message outside an operation keeps an unread error")
        eq(line(["upload: a"]) { $0.start(); $0.report("rename: b", deviceIsCurrent: true) }, "rename: b",
           "error line: an operation's first error replaces the line")
        eq(line(["upload: a"]) { $0.start(); $0.report("rename: b", deviceIsCurrent: true)
            $0.report("list failed: c", deviceIsCurrent: true) }, "rename: b; list failed: c",
           "error line: an operation's later errors join its first")
        eq(line(["upload: a"]) { $0.start(); $0.finish() }, "upload: a",
           "error line: a successful operation leaves the line as it was")
        eq(line(["upload: a"]) { $0.start(); $0.finish(); $0.report("bin: x", deviceIsCurrent: true) },
           "upload: a; bin: x", "error line: after an operation ends, a message joins the line again")
        eq(line(["upload: a"]) { $0.start(); $0.report("delete: b", deviceIsCurrent: false) }, "upload: a",
           "error line: an error about a device that left changes nothing")
        eq(line(["upload: a"]) { $0.start(); $0.report("delete: b", deviceIsCurrent: false)
            $0.report("delete: c", deviceIsCurrent: true) }, "delete: c",
           "error line: a dropped error does not count as the operation's first")
        eq(line(["upload: a"]) { $0.clear() }, nil, "error line: a clear empties the line")
        eq(line(["upload: a"]) { $0.start(); $0.report("projects: b", deviceIsCurrent: true); $0.clear()
            $0.report("projects: b", deviceIsCurrent: true) }, "projects: b",
           "error line: an error put back after a clear in the same operation is the line")
        eq(line(["x", "bin: y"]) { $0.report("bin: y", deviceIsCurrent: true) }, "x; bin: y",
           "error line: a message already ending the line is not repeated")
        eq(line(["upload: a"]) { $0.start(); $0.note("device busy"); $0.finish() }, "upload: a; device busy",
           "error line: a note during an operation keeps an unread error")
        eq(line(["upload: a"]) { $0.start(); $0.note("device busy"); $0.report("rename: b", deviceIsCurrent: true) },
           "rename: b", "error line: a note does not take the operation's first error")
        eq(line(["upload: a"]) { $0.note("bin: x") }, "upload: a; bin: x", "error line: a note joins the line")
        eq(line(["x", "bin: y"]) { $0.note("bin: y") }, "x; bin: y", "error line: a note already ending the line is not repeated")
        eq(line(["bin: y", "x"]) { $0.note("bin: y") }, "bin: y; x; bin: y",
           "error line: a message seen earlier joins again after a newer one")
        eq(line(["xbin: y"]) { $0.note("bin: y") }, "xbin: y; bin: y",
           "error line: only a whole message at the end counts as a repeat")
        eq(line(["upload: a"]) { $0.pin("device watch: x") }, "device watch: x; upload: a",
           "error line: a pinned message leads the line")
        eq(line(["upload: a"]) { $0.pin("device watch: x"); $0.clear() }, "device watch: x",
           "error line: a clear keeps a pinned message")
        eq(line(["upload: a"]) { $0.pin("device watch: x"); $0.start(); $0.report("rename: b", deviceIsCurrent: true) },
           "device watch: x; rename: b", "error line: an operation's first error keeps a pinned message")
        eq(line([]) { $0.pin("device watch: x"); $0.pin("device watch: x") }, "device watch: x",
           "error line: the same message pinned twice shows once")
        eq(line(["upload: a", "projects: x", "projects: y"]) { $0.withdraw(startingWith: "projects: ") }, "upload: a",
           "error line: a withdrawal removes every message of its kind and keeps the rest")
        eq(line(["upload: a"]) { $0.withdraw(startingWith: "projects: ") }, "upload: a",
           "error line: a withdrawal with nothing of its kind changes nothing")
        eq(line(["projects: x"]) { $0.pin("projects: pinned"); $0.withdraw(startingWith: "projects: ") }, "projects: pinned",
           "error line: a withdrawal keeps a pinned message")
        eq(line(["upload: a"]) { $0.pin("device watch: x"); $0.unpin(startingWith: "device watch: ") }, "upload: a",
           "error line: an unpin takes back a pinned message and keeps the rest")
        eq(line(["device watch: y"]) { $0.unpin(startingWith: "device watch: ") }, "device watch: y",
           "error line: an unpin leaves messages that are not pinned")
        eq(line([]) { $0.pin("device watch: x"); $0.note("device watch: x") }, "device watch: x",
           "error line: a pinned message is not repeated after it")
        eq(line(["upload: a"]) { $0.pin("device watch: x"); $0.note("device watch: x") }, "device watch: x; upload: a",
           "error line: a pinned message is not added again behind other messages")
        eq(line(["upload: a"]) { $0.pin("device watch: x"); $0.start(); $0.report("device watch: x", deviceIsCurrent: true) },
           "device watch: x", "error line: an operation reporting a pinned message first replaces the rest and shows it once")
        eq(line([]) { $0.pin("device watch: x"); $0.unpin(startingWith: "device watch: "); $0.pin("device watch: y") },
           "device watch: y", "error line: a pinned message replaced by a newer one of its kind shows once")
        eq(line(["upload: a"]) { $0.finish(); $0.report("bin: x", deviceIsCurrent: true) }, "upload: a; bin: x",
           "error line: an end with no start changes nothing")
        eq(line(["upload: a"]) { $0.start(); $0.report("X disconnected", deviceIsCurrent: true)
            $0.report("restore: n", deviceIsCurrent: true) }, "X disconnected; restore: n",
           "error line: a disconnect reported during an operation stays when the operation reports next")
    }
}
