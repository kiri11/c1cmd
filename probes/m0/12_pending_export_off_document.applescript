use framework "Foundation"
on run argv
    set actionName to item 1 of argv
    tell application "/Applications/Capture One.app"
        set d to document "c1-m0-1685-A.cosessiondb"
        if id of d is not "/private/tmp/c1-m0-1685-A" then error "Fixture mismatch"
        if actionName is "stage" then
            if processing queue enabled of d is not true then error "Queue already paused"
            set r to recipe "c1-m0-1685-preview" of d
            set root folder location of r to POSIX file "/private/tmp/c1-m0-1685-A/Output"
            set root folder type of r to custom location
            set output sub folder of r to "job-client-death"
            set output name format of r to "variant-2"
            set processing queue enabled of d to false
            set jobId to process (variant id "2" of d) recipe "c1-m0-1685-preview"
            set marker to current application's NSString's stringWithString:jobId
            marker's writeToFile:"/private/tmp/c1-m0-pending-job.txt" atomically:true encoding:(current application's NSUTF8StringEncoding) |error|:(missing value)
            delay 30
            return jobId
        else if actionName is "resume" then
            set processing queue enabled of d to true
        end if
        return {queueEnabled:processing queue enabled of d, jobIds:id of every job of d, jobSources:image path of every job of d, cloneQueued:queued of variant id "2" of d, historyPaths:path of every output event of variant id "2" of d}
    end tell
end run
