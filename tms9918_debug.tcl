# Copyright © 2024 Pedro de Medeiros (pedro.medeiros at gmail.com)
#
# TODO:
# * MSX2/2+ support:
#   - detect VDP commands that write to VRAM;
# * detect BIOS functions that write to VRAM;
# * allow user to set watchpoints to VRAM regions (PGT, PNT, SPT, etc.);

namespace eval tms9918_debug {

variable started 0 ;# properly initialised?
variable wp1 {}
variable wp2 {}    ;# internal watchpoints
variable vdp.r
variable vdp.w     ;# vdp registers
variable v         ;# vram usage array
variable addr      ;# current vdp address
variable status 0  ;# write-to-vram address status (0 = LSB, 1 = MSB)
variable c         ;# command array
variable c_count 1 ;# command array counter

# environment variable support for debugging
proc env {varname {defaults {}}} {
	if {[info exists ::env($varname)]} {
		return $::env($varname);
	}
	return $defaults;
}

# find VDP ports
proc rescan_vdp_reg {} {
	variable vdp.r [peek 7]
	variable vdp.w [expr ${vdp.r} + 1]
	puts "VDP ports found: #[format %x ${vdp.r}] and #[format %x ${vdp.w}]"
}

# more debug stuff
proc _catch {cmd} {
	if {[env DEBUG] ne 0} {
		if {[catch $cmd fid]} {
			puts stderr $::errorInfo
			error $::errorInfo
			# stop barrage of error messages
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
	incr addr ;# reused address incremented
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

set_help_proc tms9918_debug [namespace code tms9918_debug_help]
proc tms9918_debug_help {args} {
	if {[llength $args] eq 1} {
		return {The tms9918_debug script allows users to create watchpoints in VRAM without resorting to slow conditions.

Recognized commands: set_vram_watchpoint, remove_vram_watchpoint
}}
	switch -- [lindex $args 1] {
		"set_vram_watchpoint" {return {Create VRAM watchpoint.

Syntax: tms9918_debug::set_vram_watchpoint <address> [<command>]

<address> may be a single value or a {<begin> <end>} region.
If <command> is not specified, "debug break" is used by default.
The name of the watchpoint formatted as wp#<number> is returned.
}
		}
		"remove_vram_watchpoint" {return {Remove VRAM watchpoint.

Syntax: tms9918_debug::remove_vram_watchpoint <name>

<name> is the name of the watchpoint returned by set_vram_watchpoint.
}
		}
	}
}

namespace export tms9918_debug

} ;# namespace tms9918_debug

namespace import tms9918_debug::*
