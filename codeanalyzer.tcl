namespace eval codeanalyzer {

;# TODO:
;# * finish all z80 instructions;
;#   ** INI,IND,INIR,INDR,OUTI,OUTIR,OUTD,OUTDR
;#   ** explore conditional branches (specially when the PC goes the other way)
;# * BIOS support;
;# * detect ROM size (16k, 32k or MEGAROM);
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
variable l ;# label array
variable c ;# comment array
variable pc
variable slot
variable segment
variable ss ""
variable is_mapper 0
variable cond {}
variable r_wp {}
variable w_wp {}
variable entry_point {}
variable end_point 0xBFFF ;# end of page 2
variable comment "" ;# stored comment message
variable rr 0 ;# Real Read
variable labelsize 14

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
		"stop" { return {Stop script that analyzes code.

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
		"comment" { return {Comment on running code.

Syntax: codeanalyzer comment -data

Comment on the code as the program counter runs through it.
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
		"comment"  { return [codeanalyzer_comment {*}$params] }
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
proc _compladdr {addr} {
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
	variable is_mapper

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
	set is_mapper [expr [get_mapper_size {*}[lrange [expr "{$slot 0}"] 0 2]] != 0]
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

proc _scancart {} {
	variable mem_type
	variable ss
	variable slot
	variable entry_point
	foreach offset [list 0x4000 0x8000 0x0000] { ;# memory search order
		set addr [_compladdr $offset]
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

proc codeanalyzer_info {} {
	variable ss
	if {$ss eq ""} {
		error "codeanalyzer was never executed."
	}

	variable mem_type
	variable is_mapper
	variable entry_point
	variable DATA_recs
	variable CODE_recs
	variable BOTH_recs
	variable r_wp

	puts "running on slot $ss"
	puts "mapper detection: [expr $is_mapper == 0 ? no : yes]"
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

proc tag_DATA {addr} {
	variable t
	variable DATA_recs
	variable CODE_recs
	variable BOTH_recs

	set addr [_compladdr $addr]
	set type [array get t $addr]
	if {$type eq [NAUGHT]} {
		set t($addr) [DATA]
		if {[env LOGLEVEL] eq 1} {
			log "tagging [format %04x [expr $addr & 0xffff]] as DATA"
		}
		incr DATA_recs
	} elseif {$t($addr) eq [CODE]} {
		log "warning: overwritting address type in [format %04x [expr $addr & 0xffff]] from CODE to BOTH"
		set t($addr) [BOTH]
		incr CODE_recs -1
		incr BOTH_recs
	}
}

proc tag_DATA_v {first args} {
	;# v is for variable args
	tag_DATA $first
	foreach addr $args { tag_DATA $addr }
}

proc tag_JP_c {index} {
	;# c is for conditional jump
	;# tag all possible paths (branch or not)
	tag_CODE [expr [reg PC] + $index]
	tag_CODE [expr [reg PC] + 2]
}

proc tag_CALL {addr} {
	;# tag all possible paths (branch and return)
	tag_CODE $addr
	tag_CODE [expr [reg PC] + 2]
}

proc tag_CODE {addr} {
	variable t
	variable l
	variable comment
	variable DATA_recs
	variable CODE_recs
	variable BOTH_recs

	set addr [_compladdr $addr]
	set type [array get t $addr]
	if {$type eq [NAUGHT]} {
		if {[env LOGLEVEL] eq 1} {
			log "tagging [format %04x [expr $addr & 0xffff]] as CODE"
		}
		set t($addr) [CODE]
		incr CODE_recs
	} elseif {$t($addr) eq [DATA]} {
		log "warning: overwritting address type in [format %04x [expr $addr & 0xffff]] from DATA to BOTH"
		set t($addr) [BOTH]
		incr DATA_recs -1
		incr BOTH_recs
	}
}

proc tag_CMT {addr comment} {
}

proc labelfy {addr} {
	return "L_[format %04X [expr $addr & 0xffff]]"
}

proc tag_address {addr} {
	variable l
	set tmp [array get l $addr]
	if {[llength $tmp] eq 0} {
		# look for symbol in symbol table
		set syms [debug symbols lookup -value [expr 0xffff & $addr]]
		if {[llength $syms] > 0} {
			set sym [lindex $syms 0]
			set name [lindex $sym 3]
			log "found symbol $name in [format %06x $addr]"
			set l($addr) $name
		} elseif {$tmp eq [NAUGHT]} {
			set name [labelfy $addr]
			set l($addr) $name
		}
	}
}

proc _read_mem {} {
        variable oldpc
        variable inslen
	variable last_mem_read
	variable comment
	variable rr

	set fullpc [_fulladdr [reg PC]]
        if {$oldpc eq [reg PC]} {
		tag_CMT $fullpc $comment
		if {$::wp_last_address eq [expr $last_mem_read + 1]} {
			tag_CODE [_fulladdr $::wp_last_address]
			set rr 0
		} elseif {$::wp_last_address ne [expr [reg PC]]} {
			# void infinite loop to PC
			tag_DATA [_fulladdr $::wp_last_address]
			set rr 1
		}
	} else {
                # start new instruction
                tag_CODE [_fulladdr [reg PC]]
		# detect branch and set label
		if {$::wp_last_address ne [expr $last_mem_read + 1] && $rr eq 0} {
			tag_address $fullpc
		}
	}
	set oldpc [reg PC]
	set last_mem_read $::wp_last_address
}

proc _write_mem {} {
	tag_DATA [_fulladdr $::wp_last_address]
}

proc label_fmt {label} {
	variable labelsize
	if {$label ne ""} { set label "$label:" }
	set size [expr $labelsize - [string len $label]]
	if {$size > 0} {
		return $label[string repeat " " $size]
	}
	return "$label\n[string repeat " " $labelsize]"
}

proc disasm_fmt {label asm comment} {
	if {$comment eq ""} {
		set suffix $asm
	} else {
		set suffix "[format %20s $asm] ; $comment"
	}
	return [label_fmt $label]$suffix
}

proc lookup {addr} {
	variable l
	set tmp [array get l $addr]
	if {[llength $tmp] ne 0} {
		return [lindex $tmp 1]
	}
	return ""
}

proc disasm {source_file addr blob {byte {}}} {
	variable l
	variable c

	while {[string length $blob] > 0} {
		if {$byte eq {}} {
			set asm [debug disasm_blob $blob $addr lookup]
		} else {
			set asm [list "db     #[format %02x $byte]" 1]
		}
		set blob [string range $blob [lindex $asm 1] end]
		set lbl  [array get l $addr]
		set cmt  [array get c $addr]

		if {$lbl ne {}} { set lbl $l($addr) }
		if {$cmt ne {}} { set cmt $c($addr) }
		puts $source_file [disasm_fmt $lbl [lindex $asm 0] $cmt]
		incr addr [lindex $asm 1]
	}
}

proc dump_mem {source_file addr} {
	disasm $source_file $addr "\0" [peek $addr {slotted memory}]
}

proc dump_blob {source_file start_addr blob} {
	if {$blob ne ""} {
		disasm $source_file $start_addr $blob
	}
	return ""
}

proc codeanalyzer_comment {message} {
	puts "comment called with comment \"$message\"."
	variable comment
	set comment $message
}

proc codeanalyzer_dump {{filename "./source.asm"}} {
	variable t
	variable entry_point
	variable end_point
	set source_file [open $filename {WRONLY TRUNC CREAT}]
	set blob ""
	set start_addr ""

	for {set offset $entry_point} {$offset < $end_point} {incr offset} {
		set addr [_compladdr $offset]
		if {[array get t $addr] ne {}} {
			set type $t($addr)
			if {$type eq [CODE]} {
				if {$blob eq ""} {
					set start_addr $addr
				}
				append blob [format %c [peek $addr {slotted memory}]]
			} else {
				# end of blob
				dump_blob $source_file $start_addr $blob
				dump_mem $source_file $addr
				set blob ""
			}
		} else {
			dump_blob $source_file $start_addr $blob
			dump_mem $source_file $addr
			set blob ""
		}
	}
	if {$blob ne ""} {
		dump_blob $source_file $start_addr $blob
	}
	close $source_file
}

namespace export codeanalyzer

} ;# namespace codeanalyzer

namespace import codeanalyzer::*
