# Copyright © 2024 Pedro de Medeiros (pedro.medeiros at gmail.com)
#
# TODO:
# * detect BIOS function call as an interface instead of always going into BIOS code;
# * allow user to set watchpoints to VRAM regions (PGT, PNT, SPT, etc.);
# * allow user to set "watchpixels" on (x, y) coordinates in VRAM;
# * MSX2/2+ support:
#   - detect VDP commands that write to VRAM;

namespace eval tms9918_debug {

set help_text {
-----------------------------------------------------------------
 tms9918_debug 0.7 for openMSX by pvm (pedro.medeiros@gmail.com)
-----------------------------------------------------------------
}
variable started 0 ;# properly initialised?
variable wp {}     ;# internal watchpoint
variable vdp.r 152
variable vdp.w 153 ;# default vdp registers (0x98, 0x99)
variable v         ;# vram usage array
variable c         ;# command array
variable c_count 1 ;# command array counter

set help_tms9918_debug "$help_text
The tms9918_debug script allows users to create watchpoints in VRAM without resorting to conditions since they are slow.

Recognized commands:
	tms9918_debug::scan_vdp_regs
	tms9918_debug::set_vram_watchpoint
	tms9918_debug::remove_vram_watchpoint
	tms9918_debug::list_vram_watchpoints
	tms9918_debug::shutdown
"
set_help_text tms9918_debug $help_tms9918_debug

# environment variable support for debugging
proc env {varname {defaults {}}} {
	if {[info exists ::env($varname)]} {
		return $::env($varname);
	}
	return $defaults;
}

# find alternative VDP
set help_scan_vdp_regs "$help_text
Find alternative VDP ports if there is a secondary VDP.

Syntax: tms9918_debug::scan_vdp_regs
"
proc scan_vdp_regs {} {
	variable vdp.r [peek 7]
	variable vdp.w [expr ${vdp.r} + 1]
	puts "VDP ports found: #[format %x ${vdp.r}] and #[format %x ${vdp.w}]"
}
set_help_text tms9918_debug::scan_vdp_regs $help_scan_vdp_regs

# more debug stuff
proc _catch {cmd} {
	if {[catch $cmd fid]} {
		puts stderr $::errorInfo
		error $::errorInfo
		# stop barrage of error messages
		debug break
	}
}

proc vram_pointer {} {
	expr {[debug read "VRAM pointer" 0] + ([debug read "VRAM pointer" 1] << 8)}
}

proc waitbyte {} {
	variable v
	variable c
	# found observed region?
	if {[array get v [vram_pointer]] ne {}} {
		foreach idx $v([vram_pointer]) {
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
	if {[env DEBUG] eq {}} {
		set wp [debug set_watchpoint write_io ${vdp.r} {} {tms9918_debug::waitbyte}]
	} else {
		set wp [debug set_watchpoint write_io ${vdp.r} {} {tms9918_debug::_catch waitbyte}]
	}
	return
}

set help_shutdown "$help_text
Stop script execution and remove all VRAM watchpoints.

Syntax: tms9918_debug::shutdown
"
proc shutdown {} {
	variable started 0
	variable c
	unset c
	variable v
	unset v
	variable c_count 1
	_remove_wp
	return
}
set_help_text tms9918_debug::shutdown $help_shutdown
  
set help_set_vram_watchpoint "$help_text
Create VRAM watchpoint.

Syntax: tms9918_debug::set_vram_watchpoint <address> \[<command>\]

<address> may be a single value or a {<begin> <end>} region.
If <command> is not specified, \"debug break\" is used by default.
The name of the watchpoint formatted as wp#<number> is returned.
"
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
set_help_text tms9918_debug::set_vram_watchpoint $help_set_vram_watchpoint

set help_remove_vram_watchpoint "$help_text
Remove VRAM watchpoint.

Syntax: tms9918_debug::remove_vram_watchpoint <name>

<name> is the name of the watchpoint returned by set_vram_watchpoint.
"
proc remove_vram_watchpoint {name} {
	variable c
	variable v
	variable started
	if {$started eq 0} {
		error "No such watchpoint: $name"
	}
	set num [scan $name vw#%i]
	if {[array get c $num] ne {}} {
		set begin [lindex [lindex $c($num) 0] 0]
		if {[llength [lindex $c($num) 0]] eq 2} {
			set end [lindex [lindex $c($num) 0] 1]
		} else {
			set end $begin
		}
		for {set addr $begin} {$addr <= $end} {incr addr} {
			set pos [lsearch -exact $v($addr) $num]
			if {$pos >= 0} {
				# remove element from array of addresses
				set v($addr) [lreplace $v($addr) $pos $pos]
			}
		}
		unset c($num)
	} else {
		error "No such watchpoint: $name"
	}
}
set_help_text tms9918_debug::remove_vram_watchpoint $help_remove_vram_watchpoint

set help_list_vram_watchpoints "$help_text
List all VRAM watchpoints created by this script.

Syntax: tms9918_debug::list_vram_watchpoints
"
proc list_vram_watchpoints {} {
	variable c
	foreach {key value} [array get c] {
		puts "vw#$key $value"
	}
}
set_help_text tms9918_debug::list_vram_watchpoints $help_list_vram_watchpoints

} ;# namespace tms9918_debug
