use framework "Foundation"
tell application "/Applications/Capture One.app"
    set d to document "c1-m0-1685-B.cosessiondb"
    if id of d is not "/private/tmp/c1-m0-1685-B" then error "Fixture mismatch"
    set current collection of d to collection "Capture" of d
    set total to count of variants of d
    set results to {}
    repeat with n in {1, 10, 100, 1000}
        if total >= n then
            repeat 5 times
                set t to current application's NSDate's timeIntervalSinceReferenceDate()
                set vals to {exposure, contrast, saturation, temperature, tint} of adjustments of (variants 1 thru n of d)
                set elapsed to (current application's NSDate's timeIntervalSinceReferenceDate()) - t
                set end of results to {strategy:"bulk-five", nVal:n as integer, secondsVal:elapsed, columnCount:count of vals, rowCount:count of item 1 of vals}
            end repeat
            set t to current application's NSDate's timeIntervalSinceReferenceDate()
            repeat with i from 1 to n
                set vals to {exposure, contrast, saturation, temperature, tint} of adjustments of variant i of d
            end repeat
            set end of results to {strategy:"loop-five", nVal:n as integer, secondsVal:((current application's NSDate's timeIntervalSinceReferenceDate()) - t)}
        end if
    end repeat
    set nestedVals to EXIF camera model of parent image of (variants 1 thru 10 of d)
    set cropVals to crop of (variants 1 thru 10 of d)
    set curveVals to rgb curve of adjustments of (variants 1 thru 2 of d)
    try
        set vList to variants 1 thru 10 of d
        set badVals to parent image of vList
        set dereferenceError to 0
    on error number errNum
        set dereferenceError to errNum
    end try
    return {totalVariants:total, timings:results, nestedMetadata:nestedVals, flatCropCount:count of cropVals, curveObjects:curveVals, listDereferenceError:dereferenceError}
end tell
