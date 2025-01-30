set pipe [open |[list bash] r+]

fconfigure $pipe -blocking 0 -buffering line
fileevent $pipe readable [list handle_output $pipe]

# Non-blocking input reading
fconfigure stdin -blocking 0 -buffering line
fileevent stdin readable [list handle_input $pipe]

proc send_command {pipe cmd} {
    puts $pipe $cmd
    flush $pipe
}

proc handle_input {pipe} {
    if {[eof $pipe]} { return }
    if {[gets stdin line] >= 0} {
        puts "Received: $line"
        if {$line eq "quit"} {
            puts "Exiting..."
            exit
        } else {
            send_command $pipe $line
        }
    } else {
        # Handle EOF (optional)
        fileevent stdin readable {}  ;# Stop listening if EOF is reached
    }
}

proc handle_output {pipe} {
    if {[eof $pipe]} {
        puts "Process closed1."
        exit
    }
    set output [read $pipe]
    puts -nonewline "output: $output"
    flush stdout
}

vwait forever

# Close the process
close $pipe
puts "Process closed."
