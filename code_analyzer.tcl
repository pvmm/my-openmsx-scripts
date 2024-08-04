namespace eval codeanalyzer {

;# TODO:
;# * detect code size using disassembler;
;# * write assembly output to file;
;# * try to detect functions;
;# * try to detect all types of RAM-to-VRAM memory copying:
;#   ** pattern generator table (PGT)
;#   ** name table;
;#   ** colour table;
;#   ** sprite generator table;
;#   ** sprite attribute table;
;# * try to detect keyboard input;
;# * try to detect joystick port input;
;# * try to detect sound generation (PSG);

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
	return [lindex $slot 0]
}

proc subslot {} {
	variable slot
	return [lindex $slot 1]
}

proc codeanalyzer_start {args} {
	variable pc {}
	variable entry_point
	variable cond

	if {$args eq {} || [llength $args] > 2} {
		error "wrong # args: should be slot subslot"
	}

	;# check slot subslot configuration
	variable slot [lrange $args 0 end]
	if {[machine_info issubslotted [slot]]} {
		if {[subslot] eq ""} {
			error "slot $slot is extended but subslot parameter is missing."
		}
	} elseif {[subslot] ne ""} {
		error "slot is not extended but subslot is defined."
	}
	;# set condition according to slot and subslot
	if {$cond eq ""} {
		puts "Codeanalyzer started."
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

proc codeanalyzer_scancart {} {
	variable slot
	variable subslot
	variable entry_point

	if {![info exists slot]} {
		error "no slot defined"
	}
	variable ss $slot
	if {[machine_info issubslotted [slot]]} {
		if {[subslot] eq ""} {
			error "no subslot defined"
		}
		append ss "-[subslot]"
	}

	debug set_condition "\[pc_in_slot $slot\]" -once codeanalyzer::_do_scancart
}

proc _do_scancart {} {
	variable ss
	foreach addr [list 0x4000 0x8000 0x0000] { ;# memory search order
		set prefix [format %c%c [peek $addr] [peek [expr $addr + 1]]]
		if {$prefix eq "AB"} {
			puts "prefix found at $ss:$addr"
			set entry_point [peek16 [expr $addr + 2]]
			puts "entry point found at [format %04x $entry_point]"
		}
	}
	if {$entry_point eq ""} {
		puts "no cartridge signature found"
	}
}

proc codeanalyzer_info {} {
	variable ss
	if {$ss eq ""} {
		error "codeanalyzer was never executed."
	}

	variable entry_point
	variable datarecs
	variable coderecs
	variable bothrecs
	variable cond

	puts "running on slot $ss"
	if {$entry_point eq ""} {
		puts "entry point is undefined"
	} else {
		puts "entry point is [format %04x $entry_point]"
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

proc markdata {addr} {
	variable m
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
		02 { ;# LD (BC),A
			markdata $bc
		}
		12 { ;# LD (DE),A
			markdata $de
		}
		32 { ;# LD (word),A
			set word [peek16 $p1]
			markdata $word
		}
		7e { ;# LD A,(HL)
			markdata $hl
		}
		46 { ;# LD B,(HL)
			markdata $hl
		}
		4e { ;# LD C,(HL)
			markdata $hl
		}
		56 { ;# LD D,(HL)
			markdata $hl
		}
		5e { ;# LD E,(HL)
			markdata $hl
		}
		66 { ;# LD H,(HL)
			markdata $hl
		}
		6e { ;# LD L,(HL)
			markdata $hl
		}
		77 { ;# LD (HL),A
			markdata $hl
		}
		70 { ;# LD (HL),B
			markdata $hl
		}
		71 { ;# LD (HL),C
			markdata $hl
		}
		72 { ;# LD (HL),D
			markdata $hl
		}
		73 { ;# LD (HL),E
			markdata $hl
		}
		74 { ;# LD (HL),H
			markdata $hl
		}
		75 { ;# LD (HL),L
			markdata $hl
		}
		0a { ;# LD A,(BC)
			markdata $bc
		}
		1a { ;# LD A,(DE)
			markdata $de
		}
		2a { ;# LD HL,(word)
			set word [peek16 $p1]
			markdata $word
		}
		34 { ;# INC (HL)
			markdata $hl
		}
		35 { ;# DEC (HL)
			markdata $hl
		}
		36 { ;# LD (HL),byte
			markdata $hl
		}
		3a { ;# LD A,(word) # 0x3a
			set word [peek16 $p1]
			markdata $word
		}
		86 { ;# ADD A, (HL)
			markdata $hl
		}
		8e { ;# ADC A, (HL)
			markdata $hl
		}
		96 { ;# SUB A, (HL)
			markdata $hl
		}
		9e { ;# SBC A, (HL)
			markdata $hl
		}
		a6 { ;# AND (HL)
			markdata $hl
		}
		ae { ;# XOR (HL)
			markdata $hl
		}
		b6 { ;# OR (HL)
			markdata $hl
		}
		be { ;# CP (HL)
			markdata $hl
		}
		cb { ;# rotations with (HL)
			if {[peek $p1] == 0x06} { ;# RLC (HL)
				markdata $hl
			} elseif {[peek $p1] == 0x0e} { ;# RRC (HL)
				markdata $hl
			} elseif {[peek $p1] == 0x16} { ;# RL (HL)
				markdata $hl
			} elseif {[peek $p1] == 0x1e} { ;# RL (HL)
				markdata $hl
			} elseif {[peek $p1] == 0x26} { ;# SLA (HL)
				markdata $hl
			} elseif {[peek $p1] == 0x2e} { ;# SRA (HL)
				markdata $hl
			} elseif {[peek $p1] == 0x3e} { ;# SRL (HL)
				markdata $hl
			} elseif {[peek $p1] == 0x46} { ;# BIT 0,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0x4e} { ;# BIT 1,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0x56} { ;# BIT 2,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0x5e} { ;# BIT 3,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0x66} { ;# BIT 4,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0x6e} { ;# BIT 5,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0x76} { ;# BIT 6,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0x7e} { ;# BIT 7,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0x86} { ;# RES 0,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0x8e} { ;# RES 1,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0x96} { ;# RES 2,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0x9e} { ;# RES 3,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xa6} { ;# RES 4,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xae} { ;# RES 5,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xb6} { ;# RES 6,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xbe} { ;# RES 7,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xc6} { ;# BIT 0,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xce} { ;# BIT 1,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xd6} { ;# BIT 2,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xde} { ;# BIT 3,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xe6} { ;# BIT 4,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xee} { ;# BIT 5,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xf6} { ;# BIT 6,(HL)
				markdata $hl
			} elseif {[peek $p1] == 0xfe} { ;# BIT 7,(HL)
				markdata $hl
			}
		}
		e9 { ;# JP (HL)
			markcode $hl
		}
		ed {
			;# LD XX, (word)
			if {[peek $p1] == 0x4b} { ;# XX=BC
				set word [peek16 $p2]
				markdata $word
			} elseif {[peek $p1] == 0x5b} { ;# XX=DE
				set word [peek16 $p2]
				markdata $word
			} elseif {[peek $p1] == 0x6b} { ;# XX=HL
				set word [peek16 $p2]
				markdata $word
			} elseif {[peek $p1] == 0x7b} { ;# XX=SP
				set word [peek16 $p2]
				markdata $word
			;# CP operations with (HL)
			} elseif {[peek $p1] == 0xa1} { ;# CPI
				markdata $hl
			} elseif {[peek $p1] == 0xb1} { ;# CPIR
				markdata $hl
			} elseif {[peek $p1] == 0xa9} { ;# CPD
				markdata $hl
			} elseif {[peek $p1] == 0xb9} { ;# CPDR
				markdata $hl
			}
		}
		dd { ;# operation with IX somewhere
			if {[peek $p1] == 0xe9} { ;# JP (IX)
				markcode $ix
			} elseif {[peek $p1] == 0x7e} { ;# LD X=A, (IX + index)
				set index [peek $p2]
				markdata [expr $ix + $index]
			} elseif {[peek $p1] == 0x46} { ;# X=B
				set index [peek $p2]
				markdata [expr $ix + $index]
			} elseif {[peek $p1] == 0x4e} { ;# X=C
				set index [peek $p2]
				markdata [expr $ix + $index]
			} elseif {[peek $p1] == 0x56} { ;# X=D
				set index [peek $p2]
				markdata [expr $ix + $index]
			} elseif {[peek $p1] == 0x5e} { ;# X=E
				set index [peek $p2]
				markdata [expr $ix + $index]
			} elseif {[peek $p1] == 0x66} { ;# X=H
				set index [peek $p2]
				markdata [expr $ix + $index]
			} elseif {[peek $p1] == 0x6e} { ;# X=L
				set index [peek $p2]
				markdata [expr $ix + $index]
			} elseif {[peek $p1] == 0x2a} {
				set word [peek16 $p2]
				markdata $word
			} else { ;# op (IX+index)
				set index [peek $p2]
				markdata [expr $ix + $index]
			}
		}
		fd { ;# operation with IY somewhere
			if {[peek $p1] == 0xe9} { ;# JP (IY)
				markcode $iy
			} elseif {[peek $p1] == 0x7e} { ;# LD X,(IY + index)
				set index [peek $p2]
				markdata [expr $iy + $index]
			} elseif {[peek $p1] == 0x46} { ;# X=B
				set index [peek $p2]
				markdata [expr $iy + $index]
			} elseif {[peek $p1] == 0x4e} { ;# X=C
				set index [peek $p2]
				markdata [expr $iy + $index]
			} elseif {[peek $p1] == 0x56} { ;# X=D
				set index [peek $p2]
				markdata [expr $iy + $index]
			} elseif {[peek $p1] == 0x5e} { ;# X=E
				set index [peek $p2]
				markdata [expr $iy + $index]
			} elseif {[peek $p1] == 0x66} { ;# X=H
				set index [peek $p2]
				markdata [expr $iy + $index]
			} elseif {[peek $p1] == 0x6e} { ;# X=L
				set index [peek $p2]
				markdata [expr $iy + $index]
			} elseif {[peek $p1] == 0x2a} {
				set word [peek16 $p2]
				markdata $word
			} else { ;# op (IX+index)
				set index [peek $p2]
				markdata [expr $iy + $index]
			}
		}
	}
}

namespace export codeanalyzer

} ;# namespace codeanalyzer

namespace import codeanalyzer::*
