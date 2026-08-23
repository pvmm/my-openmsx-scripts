proc toggle_breakpoint {bpname} {
    foreach {id body} [debug breakpoint list] {
        if {$id eq $bpname} {
            set enabled [dict get $body -enabled]
            debug breakpoint configure $bpname -enabled [expr {!$enabled}]
            return
        }
    }
    error "Breakpoint '$bpname' not found"
}
