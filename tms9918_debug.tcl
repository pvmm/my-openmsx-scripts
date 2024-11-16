namespace eval tms9918_debug {

variable started 0
variable wp1 {}
variable wp2 {}    ;# internal watchpoints
variable vdp.r
variable vdp.w     ;# vdp registers
variable v         ;# vram usage array
variable addr      ;# current vdp address
variable status 0  ;# write-to-memory status
variable c         ;# command array
variable c_count 1 ;# command array counter

proc env {varname {defaults {}}} {
	if {[info exists ::env($varname)]} {
		return $::env($varname);
	}
	return $defaults;
}

proc rescan_vdp_reg {} {
	variable vdp.r [peek 7]
	variable vdp.w [expr ${vdp.r} + 1]
	puts "VDP ports found: #[format %x ${vdp.r}] and #[format %x ${vdp.w}]"
}

proc _catch {cmd} {
        if {[env DEBUG] ne 0} {
                if {[catch $cmd fid]} {
                        puts stderr $::errorInfo
                        error $::errorInfo
			debug break
                }
        } else {
		eval $cmd
        }
}

proc checkaddr {} {
	variable status
	variable addr
	if {$::wp_last_value eq {}} {
		return
	}
	if {$status eq 0} {
		set addr $::wp_last_value
		incr status
	} elseif {[expr $::wp_last_value & 0x40] ne 0} { ;# is it writing?
		# build 14-bit address, but first remove bit6 write access mode
		set addr [expr (($::wp_last_value & ~0x40) << 8) + $addr]
		set status 0
		#puts "address set to [format %x $addr]"
	} else {
		set addr {}
		set status 0
	}
}

proc waitbyte {} {
	variable v
	variable addr
	variable status 0 ;# force status to 0
	variable c
	# found observed region?
	if {[array get v $addr] ne {}} {
		foreach idx $v($addr) {
			#puts "running command at [format %x $addr]"
			eval [lindex $c($idx) 2]
		}
	}
	incr addr
	return
}

proc remove_wps {} {
	variable wp1
	variable wp2
	if {$wp1 ne {}} {
		debug remove_watchpoint $wp1
		set wp1 ""
	}
	if {$wp2 ne {}} {
		debug remove_watchpoint $wp2
		set wp2 ""
	}
}

proc start {} {
	variable started 1
	variable vdp.r
	variable vdp.w
	variable wp1
	variable wp2
	remove_wps
	rescan_vdp_reg
	set wp1 [debug set_watchpoint write_io ${vdp.r} {} {tms9918_debug::_catch waitbyte}]
	set wp2 [debug set_watchpoint write_io ${vdp.w} {} {tms9918_debug::_catch checkaddr}]
	return
}

proc stop {} {
	remove_wps
	return
}

proc set_vram_watchpoint {addr {cmd "debug break"}} {
	variable v
	variable c
	variable c_count
	variable started
	if {$started eq 0} { start }
	set begin [lindex $addr 0]
	if {[llength $addr] eq 1} {
		set end [lindex $addr 0]
	} elseif {[llength $addr] eq 2} {
		set end [lindex $addr 1]
	} else {
		error "addr: address or {begin end} value range expected"
	}
	set c($c_count) "$begin $end \"$cmd\""
	for {set addr $begin} {$addr < $end} {incr addr} {
		lappend v($addr) $c_count
	}
	set old_index $c_count
	incr c_count
	return "vw#${old_index}"
}

proc remove_vram_watchpoint {name} {
	variable c
	variable v
	variable started
	if {$started eq 0} {
		error "No such watchpoint: $name"
	}
	set num [scan $name vw#%c]
	if {[array get c $num] ne {}} {
		set begin [lindex c($num) 0]
		set end   [lindex c($num) 1]
		for {set addr $begin} {$addr < $end} {incr addr} {
			if {[lsearch -exact $v($addr) $num] >= 0} {
				# remove element from array of addresses
				set v($addr) [lreplace $v($addr) $num $num]
			}
		}
		unset c($num)
	} else {
		error "No such watchpoint: $name"
	}
}

namespace export tms9918_debug

} ;# namespace tms9918_debug

namespace import tms9918_debug::*
