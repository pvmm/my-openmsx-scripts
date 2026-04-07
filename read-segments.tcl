# read segment data from romblocks by Pedro de Medeiros (pvm): pedro.medeiros@gmail.com

# read currently selected segments (8-bit version, tested)
proc read_segments {slot subslot} {
        set romname [machine_info slot $slot $subslot 1]
        set seglayout {}
        for {set page 0} {$page < 4} {incr page} {
                lappend seglayout [debug read "$romname romblocks" [expr ($page * 0x4000)]]
                lappend seglayout [debug read "$romname romblocks" [expr ($page * 0x4000 + 0x2000)]]
        }
        return $seglayout
}

# read currently selected segments (NEO-8 version, untested)
proc read_segments_neo8 {slot subslot} {
	set romname [machine_info slot $slot $subslot 1]
	set seglayout {}
	for {set page 0} {$page < 4} {incr page} {
		set  tmp [debug read "$romname romblocks" [expr {$page * 0x4000}]]
		incr tmp [expr {[debug read "$romname romblocks" [expr {$page * 0x4000 + 1}]] << 8}]
		lappend seglayout $tmp
		set  tmp [debug read "$romname romblocks" [expr {$page * 0x4000 + 0x2000}]]
		incr tmp [expr {[debug read "$romname romblocks" [expr {$page * 0x4000 + 0x2001}]] << 8}]
		lappend seglayout $tmp
	}
	return $seglayout
}

# read currently selected segments (NEO-16 version, untested)
proc read_segments_neo16 {slot subslot} {
	set romname [machine_info slot $slot $subslot 1]
	set seglayout {}
	for {set page 0} {$page < 4} {incr page} {
		set  tmp [debug read "$romname romblocks" [expr {$page * 0x4000}]]
		incr tmp [expr {[debug read "$romname romblocks" [expr {$page * 0x4000 + 1}]] << 8}]
		lappend seglayout $tmp
	}
	return $seglayout
}

# read currently selected segment (ASCIIX16 version, tested)
#
# How to use:
# 1) call "trace_segments <slot> <subslot>" to activate watchpoints;
# 2) call "read_segment <address>" for the address you are interested in;
# 3) call "untrace_segments" to deactivate watchpoints (or just close openMSX);
#
variable wp {}
array set seglayout { 0 -1 1 -1 2 -1 3 -1} ;# only pages 1 and 2 are used

proc read_segment {address} {
	set result {}
	variable seglayout
	return $seglayout([expr {$address >> 14}])
}

proc _update_segment {} {
	set lsb $::wp_last_value
	set msb [expr {($::wp_last_address >> 8) & 0xf}]
	set page [expr {(($::wp_last_address >> 12) & 1) + 1}]
	variable seglayout
	set seglayout($page) [expr {($msb << 8) + $lsb}]
}

# turn it on first
proc trace_segments {slot subslot} {
	variable wp
	set wp [debug watchpoint create -type write_mem -address {0x6000 0x7fff} -condition "\[watch_in_slot $slot $subslot\]" -command _update_segment]
}

# turn if off when done
proc untrace_segments {} {
	variable wp
	if {$wp ne {}} {
		debug watchpoint remove $wp
	}
}

