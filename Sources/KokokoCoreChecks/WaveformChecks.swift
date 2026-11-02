import KokokoLibrary

extension KokokoCoreChecks {
    static func waveformChecks() {
        func s16(_ samples: [Int16]) -> [UInt8] {
            samples.flatMap { [UInt8(UInt16(bitPattern: $0) & 0xFF), UInt8(UInt16(bitPattern: $0) >> 8)] }
        }
        let mono = Waveform(pcm: s16([0, 0, 16384, -32768, 0, 0, 0, 0]), channels: 1, sampleRate: 4,
                            columns: 4, loopStart: nil, loopEnd: nil)
        eq(mono.frameCount, 8, "waveform: frames counted from 16-bit mono")
        eq(mono.peaks, [0, 1, 0, 0], "waveform: each column holds its loudest sample, negative full scale included")
        let half = Waveform(pcm: s16([16384, 0]), channels: 1, sampleRate: 1, columns: 1, loopStart: nil, loopEnd: nil)
        eq(half.peaks, [0.5], "waveform: half scale is 0.5")

        let stereo = Waveform(pcm: s16([0, 8192, 0, 0]), channels: 2, sampleRate: 2, columns: 2,
                              loopStart: nil, loopEnd: nil)
        eq(stereo.frameCount, 2, "waveform: a stereo frame is two samples")
        eq(stereo.peaks, [0.25, 0], "waveform: a column takes the loudest channel")

        let short = Waveform(pcm: s16([32767, 0]), channels: 1, sampleRate: 2, columns: 5, loopStart: nil, loopEnd: nil)
        eq(short.peaks.count, 5, "waveform: more columns than frames still gives one peak per column")
        check(short.peaks.allSatisfy { $0 >= 0 && $0 <= 1 }, "waveform: peaks stay within 0...1")
        let odd = Waveform(pcm: s16([0, 0, 0]) + [7], channels: 1, sampleRate: 3, columns: 3, loopStart: nil, loopEnd: nil)
        eq(odd.frameCount, 3, "waveform: a trailing partial frame is ignored")
        let silent = Waveform(pcm: [], channels: 1, sampleRate: 1, columns: 3, loopStart: nil, loopEnd: nil)
        eq(silent.peaks, [0, 0, 0], "waveform: no audio draws flat columns")

        let looped = Waveform(pcm: s16([Int16](repeating: 100, count: 100)), channels: 1, sampleRate: 100,
                              columns: 10, loopStart: 20, loopEnd: 60)
        eq(looped.column(ofFrame: 0), 0, "waveform: the first frame is in the first column")
        eq(looped.column(ofFrame: 99), 9, "waveform: the last frame is in the last column")
        eq(looped.column(ofFrame: 25), 2, "waveform: a frame maps to its column")
        let uneven = Waveform(pcm: s16([Int16](repeating: 1, count: 10)), channels: 1, sampleRate: 10,
                              columns: 4, loopStart: nil, loopEnd: nil)
        // 10 frames over 4 columns: the peaks take frames 0-1, 2-4, 5-6 and 7-9.
        eq((0..<10).map(uneven.column), [0, 0, 1, 1, 1, 2, 2, 3, 3, 3],
           "waveform: a frame maps to the column whose peak it is part of")
        eq((0..<10).filter(looped.isInsideLoop), [2, 3, 4, 5, 6], "waveform: the columns from loop start to loop end are inside")
        eq(looped.summary, "Waveform, 1.00 s, loop from 0.20 s to 0.60 s", "waveform: the summary names length and loop")

        let rejected: [(Int, Int, String)] = [
            (20, 100, "loop points outside the sound"), (-1, 50, "loop points outside the sound"),
            (60, 20, "loop end before loop start"),
        ]
        eq(Waveform(pcm: s16([1, 2]), channels: 1, sampleRate: 2, columns: 2, loopStart: 1, loopEnd: nil).loopDescription,
           "only one loop point", "waveform: a loop start without an end is described as such")
        for (start, end, reason) in rejected {
            let bad = Waveform(pcm: s16([Int16](repeating: 1, count: 100)), channels: 1, sampleRate: 100,
                               columns: 10, loopStart: start, loopEnd: end)
            check(bad.loopStart == nil && bad.loopEnd == nil, "waveform: loop \(start)...\(end) is not drawn")
            eq(bad.loopDescription, reason, "waveform: loop \(start)...\(end) is described by what is wrong with it")
        }
        eq(looped.loopDescription, "loop from 0.20 s to 0.60 s", "waveform: the loop is described in seconds")
        let wide = Waveform(pcm: s16([1, 1]), channels: 1, sampleRate: 2, columns: 5, loopStart: 0, loopEnd: 1)
        eq((0..<5).filter(wide.isInsideLoop), [0, 1, 2, 3, 4],
           "waveform: with fewer frames than columns, every column showing a looped frame is inside")
        eq(wide.column(ofFrame: 0), 0, "waveform: a frame spread over several columns maps to the first of them")
        eq(wide.loopColumns?.first, 0, "waveform: the loop's first mark is over its first column")
        eq(wide.loopColumns?.last, 4, "waveform: the loop's last mark is over its last column")
        eq(looped.loopColumns?.first, 2, "waveform: loop columns start where the loop starts")
        eq(looped.loopColumns?.last, 6, "waveform: loop columns end where the loop ends")
        let oneFrame = Waveform(pcm: s16([Int16](repeating: 1, count: 100)), channels: 1, sampleRate: 100,
                                columns: 10, loopStart: 30, loopEnd: 30)
        eq((0..<10).filter(oneFrame.isInsideLoop), [3], "waveform: a loop that starts and ends on one frame is drawn")
        let toLast = Waveform(pcm: s16([Int16](repeating: 1, count: 100)), channels: 1, sampleRate: 100,
                              columns: 10, loopStart: 0, loopEnd: 99)
        eq((0..<10).filter(toLast.isInsideLoop).count, 10, "waveform: a loop ending on the last frame covers every column")
        eq(Waveform(pcm: s16([1, 2]), channels: 1, sampleRate: 2, columns: 0, loopStart: nil, loopEnd: nil).peaks, [],
           "waveform: zero columns give no peaks")
        eq(Waveform(pcm: s16([1, 2]), channels: 0, sampleRate: 2, columns: 2, loopStart: nil, loopEnd: nil).frameCount, 2,
           "waveform: a channel count of 0 is read as mono")
        let unlooped = Waveform(pcm: s16([Int16](repeating: 1, count: 150)), channels: 1, sampleRate: 100,
                                columns: 10, loopStart: nil, loopEnd: nil)
        eq(unlooped.summary, "Waveform, 1.50 s, no loop points", "waveform: the summary says when there are no loop points")
        eq(unlooped.loopDescription, "no loop points", "waveform: no loop keys are described as no loop points")
        check((0..<10).allSatisfy { !unlooped.isInsideLoop(column: $0) }, "waveform: without loop points no column is inside")
    }
}
