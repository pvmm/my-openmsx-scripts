namespace eval codeanalyzer {

;# TODO:
;# * finish all z80 instructions;
;#   ** INI,IND,INIR,INDR,OUTI,OUTIR,OUTD,OUTDR
;#   ** explore conditional branches (specially when they fall through)
;# * BIOS support;
;# * detect segment type and usage when executing code or reading/writing data;
;# * detect code copying to RAM and include it in the analysis;
;# * detect code size using disassembler;
;# * write assembly output to file;
;# * annotate unscanned code/data when writing output file;
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

variable mem_type ""
variable t ;# memory type array
variable l ;# instruction length array
variable pc
variable slot
variable segment
variable ss ""
variable cond {}
variable r_wp {}
variable w_wp {}
variable entry_point {}

# bookkeeping
variable oldpc {}
variable inslen 0
variable last_mem_read {}

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
Recognized commands: start, stop, info, pixel
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

;# Get complete address in {slotted memory} format: [slot][subslot][64kb addr]
proc _compaddr {addr} {
	variable slot
	if {![info exists slot]} {
		error "no slot defined"
	}
	return [expr ([slot] << 18) | ([subslot 0] << 16) | $addr]
}

proc _get_selected_slot {page} {
        set ps_reg [debug read "ioports" 0xA8]
        set ps [expr {($ps_reg >> (2 * $page)) & 0x03}]
        if {[machine_info "issubslotted" $ps]} {
                set ss_reg [debug read "slotted memory" [expr {0x40000 * $ps + 0xFFFF}]]
                set ss [expr {(($ss_reg ^ 255) >> (2 * $page)) & 0x03}]
        } else {
                set ss 0
        }
        list $ps $ss
}

;# Get full address as used in {slotted memory} format: [slot][subslot][64KB addr]
proc _fulladdr {addr} {
	set curslot [_get_selected_slot [expr $addr >> 14]]
	return [expr ([lindex $curslot 0] << 18) | ([lindex $curslot 1] << 16) | $addr]
}

proc reset_info {} {
	variable mem_type ""
	variable m
	unset m
	variable entry_point ""
	variable DATA_recs 0
	variable CODE_recs 0
	variable BOTH_recs 0
}

proc codeanalyzer_start {args} {
	variable mem_type
	variable pc {}
	variable entry_point
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
	;# set breakpoints according to slot and subslot
	if {$r_wp eq ""} {
		puts "codeanalyzer started"
		if {$entry_point eq ""} {
			codeanalyzer_scancart
		}
		set r_wp [debug set_watchpoint read_mem  {0x0000 0xffff} "\[pc_in_slot $slot\]" codeanalyzer::_read_mem ]
		set w_wp [debug set_watchpoint write_mem {0x0000 0xffff} "\[pc_in_slot $slot\]" codeanalyzer::_write_mem]
	} else {
		puts "Nothing to start."
	}

	return ;# no output
}

proc codeanalyzer_stop {} {
	variable r_wp
	variable w_wp
	if {$r_wp ne ""} {
		puts "Codeanalyzer stopped."
		debug remove_watchpoint $r_wp
		debug remove_watchpoint $w_wp
		set r_wp ""
		set w_wp ""
	} else {
		puts "Nothing to stop."
	}
}

proc _scanmemtype {} {
	variable mem_type
	set addr [_compaddr [reg PC]]
	set byte [peek $addr {slotted memory}]
	poke $addr [expr $byte ^ 1] {slotted memory}
	if {[peek $addr {slotted memory}] eq $byte} {
		set mem_type ROM
	} else {
		set mem_type RAM
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
	variable mem_type
	variable ss
	variable slot
	variable entry_point
	foreach offset [list 0x4000 0x8000 0x0000] { ;# memory search order
		set addr [_compaddr $offset]
		set tmp [peek16 $addr {slotted memory}]
		set prefix [format %c%c [expr $tmp & 0xff] [expr $tmp >> 8]]
		if {$prefix eq "AB"} {
			set mem_type ROM
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

	variable mem_type
	variable entry_point
	variable DATA_recs
	variable CODE_recs
	variable BOTH_recs
	variable r_wp

	puts "running on slot $ss"
	puts -nonewline "memory type: "
	if {$mem_type ne ""} {
		puts $mem_type
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
	if {$r_wp ne ""} {
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
	variable t
	variable DATA_recs
	variable CODE_recs
	variable BOTH_recs

	set addr [_compaddr $addr]
	set type [array get t $addr]
	if {$type eq [NAUGHT]} {
		set t($addr) [DATA]
		if {[env LOGLEVEL] eq 1} {
			log "marking [format %04x [expr $addr & 0xffff]] as DATA"
		}
		incr DATA_recs
	} elseif {$t($addr) eq [CODE]} {
		log "warning: overwritting address type in [format %04x [expr $addr & 0xffff]] from CODE to BOTH"
		set t($addr) [BOTH]
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
	variable t
	variable DATA_recs
	variable CODE_recs
	variable BOTH_recs

	set addr [_compaddr $addr]
	set type [array get t $addr]
	if {$type eq [NAUGHT]} {
		set t($addr) [CODE]
		if {[env LOGLEVEL] eq 1} {
			log "marking [format %04x [expr $addr & 0xffff]] as CODE"
		}
		incr CODE_recs
	} elseif {$t($addr) eq [DATA]} {
		log "warning: overwritting address type in [format %04x [expr $addr & 0xffff]] from DATA to BOTH"
		set t($addr) [BOTH]
		incr DATA_recs -1
		incr BOTH_recs
	}
}

proc _read_mem {} {
        variable oldpc
        variable inslen
	variable last_mem_read

        if {$oldpc eq [reg PC]} {
        	;# if same instruction, count its length
		if {[expr $oldpc + $inslen] eq $::wp_last_address} {
			mark_CODE [_fulladdr [expr [reg PC] + $inslen]]
		} else {
			set last_mem_read $::wp_last_address
		}
                incr inslen
        } else {
		;# last memory operation on oldpc is the actual read
		if {$last_mem_read ne {}} {
			mark_DATA [_fulladdr $last_mem_read]
			set last_mem_read {}
			;#checkop $oldpc
		}
                ;# start new instruction
                mark_CODE [reg PC]
                set oldpc [reg PC]
		set inslen 1
	}
}

proc _write_mem {} {
	mark_DATA [_fulladdr $::wp_last_address]
}

proc _check_mem {} {
	log "_check_mem called at PC=[format %04x [reg PC]]"
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

proc disasm {source_file addr blob} {
	while {[string length $blob] > 0} {
		set tmp  [debug disasm_blob $blob $addr]
		set blob [string range $blob [lindex $tmp 1] end]
		puts $source_file "[format %04x $addr] [lindex $tmp 0]"
		incr addr [lindex $tmp 1]
	}
}

proc dump_blob {source_file start_addr blob} {
	if {$blob ne ""} {
		disasm $source_file $start_addr $blob
	}
	return ""
}

proc codeanalyzer_dump {{filename "./source.asm"}} {
	variable t
	variable entry_point
	set source_file [open $filename {WRONLY TRUNC CREAT}]
	set blob ""
	set start_addr ""

	for {set offset $entry_point} {$offset < [expr $entry_point + 0x20]} {incr offset} {
		set addr [_compaddr $offset]
		if {[array get t $addr] ne {}} {
			set type $t($addr)
			if {$type eq [CODE]} {
				if {$blob eq ""} {
					set start_addr $offset
				}
				append blob [format %c [peek $addr {slotted memory}]]
			} else {
				;# end of blob
				set blob [dump_blob $source_file $start_addr $blob]
				puts -nonewline $source_file "[format %04x $offset] "
				puts $source_file "db #[format %02x [peek $addr {slotted memory}]]"
			}
		} else {
			set blob [dump_blob $source_file $start_addr $blob]
			append blob [format %c [peek $addr {slotted memory}]]
		}
	}
	dump_blob $source_file $start_addr $blob
	close $source_file
}

namespace export codeanalyzer

} ;# namespace codeanalyzer

namespace import codeanalyzer::*
