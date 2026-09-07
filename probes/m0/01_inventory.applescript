tell application "/Applications/Capture One.app"
    set d to document "c1-m0-1685-A.cosessiondb"
    set current collection of d to collection "Capture" of d
    return {version, id of d, path of d, id of every variant of d, name of every variant of d, processing done script, batch done script, edit all selected variants}
end tell
