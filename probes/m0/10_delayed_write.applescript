tell application "/Applications/Capture One.app"
    with timeout of 1 second
        set exposure of adjustments of variant id "2" of document "c1-m0-1685-A.cosessiondb" to 0.875
    end timeout
end tell
