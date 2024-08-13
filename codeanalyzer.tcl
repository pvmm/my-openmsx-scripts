namespace eval codeanalyzer {

;# TODO:
;# * finish all z80 instructions;
;#   ** INI,IND,INIR,INDR,OUTI,OUTIR,OUTD,OUTDR
;#   ** explore conditional branches (specially when it falls through)
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
variable r_wp {}
variable w_wp {}
variable entry_point {}
# info
variable DATA_recs 0 ;# data records
variable CODE_recs 0 ;# code records
variable BOTH_recs 0 ;# both DATA and CODE records

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
		"dump" { return {Dump source code to a file.

Syntax: codeanalyzer dump <filename>
}}
		default { error "Unknown command \"[lindex $args 1]\"."
}
	}
}

proc codeanalyzer {args} {
	if {[env DEBUG] ne 0} {
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
		"dump"     { return [codeanalyzer_dump {*}$params] }
		default    { error "Unknown command \"[lindex $args 0]\"." }
	}
}

proc slot {} {
	variable slot
	if {![info exists slot]} {
		error "no slot defined"
	}
	return [lindex $slot 0]
}

proc subslot {{defaults {}}} {
	variable slot
	if {![info exists slot]} {
		error "no slot defined"
	}
	if {[lindex $slot 1] eq {}} {
		return $defaults
	}
	return [lindex $slot 1]
}

;# Get full address in {slotted memory} format: [slot][subslot][64kb addr]
proc fulladdr {addr} {
	variable slot
	if {![info exists slot]} {
		error "no slot defined"
	}
	return [expr ([slot] << 18) | ([subslot 0] << 16) | $addr]
}

proc reset_info {} {
	variable m_type ""
	variable m
	unset m
	variable entry_point ""
	variable DATA_recs 0
	variable CODE_recs 0
	variable BOTH_recs 0
}

proc codeanalyzer_start {args} {
	variable m_type
	variable pc {}
	variable entry_point
	variable cond
	variable r_wp
	variable w_wp

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
		set cond [debug set_condition "\[pc_in_slot $slot\]"        codeanalyzer::_check_mem]
		set r_wp [debug set_watchpoint read_mem  {0x0000 0xffff} "\[pc_in_slot $slot\]" codeanalyzer::_read_mem ]
		set w_wp [debug set_watchpoint write_mem {0x0000 0xffff} "\[pc_in_slot $slot\]" codeanalyzer::_write_mem]
	} else {
		puts "Nothing to start."
	}

	return ;# no output
}

proc codeanalyzer_stop {} {
	variable cond
	variable r_wp
	variable w_wp

	if {$cond ne ""} {
		puts "Codeanalyzer stopped."
		debug remove_condition $cond
		set cond ""
		set r_wp ""
		set w_wp ""
	} else {
		puts "Nothing to stop."
	}
}

