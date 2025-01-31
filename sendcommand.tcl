
variable pipe    0

proc open_comm {} {
    variable pipe
    # Non-blocking comunication reading
    set pipe [open |[list bash] r+]
    fconfigure $pipe -blocking 0 -buffering line
    fileevent $pipe readable [list handle_output $pipe]
    puts "Process opened."
}

proc handle_output {pipe} {
    if {[fblocked $pipe]} {
        puts "Process closed."
        fileevent $pipe readable {}
    }
    set output ""
    while {![fblocked $pipe]} {
        append output [read $pipe]
    }
    puts -nonewline stderr "output: $output"
    flush stdout
}

proc send_command {cmd} {
    puts "send_command called"
    variable pipe
    puts $pipe $cmd
    flush $pipe
}

proc close_comm {} {
    variable pipe
    close $pipe
    puts "Process closed."
}

proc start {} {
    variable pipe
    open_comm
    send_command [list touch c]
    after time 1 [list send_command [list touch a]]
    after time 2 [list send_command [list touch b]]
    after time 3 [list send_command [list ls]]
    after time 5 [list send_command [list exit]]
}
