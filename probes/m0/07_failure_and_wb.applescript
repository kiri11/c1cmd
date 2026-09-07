tell application "/Applications/Capture One.app"
    set d to document "c1-m0-1685-A.cosessiondb"
    if id of d is not "/private/tmp/c1-m0-1685-A" then error "Fixture mismatch"
    set v to variant id "2" of d
    set baseline to {exposure, contrast, temperature, tint} of adjustments of v
    set exposure of adjustments of v to 0.6
    try
        set contrast of adjustments of v to "invalid-number"
        set failedCode to 0
    on error errText number errNum
        set failedCode to errNum
    end try
    set partialState to {exposure, contrast} of adjustments of v
    set exposure of adjustments of v to item 1 of baseline
    set temperature of adjustments of v to 5400
    set tint of adjustments of v to 5
    set tempThenTint to {temperature, tint} of adjustments of v
    set tint of adjustments of v to -3
    set temperature of adjustments of v to 6100
    set tintThenTemp to {temperature, tint} of adjustments of v
    set temperature of adjustments of v to item 3 of baseline
    set tint of adjustments of v to item 4 of baseline
    set beforePick to {id, position} of every variant of d
    set pick of variant id "3" of d to true
    set afterPick to {id, position} of every variant of d
    set pick of variant id "1" of d to true
    return {baselineVal:baseline, partialError:failedCode, partialReadback:partialState, tempThenTintVal:tempThenTint, tintThenTempVal:tintThenTemp, restoredVal:{exposure, contrast, temperature, tint} of adjustments of v, beforePickVal:beforePick, afterPickVal:afterPick, sourceMetadata:{EXIF camera model, EXIF ISO, EXIF shutter speed} of parent image of v}
end tell
