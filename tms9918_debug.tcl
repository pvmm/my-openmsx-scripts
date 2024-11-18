# Copyright © 2024 Pedro de Medeiros (pedro.medeiros at gmail.com)
#
# TODO:
# * MSX2/2+ support:
#   - detect VDP commands that write to VRAM;
# * detect BIOS functions that write to VRAM;
# * allow user to set watchpoints to VRAM regions (PGT, PNT, SPT, etc.);

namespace eval tms9918_debug {

variable started 0 ;# properly initialised?
variable wp {}     ;# internal watchpoint
variable vdp.r 152
variable vdp.w 153 ;# default vdp registers (0x98, 0x99)
variable v         ;# vram usage array
variable c         ;# command array
variable c_count 1 ;# command array counter

# environment variable support for debugging
proc env {varname {defaults {}}} {
	if {[info exists ::env($varname)]} {
		return $::env($varname);
	}
	return $defaults;
}

# find alternative VDP
proc scan_vdp_regs {} {
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

proc vram_pointer {} {
	expr {[debug read "VRAM pointer" 0] + 256 * [debug read "VRAM pointer" 1]}
}

proc waitbyte {} {
	variable v
	variable c
	# found observed region?
	if {[array get v [vram_pointer]] ne {}} {
		foreach idx $v([vram_pointer]) {
			#puts "running command \"[lindex $c($idx) 1]\" at 0x[format %04x [vram_pointer]]"
			eval [lindex $c($idx) 1]
		}
	}
	return
}

proc _remove_wp {} {
	variable wp
	if {$wp ne {}} {
		debug remove_watchpoint $wp
		set wp {}
	}
}

proc start {} {
	variable started 1
	_remove_wp
	variable wp
	variable vdp.r
	variable vdp.w
	set wp [debug set_watchpoint write_io ${vdp.r} {} {tms9918_debug::_catch waitbyte}]
	return
}

proc shutdown {} {
	variable c
	unset c
	variable v
	unset v
	variable c_count 1
	_remove_wp
	return
}

proc set_vram_watchpoint {addr {cmd "debug break"}} {
	variable v
	variable c
	variable c_count
	variable started
	if {$started eq 0} { start }
	if {[llength $addr] > 2} {
		error "addr: address or {<begin> <end>} value range expected"
	}
	set begin [lindex $addr 0]
	if {![string is integer -strict $begin]} {
		error "\"$begin\" is not an address"
	}
	if {[llength $addr] eq 2} {
		set end [lindex $addr 1]
		if {![string is integer -strict $end]} {
			error "\"$end\" is not an address"
		}
		set c($c_count) "{$begin $end} {$cmd}"
	} else {
		set c($c_count) "$begin {$cmd}"
		set end $begin
	}
	for {set addr $begin} {$addr <= $end} {incr addr} {
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
	set num [scan $name vw#%i]
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

proc list_vram_watchpoints {} {
	variable c
	foreach {key value} [array get c] {
		puts "vw#$key $value"
	}
}

set_help_proc tms9918_debug [namespace code tms9918_debug_help]
proc tms9918_debug_help {args} {
	if {[llength $args] eq 1} {
		return {The tms9918_debug script allows users to create watchpoints in VRAM without resorting to slow conditions.

Recognized commands: scan_vdp_regs, set_vram_watchpoint, remove_vram_watchpoint, list_vram_watchpoints, shutdown
}}
	switch -- [lindex $args 1] {
		"scan_vdp_regs" {return {Find alternative VDP ports if there is a second VDP chip.

Syntax: tms9918_debug::scan_vdp_regs
}
		}
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
		"list_vram_watchpoints" {return {List all VRAM watchpoints created by this script.

Syntax: tms9918_debug::list_vram_watchpoints
}
		}
		"shutdown" {return {Stop script execution and remove all VRAM watchpoints.

Syntax: tms9918_debug::shutdown
}
		}
	}
}

namespace export tms9918_debug

} ;# namespace tms9918_debug
