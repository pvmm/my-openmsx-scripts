namespace eval codeanalyzer {

;# TODO:
;# * finish all z80 instructions;
;# * BIOS support;
;# * detect code size using disassembler;
;# * write assembly output to file;
;# * annotate unscanned code when writing output file;
;# * allow user to set markers on the code;
;# * try to detect functions;
;#   ** detect call/ret combinations;
;# * try to detect all types of RAM-to-VRAM memory copying:
;#   ** pattern generator table (PGT)
;#   ** name table;
;#   ** colour table;
;#   ** sprite generator table;
;#   ** sprite attribute table;
;# * try to detect keyboard input;
;# * try to detect joystick port input;
;# * try to detect sound generation (PSG);

variable m_type ""
variable m ;# memory
variable pc
variable slot
variable segment
variable ss ""
variable cond {}
variable entry_point {}
# info
variable datarecs 0 ;# data records
variable coderecs 0 ;# code records
variable bothrecs 0 ;# both records

;# constants
proc NAUGHT	{} { return {}}
proc CODE	{} { return 1 }
proc DATA	{} { return 2 }
proc BOTH	{} { return 3 }

set_help_proc codeanalyzer [namespace code codeanalyzer_help]
proc codeanalyzer_help {args} {
	if {[llength $args] == 1} {
		return {The codeanalyzer script creates annotated source code from dynamically analyzing running programs.
Recognized commands: start, stop, scancart, info, pixel
}
	}
	switch -- [lindex $args 1] {
		"start"	{ return {Start script that analyzes code.

Syntax: codeanalyzer start <slot> [<subslot>]

Analyze code from specified slot (0..3) and subslot (0..3).
}}
		"stop"  { return {Stop script that analyzes code.

Syntax: codeanalyzer stop
}}
		"scancart" { return {Search for cartridge ROM signature in specified slot/subslot.

Syntax: codeanalyzer scancart
}}
		"info" { return {Print info about code analysis to console.

Syntax: codeanalyzer info
}}
		"pixel" { return {Find piece of code that writes to screen positon (x, y).

Syntax: codeanalyzer pixel <x> <y>
}}
		default { error "Unknown command \"[lindex $args 1]\"."
}
	}
}

proc codeanalyzer {args} {
	if {[info exists ::env(DEBUG)] && $::env(DEBUG) ne 0} {
		if {[catch {_codeanalyzer {*}$args} fid]} {
			debug break 
			puts stderr $::errorInfo
			error $::errorInfo
		}
	} else {
		_codeanalyzer {*}$args
	}
	return
}

proc _codeanalyzer {args} {
	set params "[lrange $args 1 end]"
	switch -- [lindex $args 0] {
		"start"    { return [codeanalyzer_start {*}$params] }
		"stop"     { return [codeanalyzer_stop {*}$params] }
		"scancart" { return [codeanalyzer_scancart {*}$params] }
		"info"     { return [codeanalyzer_info {*}$params] }
		default    { error "Unknown command \"[lindex $args 0]\"." }
	}
}

proc slot {} {
	variable slot
	if {[info exists slot]} {
		return [lindex $slot 0]
	}
	return {}
}

proc subslot {} {
	variable slot
	if {[info exists slot]} {
		return [lindex $slot 1]
	}
	return {}
}

proc reset_info {} {
	variable m_type ""
	variable m
	unset m
	variable entry_point ""
	variable datarecs 0
	variable coderecs 0
	variable bothrecs 0
}

proc codeanalyzer_start {args} {
	variable m_type
	variable pc {}
	variable entry_point
	variable cond

	if {$args eq {} || [llength $args] > 2} {
		error "wrong # args: should be slot ?subslot?"
	}

	;# check slot subslot configuration
	set tmp [lrange $args 0 end]
	if {[machine_info issubslotted [lindex $tmp 0]]} {
		if {[llength $tmp] ne 2} {
			error "slot $slot is extended but subslot parameter is missing."
		}
	} elseif {[llength $tmp] ne 1} {
		error "slot is not extended but subslot is defined."
	}
	variable slot
	if {[info exists slot] && $slot ne $args} {
		puts "resetting entry point"
		reset_info
	}
	set slot $tmp
	;# set condition according to slot and subslot
	if {$cond eq ""} {
		puts "codeanalyzer started"
		if {$entry_point eq ""} {
			codeanalyzer_scancart
		}
		set cond [debug set_condition "\[pc_in_slot $slot\]" codeanalyzer::_checkmem]
	} else {
		puts "Nothing to start."
	}

	return ;# no output
}

proc codeanalyzer_stop {} {
	variable cond

	if {$cond ne ""} {
		puts "Codeanalyzer stopped."
		debug remove_condition $cond
		set cond ""
	} else {
		puts "Nothing to stop."
	}
}

proc _scanmemtype {} {
	variable m_type
	set byte [peek [reg PC]]
	poke [reg PC] [expr $byte ^ 1]
	if {[peek [reg PC]] eq $byte} {
		set m_type ROM
	} else {
		set m_type RAM
	}
}

proc codeanalyzer_scancart {} {
	variable slot
	variable subslot

	if {![info exists slot]} {
		error "no slot defined"
	}
	variable ss [slot]
	if {[machine_info issubslotted [slot]]} {
		if {[subslot] eq ""} {
			error "no subslot defined"
		}
		append ss "-[subslot]"
	}

	_scancart
}

proc _scancart {} {
	variable m_type
	variable ss
	variable slot
	variable entry_point

	set base [expr [slot] << 18]
	foreach offset [list 0x4000 0x8000 0x0000] { ;# memory search order
		set addr [expr $base + $offset]
		set tmp [peek16 $addr {slotted memory}]
		set prefix [format %c%c [expr $tmp & 0xff] [expr $tmp >> 8]]
		if {$prefix eq "AB"} {
			set m_type ROM
			puts "prefix found at $ss:[format %04x [expr $addr & 0xffff]]"
			set entry_point [peek16 [expr $addr + 2] {slotted memory}]
			puts "entry point found at [format %04x $entry_point]"
		}
	}
	if {$entry_point eq ""} {
		puts "no cartridge signature found"
		set entry_point ""
		debug set_condition "\[pc_in_slot $slot\]" -once codeanalyzer::_scanmemtype
	}
}

proc codeanalyzer_info {} {
	variable ss
	if {$ss eq ""} {
		error "codeanalyzer was never executed."
	}

	variable m_type
	variable entry_point
	variable datarecs
	variable coderecs
	variable bothrecs
	variable cond

	puts "running on slot $ss"
	puts -nonewline "memory type: "
	if {$m_type ne ""} {
		puts $m_type
	} else {
		puts "???"
	}
	puts -nonewline "entry point: "
	if {$entry_point ne ""} {
		puts [format %04x $entry_point]
	} else {
		puts "undefined"
	}
	puts "number of DATA records: $datarecs"
	puts "number of CODE records: $coderecs"
	puts "number of BOTH records: $bothrecs"

	puts -nonewline "codeanalyzer "
	if {$cond ne ""} {
		puts "still running"
	} else {
		puts "stopped"
	}
}

proc log {s} {
	if {[info exists ::env(DEBUG)] && $::env(DEBUG) ne 0} {
		puts stderr $s
		puts $s
	}
}

proc _markdata {addr} {
	variable m
	variable slot
	variable datarecs
	variable coderecs
	variable bothrecs
	set type [array get m $addr]

	if {$type eq [NAUGHT]} {
		set m($addr) [DATA]
		log "marking [format %04x $addr] as DATA"
		incr datarecs
	} elseif {$m($addr) eq [CODE]} {
		log "warning: overwritting address type in [format %04x $addr] from CODE to BOTH"
		set m($addr) [BOTH]
		incr coderecs -1
		incr bothrecs
	}
}

proc markdata {first args} {
	_markdata $first
	foreach addr $args { _markdata $addr }
}

proc markcode {addr} {
	variable m
	variable datarecs
	variable coderecs
	variable bothrecs
	set type [array get m $addr]

	if {$type eq [NAUGHT]} {
		set m($addr) [CODE]
		log "marking [format %04x $addr] as CODE"
		incr coderecs
	} elseif {$m($addr) eq [DATA]} {
		log "warning: overwritting address type in [format %04x $addr] from DATA to BOTH"
		set m($addr) [BOTH]
		incr datarecs -1
		incr bothrecs
	}
}

proc _checkmem {} {
	variable m
	variable pc [reg PC]
	variable hl [reg HL]
	variable bc [reg BC]
	variable de [reg DE]
	variable ix [reg IX]
	variable iy [reg IY]
	variable p1 [expr $pc + 1]
	variable p2 [expr $pc + 2]
	variable p3 [expr $pc + 3]

	;# CODE memory
	if {[array get m $pc] eq ""} {
		markcode $pc
	}
	;# DATA memory
	switch -- [format %02x [peek $pc]] {
		02 { markdata $bc }
		0a { markdata $bc }
		10 { markcode [peek $p1] }
		12 { markdata $de }
		18 { markcode [expr $pc + [peek $p1]] }
		1a { markdata $de }
		20 { markcode [expr $pc + [peek $p1]] }
		28 { markcode [expr $pc + [peek $p1]] }
		2a { markdata [peek16 $p1] }
		30 { markcode [expr $pc + [peek $p1]] }
		32 { markdata [peek16 $p1] }
		34 { markdata $hl }
		35 { markdata $hl }
		36 { markdata $hl }
		38 { markcode [expr $pc + [peek $p1]] }
		3a { markdata [peek16 $p1] }
		46 { markdata $hl }
		4e { markdata $hl }
		56 { markdata $hl }
		5e { markdata $hl }
		66 { markdata $hl }
		6e { markdata $hl }
		70 { markdata $hl }
		71 { markdata $hl }
		72 { markdata $hl }
		73 { markdata $hl }
		74 { markdata $hl }
		75 { markdata $hl }
		77 { markdata $hl }
		7e { markdata $hl }
		86 { markdata $hl }
		8e { markdata $hl }
		96 { markdata $hl }
		9e { markdata $hl }
		a6 { markdata $hl }
		ae { markdata $hl }
		b6 { markdata $hl }
		be { markdata $hl }
		c4 { markcode [peek16 $p1] }
		cb { ;# bit operations with (HL)
			switch -- [format %02x [peek $p1]] {
				06 { markdata $hl }
				0e { markdata $hl }
				16 { markdata $hl }
				1e { markdata $hl }
				26 { markdata $hl }
				2e { markdata $hl }
				36 { markdata $hl }
				3e { markdata $hl }
				46 { markdata $hl }
				4e { markdata $hl }
				56 { markdata $hl }
				5e { markdata $hl }
				66 { markdata $hl }
				6e { markdata $hl }
				76 { markdata $hl }
				7e { markdata $hl }
				86 { markdata $hl }
				8e { markdata $hl }
				96 { markdata $hl }
				9e { markdata $hl }
				a6 { markdata $hl }
				ae { markdata $hl }
				b6 { markdata $hl }
				be { markdata $hl }
				c6 { markdata $hl }
				ce { markdata $hl }
				d6 { markdata $hl }
				de { markdata $hl }
				e6 { markdata $hl }
				ee { markdata $hl }
				f6 { markdata $hl }
				fe { markdata $hl }
			}
		}
		cc { markcode [peek16 $p1] }
		cd { markcode [peek16 $p1] }
		d4 { markcode [peek16 $p1] }
		dc { markcode [peek16 $p1] }
		e4 { markcode [peek16 $p1] }
		e9 { markcode $hl }
		ec { markcode [peek16 $p1] }
		ed {
			switch -- [format %02x [peek $p1]] {
				4b { markdata [peek16 $p2] }
				5b { markdata [peek16 $p2] }
				6b { markdata [peek16 $p2] }
				7b { markdata [peek16 $p2] }
				a1 { markdata $hl }
				a9 { markdata $hl }
				b1 { markdata $hl }
				b9 { markdata $hl }
				a0 { markdata $hl $de }
				a8 { markdata $hl $de }
				b0 {
					set bc_ $bc
					set hl_ $hl
					set de_ $de
					for {} {$bc_ != -1} {incr bc_ -1} {
						markdata $hl_ $de_
						incr hl_
						incr de_
					}
				}
				b8 {
					set bc_ $bc
					set hl_ $hl
					set de_ $de
					for {} {$bc_ != -1} {incr bc_ -1} {
						markdata $hl_ $de_
						incr hl_ -1
						incr de_ -1
					}
				}
			}
		}
		dd { ;# operation with IX somewhere
			switch -- [format %02x [peek $p1]] {
				2a      { markdata [expr [peek16 $p2]] }
				46      { markdata [expr $ix + [peek $p2]] }
				4e      { markdata [expr $ix + [peek $p2]] }
				56      { markdata [expr $ix + [peek $p2]] }
				5e      { markdata [expr $ix + [peek $p2]] }
				66      { markdata [expr $ix + [peek $p2]] }
				6e      { markdata [expr $ix + [peek $p2]] }
				7e      { markdata [expr $ix + [peek $p2]] }
				e9      { markcode $ix }
				default { markdata [expr $ix + [peek $p2]] }
			}
		}
		f4 { markcode [peek16 $p1] }
		fc { markcode [peek16 $p1] }
		fd { ;# operation with IY somewhere
			switch -- [peek $p1] {
				2a      { markdata [peek16 $p2] }
				46      { markdata [expr $iy + [peek $p2]] }
				4e      { markdata [expr $iy + [peek $p2]] }
				56      { markdata [expr $iy + [peek $p2]] }
				5e      { markdata [expr $iy + [peek $p2]] }
				66      { markdata [expr $iy + [peek $p2]] }
				6e      { markdata [expr $iy + [peek $p2]] }
				7e      { markdata [expr $iy + [peek $p2]] }
				e9      { markcode $iy }
				default { markdata [expr $iy + [peek $p2]] }
			}
		}
	}
}

namespace export codeanalyzer

} ;# namespace codeanalyzer

namespace import codeanalyzer::*
