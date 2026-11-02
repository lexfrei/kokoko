import KokokoLibrary

extension KokokoCoreChecks {
    static func errorLineChecks() {
        func line(_ text: String?, _ events: (inout ErrorLine) -> Void) -> String? {
            var line = ErrorLine(text: text)
            events(&line)
            return line.text
        }
        eq(line(nil) { $0.report("device watch: x", deviceIsCurrent: true) }, "device watch: x",
           "error line: a message outside an operation is the line when it is empty")
        eq(line("upload: a") { $0.report("bin: x", deviceIsCurrent: true) }, "upload: a; bin: x",
           "error line: a message outside an operation keeps an unread error")
        eq(line("upload: a") { $0.start(); $0.report("rename: b", deviceIsCurrent: true) }, "rename: b",
           "error line: an operation's first error replaces the line")
        eq(line("upload: a") { $0.start(); $0.report("rename: b", deviceIsCurrent: true)
            $0.report("list failed: c", deviceIsCurrent: true) }, "rename: b; list failed: c",
           "error line: an operation's later errors join its first")
        eq(line("upload: a") { $0.start(); $0.finish() }, "upload: a",
           "error line: a successful operation leaves the line as it was")
        eq(line("upload: a") { $0.start(); $0.finish(); $0.report("bin: x", deviceIsCurrent: true) },
           "upload: a; bin: x", "error line: after an operation ends, a message joins the line again")
        eq(line("upload: a") { $0.start(); $0.report("delete: b", deviceIsCurrent: false) }, "upload: a",
           "error line: an error about a device that left changes nothing")
        eq(line("upload: a") { $0.start(); $0.report("delete: b", deviceIsCurrent: false)
            $0.report("delete: c", deviceIsCurrent: true) }, "delete: c",
           "error line: a dropped error does not count as the operation's first")
        eq(line("upload: a") { $0.clear() }, nil, "error line: a clear empties the line")
        eq(line("upload: a") { $0.start(); $0.report("projects: b", deviceIsCurrent: true); $0.clear()
            $0.report("projects: b", deviceIsCurrent: true) }, "projects: b",
           "error line: an error put back after a clear in the same operation is the line")
        eq(line("x; bin: y") { $0.report("bin: y", deviceIsCurrent: true) }, "x; bin: y",
           "error line: a message already ending the line is not repeated")
        eq(line("upload: a") { $0.start(); $0.note("device busy"); $0.finish() }, "upload: a; device busy",
           "error line: a note during an operation keeps an unread error")
        eq(line("upload: a") { $0.start(); $0.note("device busy"); $0.report("rename: b", deviceIsCurrent: true) },
           "rename: b", "error line: a note does not take the operation's first error")
        eq(line("upload: a") { $0.note("bin: x") }, "upload: a; bin: x", "error line: a note joins the line")
        eq(line("x; bin: y") { $0.note("bin: y") }, "x; bin: y", "error line: a note already ending the line is not repeated")
        eq(line("upload: a") { $0.finish(); $0.report("bin: x", deviceIsCurrent: true) }, "upload: a; bin: x",
           "error line: an end with no start changes nothing")
        eq(line("upload: a") { $0.start(); $0.report("X disconnected", deviceIsCurrent: true)
            $0.report("restore: n", deviceIsCurrent: true) }, "X disconnected; restore: n",
           "error line: a disconnect reported during an operation stays when the operation reports next")
    }
}
