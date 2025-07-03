variable wio
variable last_addr {}

proc _check_debug_msg {} {
        variable wio
	variable last_addr
	if {$last_addr eq [reg HL]} {
		return
	}
	set last_addr [reg HL]
        if {[expr [reg HL] != [expr [reg SP] + 2]]} { 
                puts "Expecting 0x[format %x [reg HL]] from the stack, got 0x[format %x [expr [reg SP] + 2]]"
                return
        }
        set tmp [peek16 [reg HL]]
	for {set len 0; set c {}} {$c != 0} {incr len} {
		set c [peek [expr $tmp + $len]]
	}
        if {$len eq 1} { set len 10 }
	puts "found:\n[showdebuggable memory $tmp 1 $len]"
        #debug watchpoint remove $wio
}

proc check_debug_msgs {} {
        variable wio [debug watchpoint create -type write_io -address 0x2f -command _check_debug_msg]
	return {}
}

check_debug_msgs
