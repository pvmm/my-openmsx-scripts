# Copyright © 2024-2026 Pedro de Medeiros (pedro.medeiros at gmail.com)
#
# TODO:
# * MSX2/2+ support:
#   - detect VDP commands that write to VRAM;
# * detect BIOS function call as an entry point instead of always going inside BIOS code;
# * allow user to attach watchpoints to VRAM regions (PGT, PNT, SPT, etc.);
# * allow user to set "watchpixels" on (x, y) coordinates in VRAM;

namespace eval vdpdebugger {

array set mem {}        ;# vram usage array
variable vpw {}         ;# vdp port watchpoint
variable pw {}          ;# VDP.command probe watchpoint
variable vdp 0x98       ;# default vdp port
variable vbp {}         ;# store vram watchpoint
variable vbp_counter 0  ;# command array counter

set_help_text vdpdebugger {----------------------------------------------------------------
 vdp debugger 1.0 for openMSX by pvm (pedro.medeiros@gmail.com)
----------------------------------------------------------------

The vdp debugger script allows users to create watchpoints in VRAM without resorting to conditions since they are slow.

Recognized commands:
	vdpdebugger::scan_vdp                   Detect first VDP register
	vdpdebugger::set_vram_watchpoint        Set VRAM watchpoint on address or region
	vdpdebugger::remove_vram_watchpoint     Removfe VRAM watchpoint by name
	vdpdebugger::list_vram_watchpoints      List current VRAM watchpoints
	vdpdebugger::vram_pointer               Return last used VRAM address
	vdpdebugger::shutdown                   Disable vdp debugger completely

type \"help <command>\" for more details.
}

set_help_text vdpdebugger::scan_vdp {Find current VDP port if there is a second VDP for instance.

Syntax: vdpdebugger::scan_vdp
}
proc scan_vdp {} {
	variable vdp [peek 7]
	puts "VDP port found at #[format %x ${vdp}]"
}

# catch error and display more useful information like a stack trace
proc _catch {cmd} {
	if {[catch $cmd fid]} {
		puts stderr $::errorInfo
		error $::errorInfo
		# stop barrage of error messages
		debug break
	}
}

set_help_text vdpdebugger::vram_pointer {Return last VRAM address used.

Syntax: vdpdebugger::vram_pointer
}
proc vram_pointer {} {
	peek16 0 "VRAM pointer"
}

proc _receive_byte {} {
	variable mem
	variable vbp
	# found observed region?
	set addr [vram_pointer]
	if {[array_exists mem $addr]} {
		foreach index $mem($addr) {
			lassign [dict get $vbp $index] begin end cmd
			eval $cmd
		}
	}
}

proc _receive_cmd {} {
	# TODO: read vdp regs just like reportVdpCommand
}

proc _remove_wps {} {
	variable vpw
	if {$vpw ne {}} {
		debug remove_watchpoint $vpw
		set vpw {}
	}
}

proc _start {} {
	variable vbp
	if {$vbp ne {}} { return }

	_remove_wps
	variable DEBUG
	variable vpw
	variable vdp
	if {$DEBUG eq {}} {
		set vpw [debug set_watchpoint write_io $vdp {} [namespace code "_receive_byte"]]
		#set pw [debug probe set_bp VDP.commandExecuting {} vdpdebugger::receive_cmd]
	} else {
		set vpw [debug set_watchpoint write_io $vdp {} [namespace code "_catch _receive_byte"]]
		#set pw [debug probe set_bp VDP.commandExecuting {} {vdpdebugger::_catch receive_cmd}]
	}
}

set_help_text vdpdebugger::shutdown {Stop script execution and remove all VRAM watchpoints.

Syntax: vdpdebugger::shutdown
}
proc shutdown {} {
	variable vbp {}
	variable mem
	array unset mem
	variable counter 0
	_remove_wps
}

proc array_exists {arname id} {
	upvar 1 $arname tmp
	expr {[info exists tmp($id)]}
}

set_help_text vdpdebugger::set_vram_watchpoint {Create VRAM watchpoint.

Syntax: vdpdebugger::set_vram_watchpoint <address> [<command>]

<address> may be a single value or a {<begin> <end>} region.
If <command> is not specified, "debug break" is used by default.
The name of the watchpoint formatted as wp#<number> is returned.
}
proc set_vram_watchpoint {addr {cmd "debug break"}} {
	variable vbp
	if {$vbp eq {}} { _start }
	if {[llength $addr] > 2} {
		error "addr: <address> or {<begin> <end>} value range expected"
	}
	lassign $addr begin end
	if {![string is integer -strict $begin]} {
		error "\"$begin\" is not an address"
	}
	if {$end eq {}} {
		set end $begin
	} elseif {![string is integer -strict $end]} {
		error "\"$end\" is not an address"
	}
	variable vbp_counter
	incr vbp_counter
	dict set vbp $vbp_counter "$begin $end \"$cmd\""
	variable mem
	for {set addr $begin} {$addr <= $end} {incr addr} {
		if {[array_exists mem $addr]} {
			lappend mem($addr) $vbp_counter
		} else {
			set mem($addr) $vbp_counter
		}
	}
	return vw#$vbp_counter
}

set_help_text vdpdebugger::remove_vram_watchpoint {Remove VRAM watchpoint.

Syntax: vdpdebugger::remove_vram_watchpoint vw#<number>

<name> is the name of the watchpoint returned by set_vram_watchpoint.
}
proc remove_vram_watchpoint {name} {
	variable vbp
	variable mem
	if {$vbp eq {}} {
		error "No such watchpoint: $name"
	}
	set id [scan $name vw#%i]
	if {[dict exists $vbp $id]} {
		lassign [dict get $vbp $id] begin end
		dict unset vbp $id
		for {set addr $begin} {$addr <= $end} {incr addr} {
			if {![array_exists mem $addr]} { continue }
			set pos [lsearch -exact $mem($addr) $id]
			if {$pos >= 0} {
				# remove element from array of addresses
				set mem($addr) [lreplace $mem($addr) $pos $pos]
			}
		}
	} else {
		error "No such watchpoint: $name"
	}
}

proc h {addr} {
	format %04x $addr
}

set_help_text vdpdebugger::list_vram_watchpoints {List all VRAM watchpoints created by this script.

Syntax: vdpdebugger::list_vram_watchpoints
}
proc list_vram_watchpoints {} {
	variable vbp
	dict for {id bp} $vbp {
		lassign $bp begin end cmd
		puts "vw#$id [h $begin]:[h $end] {$cmd}"
	}
}

# DEBUG mode
variable DEBUG 0

} ;# namespace vdpdebugger