proc _scanmemtype {} {
	variable m_type
	set addr [fulladdr [reg PC]]
	set byte [peek $addr {slotted memory}]
	poke $addr [expr $byte ^ 1] {slotted memory}
	if {[peek $addr {slotted memory}] eq $byte} {
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
	foreach offset [list 0x4000 0x8000 0x0000] { ;# memory search order
		set addr [fulladdr $offset]
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
	variable DATA_recs
	variable CODE_recs
	variable BOTH_recs
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
	puts "number of DATA records: $DATA_recs"
	puts "number of CODE records: $CODE_recs"
	puts "number of BOTH records: $BOTH_recs"

	puts -nonewline "codeanalyzer "
	if {$cond ne ""} {
		puts "still running"
	} else {
		puts "stopped"
	}
}

proc log {s} {
	if {[env DEBUG] ne 0} {
		puts stderr $s
		puts $s
	}
}

proc env {varname {defaults {}}} {
	if {[info exists ::env($varname)]} {
		return $::env($varname);
	}
	return $defaults;
}

proc mark_DATA {addr} {
	variable m
	variable slot
	variable DATA_recs
	variable CODE_recs
	variable BOTH_recs

	set addr [fulladdr $addr]
	set type [array get m $addr]
	log "D) type = $type, addr = [format %06x $addr]"
	if {$type eq [NAUGHT]} {
		set m($addr) [DATA]
		if {[env LOGLEVEL] eq 1} {
			log "marking [format %04x [expr $addr & 0xffff]] as DATA"
		}
		incr DATA_recs
	} elseif {$m($addr) eq [CODE]} {
		log "warning: overwritting address type in [format %04x [expr $addr & 0xffff]] from CODE to BOTH"
		set m($addr) [BOTH]
		incr CODE_recs -1
		incr BOTH_recs
	}
}

proc mark_DATA_v {first args} {
	;# v is for variable args
	mark_DATA $first
	foreach addr $args { mark_DATA $addr }
}

proc mark_JP_c {index} {
	;# c is for conditional jump
	;# mark all possible paths (branch or not)
	mark_CODE [expr [reg PC] + $index]
	mark_CODE [expr [reg PC] + 2]
}

proc mark_CALL {addr} {
	;# mark all possible paths (branch and return)
	mark_CODE $addr
	mark_CODE [expr [reg PC] + 2]
}

proc mark_CODE {addr} {
	variable m
	variable DATA_recs
	variable CODE_recs
	variable BOTH_recs

	set type [array get m $addr]
	set addr [fulladdr $addr]
	log "C) type = $type, addr = [format %06x $addr]"
	if {$type eq [NAUGHT]} {
		set m($addr) [CODE]
		if {[env LOGLEVEL] eq 1} {
			log "marking [format %04x [expr $addr & 0xffff]] as CODE"
		}
		incr CODE_recs
	} elseif {$m($addr) eq [DATA]} {
		log "warning: overwritting address type in [format %04x [expr $addr & 0xffff]] from DATA to BOTH"
		set m($addr) [BOTH]
		incr DATA_recs -1
		incr BOTH_recs
	}
}

proc _read_mem {} {
	set a [fulladdr $::wp_last_address]
	log "R) a = $a"
	mark_DATA [fulladdr $::wp_last_address]
}

proc _write_mem {} {
	set a [fulladdr $::wp_last_address]
	set b [$::wp_last_value]
	log "W) ab = $a, $b"
	mark_DATA [fulladdr $::wp_last_address]
}

proc _check_mem {} {
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

	;# mark PC address as CODE
	mark_CODE $pc

	;# mark instruction parameter as CODE
	switch -- [format %x [peek $pc]] {
		10 {
			;# djnz index
			mark_JP_c [peek $p1]
		}
		18 {
			;# jr index
			;# just one possible path
			set a 0
		}
		20 {
			;# jr nz, index
			mark_JP_c [peek $p1]
		}
		28 {
			;# jr z, index
			mark_JP_c [peek $p1]
		}
		30 {
			;# jr nc, index
			mark_JP_c [peek $p1]
		}
		38 {
			;# jr c, index
			mark_JP_c [peek $p1]
		}
		c4 {
			;# call nz, address 
			mark_CALL [peek16 $p1]
		}
		cc {
			;# call z, address 
			mark_CALL [peek16 $p1]
		}
		cd {
			;# call address 
			mark_CALL [peek16 $p1]
		}
		d4 {
			;# call nc, address
			mark_CALL [peek16 $p1]
		}
		dc {
			;# call c, address
			mark_CALL [peek16 $p1]
		}
		e4 {
			;# call po, address
			mark_CALL [peek16 $p1]
		}
		e9 {
			;# jp (hl)
			;# just one possible path
			set a 0
		}
		ec {
			;# call pe, address
			mark_CALL [peek16 $p1]
		}
		f4 {
			;# call p, address
			mark_CALL [peek16 $p1]
		}
		fc {
			;# call m, address
			mark_CALL [peek16 $p1]
		}
	}
}

proc codeanalyzer_dump {{filename "./source.asm"}} {
	variable m
	set source_file [open $filename {WRONLY TRUNC CREAT}]
	;#set type [array get m $addr]
	set size 1
	for {set offset 0x0000} {$offset < 0xffff} {incr offset $size} {
		set addr [fulladdr $offset]
		if {[array get m $addr]} {
			m($addr)
		} else {
			disasm $addr
		}
	}
	foreach {addr type} [array get m] {
		puts "[format %06x $addr] - $type"
	}
	;#puts $source_file [binary format c16 $header]
}

namespace export codeanalyzer

} ;# namespace codeanalyzer

namespace import codeanalyzer::*
