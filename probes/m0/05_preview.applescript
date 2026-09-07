use framework "Foundation"
on run argv
    set jobFolder to item 1 of argv
    set variantId to item 2 of argv
    tell application "/Applications/Capture One.app"
        set d to document "c1-m0-1685-A.cosessiondb"
        if id of d is not "/private/tmp/c1-m0-1685-A" then error "Fixture mismatch"
        set r to recipe "c1-m0-1685-preview" of d
        set color profile of r to "sRGB Color Space Profile"
        set root folder location of r to POSIX file "/private/tmp/c1-m0-1685-A/Output"
        set root folder type of r to custom location
        set output sub folder of r to jobFolder
        set output name format of r to "variant-" & variantId
        if color profile of r is not "sRGB Color Space Profile" then error "Profile readback mismatch"
        if root folder type of r is not custom location then error "Root type readback mismatch"
        set startTime to current application's NSDate's timeIntervalSinceReferenceDate()
        set jobId to process (variant id variantId of d) recipe "c1-m0-1685-preview"
        set samples to {}
        repeat 100 times
            set t to current application's NSDate's timeIntervalSinceReferenceDate()
            set jobIds to id of every job of d
            set isQueued to queued of variant id variantId of d
            set ev to exposure of adjustments of variant id variantId of d
            set elapsed to (current application's NSDate's timeIntervalSinceReferenceDate()) - t
            set end of samples to {jobIds, isQueued, ev, elapsed}
            if not isQueued and jobIds does not contain jobId then exit repeat
            delay 0.1
        end repeat
        return {jobIdVal:jobId, durationVal:((current application's NSDate's timeIntervalSinceReferenceDate()) - startTime), recipeProfile:color profile of r, rootType:root folder type of r, historyPaths:path of every output event of variant id variantId of d, samplesVal:samples}
    end tell
end run
