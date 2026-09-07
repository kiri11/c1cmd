use framework "Foundation"
on run argv
    set payload to current application's NSDictionary's dictionaryWithObjects:argv forKeys:{"jobId", "source", "outputs"}
    set targetPath to "/private/tmp/c1-m0-callbacks/" & (item 1 of argv) & ".plist"
    payload's writeToFile:targetPath atomically:true
end run
