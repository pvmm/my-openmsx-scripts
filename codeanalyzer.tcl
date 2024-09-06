namespace eval codeanalyzer {

# TODO:
# * finish all z80 instructions;
#   ** INI,IND,INIR,INDR,OUTI,OUTIR,OUTD,OUTDR
#   ** explore conditional branches (specially when the PC goes the other way)
# * BIOS support;
# * detect ROM size (16k, 32k or MEGAROM);
# * detect segment type (ROM or memory mapper) and usage when executing code or reading/writing data;
# * detect code copying to RAM and include it in the analysis;
# * detect instructon size using disassembler;
# * write assembly output to file;
# * annotate unscanned code/data when writing output file;
# * allow user to set markers on the code;
# * try to detect functions;
#   * detect call/ret combinations;
# * try to detect all types of RAM-to-VRAM memory copying:
#   * pattern generator table (PGT)
#   * name table;
#   * colour table;
#   * sprite generator table;
#   * sprite attribute table;
# * try to detect keyboard input;
# * try to detect joystick port input;
# * try to detect sound generation (PSG);

variable mem_type ""

variable t ;# memory type array
variable l ;# label array
variable c ;# comment array
variable x ;# extended address
variable pc
variable tmp_pc {}
variable slot
variable segment
variable ss ""
variable is_mapper 0
variable cond {}
variable r_wp {}
variable w_wp {}
variable start_point {}
variable entry_point {}
variable end_point 0xBFFF ;# end of page 2
variable comment "" ;# stored comment message
variable _rr 0 ;# (R)eal (R)ead
variable label_size 14

# bookkeeping
variable oldpc {}
variable inslen 0
variable last_mem_read {}

# info
variable DATA_recs 0 ;# data records
variable CODE_recs 0 ;# code records
variable BOTH_recs 0 ;# both DATA and CODE records

# constants
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
		"labelsize" { return {Return current label length or change its value. Default value: 14

Syntax: codeanalyzer labelsize [<value>]

Comment on the code as the program counter runs through it.
}}
		default { error "Unknown command \"[lindex $args 1]\"."
}
	}
}

proc codeanalyzer_dispatch {args} {
	set params "[lrange $args 1 end]"
	switch -- [lindex $args 0] {
		"start"     { return [codeanalyzer_start {*}$params] }
		"stop"      { return [codeanalyzer_stop {*}$params] }
		"info"      { return [codeanalyzer_info {*}$params] }
		"comment"   { return [codeanalyzer_comment {*}$params] }
		"dump"      { return [codeanalyzer_dump {*}$params] }
		"labelsize" { return [codeanalyzer_labelsize {*}$params] }
		default     { error "Unknown command \"[lindex $args 0]\"." }
	}
}

proc codeanalyzer {args} {
	if {[env DEBUG] ne 0} {
		if {[catch {codeanalyzer_dispatch {*}$args} fid]} {
			debug break 
			puts stderr $::errorInfo
			error $::errorInfo
		}
	} else {
		codeanalyzer_dispatch {*}$args
	}
	return
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

# Get complete address in {slotted memory} format: [slot][subslot][64kb addr]
proc get_slotaddr {addr} {
	variable slot
	if {![info exists slot]} {
		error "no slot defined"
	}
	if {![llength slot] > 1} {
		return [expr ([slot] << 18) | ([subslot] << 16) | $addr]
	}
	return [expr ([slot] << 18) | $addr]
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

proc calc_addr {slot subslot addr} {
	if {[env DEBUG] ne 0 && ($slot eq {} || $subslot eq {} || $addr eq {})} { error "parameters missing" }
	return [expr ($slot << 18) | ($subslot << 16) | $addr]
}

# Get current address as used in {slotted memory} format: [current slot][current subslot][64KB addr]
proc get_curraddr {addr} {
	if {[env DEBUG] ne 0 && $addr eq {}} { error "address missing" }
	return [calc_addr {*}[list {*}[_get_selected_slot [expr $addr >> 14]] $addr]]
}

proc reset_info {} {
	variable mem_type ""
	variable m
	unset m
	variable start_point {}
	variable entry_point {}
	variable DATA_recs 0
	variable CODE_recs 0
	variable BOTH_recs 0
}

proc codeanalyzer_start {args} {
	variable mem_type
	variable pc {}
	variable start_point
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
		load_bios
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
	variable start_point
	variable entry_point
	foreach offset [list 0x4000 0x8000 0x0000] { ;# memory search order
		set addr [get_slotaddr $offset]
		set tmp [peek16 $addr {slotted memory}]
		set prefix [format %c%c [expr $tmp & 0xff] [expr $tmp >> 8]]
		if {$prefix eq "AB"} {
			set mem_type ROM
			puts "prefix found at $ss:[format %04x [expr $addr & 0xffff]]"
			set start_point $offset
			set entry_point [peek16 [expr $addr + 2] {slotted memory}]
			puts "start point found at [format %04x $start_point]"
			puts "entry point found at [format %04x $entry_point]"
		}
	}
	if {$start_point eq ""} {
		puts "no cartridge signature found"
		set start_point ""
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
	variable start_point
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
	puts -nonewline "start point: "
	if {$start_point ne {}} {
		puts [format %04x $start_point]
	} else {
		puts "undefined"
	}
	puts -nonewline "entry point: "
	if {$entry_point ne {}} {
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

proc tag_DATA {fulladdr} {
	variable t
	variable DATA_recs
	variable CODE_recs
	variable BOTH_recs

	set type [array get t $fulladdr]
	if {$type eq [NAUGHT]} {
		set t($fulladdr) [DATA]
		if {[env LOGLEVEL] eq 1} {
			log "tagging [format %04x $fulladdr] as DATA"
		}
		incr DATA_recs
	} elseif {$t($fulladdr) eq [CODE]} {
		log "warning: overwritting address type in [format %04x $fulladdr] from CODE to BOTH"
		set t($fulladdr) [BOTH]
		incr CODE_recs -1
		incr BOTH_recs
	}
}

proc tag_CODE {fulladdr} {
	variable t
	variable l
	variable DATA_recs
	variable CODE_recs
	variable BOTH_recs

	set type [array get t $fulladdr]
	if {$type eq [NAUGHT]} {
		if {[env LOGLEVEL] eq 1} {
			log "tagging [format %04x $fulladdr] as CODE"
		}
		set t($fulladdr) [CODE]
		incr CODE_recs
	} elseif {$t($fulladdr) eq [DATA]} {
		log "warning: overwritting address type in [format %04x $fulladdr] from DATA to BOTH"
		set t($fulladdr) [BOTH]
		incr DATA_recs -1
		incr BOTH_recs
	}
}

proc comment {fulladdr comment} {
	variable c
	set curcmt [array get c $fulladdr]
	if {[llength $curcmt] eq 0} {
		set c($fulladdr) $comment
	} else {
		if {[string first $comment $c($fulladdr)] eq -1} {
			log "append comment at $curcmt: $comment"
			set c($fulladdr) "[lindex $curcmt 1], $comment"
		}
	}
}

proc labelfy {fulladdr} {
	return "L_[format %04X [expr $fulladdr & 0xffff]]"
}

# Find label for address or create a new one in the format "L_"<hex address>
proc tag_address {fulladdr {name {}}} {
	variable l
	if {$name ne {}} {
		set l($fulladdr) $name
		return
	}
	set lbl [array get l $fulladdr]
	if {[llength $lbl] eq 0} {
		# look for symbol in symbol table
		set syms [debug symbols lookup -value [expr 0xffff & $fulladdr]]
		if {[llength $syms] > 0} {
			set sym [lindex $syms 0]
			set name [lindex $sym 3]
			log "[format %04x $fulladdr]: found symbol $name"
			set l($fulladdr) $name
		} elseif {$lbl eq [NAUGHT]} {
			set name [labelfy $fulladdr]
			log "[format %04x $fulladdr]: address tagged with new name $name."
			set l($fulladdr) $name
		}
	}
}

# tag PC with extra information on memory access
proc tag_extra {pc fulladdr} {
	variable x
	if {[array get x $pc] eq {}} {
		log "store slot and subslot for [format %04x $pc]: [format %04x $fulladdr]"
		set x($pc) $fulladdr
	}
}

# create label from lookup (uses global tmp_pc)
proc lookup_or_create {addr} {
	variable l
	variable tmp_pc
	if {[env DEBUG] ne 0 &&   $addr eq {}} { error "missing parameter addr" }
	if {[env DEBUG] ne 0 && $tmp_pc eq {}} { error "missing parameter tmp_pc" }

	set fulladdr [get_curraddr $addr]
	set lbl [array get l $fulladdr]
	if {[llength $lbl] eq 0} {
		tag_address $fulladdr
		tag_extra $tmp_pc $fulladdr
		return $l($fulladdr)
	}
	tag_extra $tmp_pc $fulladdr
	return [lindex $lbl 1]
}

proc _disasm {blob fulladdr lookup} {
	variable tmp_pc
	set tmp_pc $fulladdr
	if {[catch {set result [debug disasm_blob $blob $fulladdr $lookup]} fid]} {
		comment $fulladdr "warning: invalid Z80 code detected"
		set result "db     "
		for {set i 0} {$i < [string length $blob]} {incr i} {
			append result "#[format %02x [scan [string index $blob $i] %c]],"
		}
		set result [list [string trimright $result ,] 4]
	}
	return $result
}

proc disasm_blob {fulladdr lookup} {
	if {[env DEBUG] ne 0 && $fulladdr eq {}} { error "missing parameter fulladdr" }
	set blob ""
	append blob [format %c [peek $fulladdr {slotted memory}]]
	append blob [format %c [peek [expr $fulladdr + 1] {slotted memory}]]
	append blob [format %c [peek [expr $fulladdr + 2] {slotted memory}]]
	append blob [format %c [peek [expr $fulladdr + 3] {slotted memory}]]
	return [_disasm $blob $fulladdr $lookup]
}

proc tag_decoded {fulladdr lookup} {
	set len [lindex [disasm_blob $fulladdr $lookup] 1]
	for {set i 0} {$i < $len} {incr i} {
		tag_CODE [expr $fulladdr + $i]
	}
}

# Detect functions, BIOS calls etc.
proc analyze_code {addr} {
	if {[env DEBUG] ne 0 && $addr eq {}} { error "missing parameter addr" }
	# store extended address
	# tag conditional branches as CODE
	if {[lsearch -exact [list 16 32 40 48 56 194 196 202 204 210 212 218 220 226 228 234 236 242 244 250 252] [peek $addr]] >= 0} {
		log "analyze_code started"
		set fulladdr [get_curraddr $addr]
		log "conditional branch detected at [format %04x $fulladdr]"
		set dest [get_curraddr [peek16 [expr $fulladdr + 1] {slotted memory}]]
		tag_extra $fulladdr $dest
		tag_address $dest
		tag_decoded $dest lookup
		set next [expr $fulladdr + 3]
		#tag_address $next
		tag_decoded $next lookup_or_create
		log "analyze_code done"
	}
}

# hex or "null"
proc xe {num {i 4}} {
	if {$num eq ""} {
		return "ø"
	}
	return [format "%0${i}x" $num]
}

proc _read_mem {} {
	variable t
	variable oldpc
	variable inslen
	variable last_mem_read
	variable _rr
	variable comment

	set fullpc [get_curraddr [reg PC]]
	#log "pc: [xe $oldpc] -> [xe $fullpc], read: [xe $::wp_last_address]"
	# process current instruction
	if {$oldpc eq [reg PC]} {
		# detect if ::wp_last_address is still reading instructions
		if {$::wp_last_address eq [expr $last_mem_read + 1]} {
			tag_CODE [get_curraddr $::wp_last_address]
			set _rr 0
		} elseif {$::wp_last_address ne [expr [reg PC]]} {
			set fulladdr [get_curraddr $::wp_last_address]
			tag_extra $fullpc $fulladdr
			tag_address $fulladdr
			tag_DATA $fulladdr
			# avoid PC infinite loop
			set _rr 1
		}
	} else {
		# analyze last instruction
		if {$oldpc ne {}} {
			analyze_code $oldpc
			# detect branch and set label
			if {$::wp_last_address ne {} && [expr abs($::wp_last_address - $oldpc)] >= 4} {
				set oldpc    [get_curraddr $oldpc]
				set fulladdr [get_curraddr $::wp_last_address]
				tag_extra $oldpc $fulladdr
				tag_address $fulladdr
			}
		}
		# start new instruction
		tag_CODE [get_curraddr [reg PC]]
		# put comment on new instruction if it exists
		if {$comment ne {}} { comment $fullpc $comment }
	}
	set oldpc [reg PC]
	set last_mem_read $::wp_last_address
}

proc _write_mem {} {
	tag_DATA [get_curraddr $::wp_last_address]
}

proc label_fmt {label} {
	variable label_size
	if {$label ne ""} { set label "$label:" }
	set size [expr $label_size - [string len $label]]
	if {$size > 0} {
		return $label[string repeat " " $size]
	}
	return "$label\n[string repeat " " $label_size]"
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
	variable x
	variable tmp_pc
	if {[env DEBUG] ne 0 && $tmp_pc eq {}} { error "missing parameter tmp_pc \[1\]" }

	log "\[1\] searching [format %04x $tmp_pc] [format %04x $addr]..."
	# search extended address information
	if {[array get x $tmp_pc] ne {}} {
		set addr $x($tmp_pc)
	}
	log "\[2\] searching [format %04x $addr]..."
	set lbl [array get l $addr]
	if {[llength $lbl] ne 0} {
		log "found @[format %04x $addr]: [lindex $lbl 1]"
		return [lindex $lbl 1]
	}
	return ""
}

proc disasm {source_file fulladdr blob {byte {}}} {
	variable l
	variable c
	variable comment

	while {[string length $blob] > 0} {
		if {$byte eq {}} {
			set asm [_disasm $blob $fulladdr lookup]
		} else {
			set asm [list "db     #[format %02x $byte]" 1]
		}
		set blob [string range $blob [lindex $asm 1] end]
		set lbl  [array get l $fulladdr]
		set cmt  [array get c $fulladdr]

		if {$lbl ne {}} { set lbl $l($fulladdr) }
		if {$cmt ne {}} { set cmt $c($fulladdr) }
		puts $source_file [disasm_fmt $lbl [lindex $asm 0] $cmt]
		incr fulladdr [lindex $asm 1]
	}
}

proc dump_mem {source_file fulladdr} {
	disasm $source_file $fulladdr "\0" [peek $fulladdr {slotted memory}]
}

proc dump_blob {source_file fulladdr blob} {
	if {$blob ne ""} {
		disasm $source_file $fulladdr $blob
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
	variable start_point
	variable entry_point
	variable end_point
	set source_file [open $filename {WRONLY TRUNC CREAT}]
	set blob ""
	set start_addr {}

	if {$start_point eq {}} {
		error "unknown program entry point"
	}
	tag_address [get_slotaddr $start_point] "START"
	tag_address [get_slotaddr $entry_point] "MAIN"
	for {set offset $start_point} {$offset < $end_point} {incr offset} {
		set addr [get_slotaddr $offset]
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

proc codeanalyzer_labelsize {{value {}}} {
	variable label_size
	if {$value eq {}} {
		return $label_size
	}
	set label_size $value
}

proc load_bios {} {
	variable l
	set l([calc_addr 0 0 0x0006]) vdp.dr
	set l([calc_addr 0 0 0x0007]) vdp.dw
	set l([calc_addr 0 0 0x0008]) SYNCHR
	set l([calc_addr 0 0 0x000c]) RDSLT
	set l([calc_addr 0 0 0x0010]) CHRGTR
	set l([calc_addr 0 0 0x0014]) WRSLT
	set l([calc_addr 0 0 0x0018]) OUTDO
	set l([calc_addr 0 0 0x001c]) CALSLT
	set l([calc_addr 0 0 0x0020]) DCOMPR
	set l([calc_addr 0 0 0x0024]) ENASLT
	set l([calc_addr 0 0 0x0024]) ENASLT
	set l([calc_addr 0 0 0x0028]) GETYPR
	set l([calc_addr 0 0 0x0030]) CALLF
	set l([calc_addr 0 0 0x0038]) KEYINT
	set l([calc_addr 0 0 0x003b]) INITIO
	set l([calc_addr 0 0 0x003e]) INIFNK
	set l([calc_addr 0 0 0x0041]) DISSCR
	set l([calc_addr 0 0 0x0044]) ENASCR
	set l([calc_addr 0 0 0x0047]) WRTVDP
	set l([calc_addr 0 0 0x004a]) RDVRM
	set l([calc_addr 0 0 0x004d]) WRTVRM
	set l([calc_addr 0 0 0x0050]) SETRD
	set l([calc_addr 0 0 0x0053]) SETWRT
	set l([calc_addr 0 0 0x0056]) FILVRM
	set l([calc_addr 0 0 0x0059]) LDIRMV
	set l([calc_addr 0 0 0x005c]) LDIRVM
	set l([calc_addr 0 0 0x005f]) CHGMOD
	set l([calc_addr 0 0 0x0062]) CHGCLR
	set l([calc_addr 0 0 0x0066]) NMI
	set l([calc_addr 0 0 0x0069]) CLRSPR
	set l([calc_addr 0 0 0x006c]) INITXT
	set l([calc_addr 0 0 0x006f]) INIT32
	set l([calc_addr 0 0 0x006f]) INIGRP
	set l([calc_addr 0 0 0x0075]) INIMLT
	set l([calc_addr 0 0 0x0078]) SETTXT
	set l([calc_addr 0 0 0x007b]) SETT32
	set l([calc_addr 0 0 0x007e]) SETGRP
	set l([calc_addr 0 0 0x0081]) SETMLT
	set l([calc_addr 0 0 0x0084]) CALPAT
	set l([calc_addr 0 0 0x0087]) CALATR
	set l([calc_addr 0 0 0x008a]) GSPSIZ
	set l([calc_addr 0 0 0x008d]) GSPPRT
	set l([calc_addr 0 0 0x0090]) GICINI
	set l([calc_addr 0 0 0x0093]) WRTPSG
	set l([calc_addr 0 0 0x0096]) RDPSG
	set l([calc_addr 0 0 0x0099]) STRTMS
	set l([calc_addr 0 0 0x009c]) CHSNS
	set l([calc_addr 0 0 0x009f]) CHGET
	set l([calc_addr 0 0 0x00a2]) CHPUT
	set l([calc_addr 0 0 0x00a5]) LPTOUT
	set l([calc_addr 0 0 0x00a8]) LPTSTT
	set l([calc_addr 0 0 0x00ab]) CNVCHR
	set l([calc_addr 0 0 0x00ae]) PINLIN
	set l([calc_addr 0 0 0x00b1]) INLIN
	set l([calc_addr 0 0 0x00b4]) QINLIN
	set l([calc_addr 0 0 0x00b7]) BREAKX
	set l([calc_addr 0 0 0x00ba]) ISCNTC
	set l([calc_addr 0 0 0x00bd]) CKCNTC
	set l([calc_addr 0 0 0x00c0]) BEEP
	set l([calc_addr 0 0 0x00c3]) CLS
	set l([calc_addr 0 0 0x00c6]) POSIT
	set l([calc_addr 0 0 0x00c9]) FNKSB
	set l([calc_addr 0 0 0x00cc]) ERAFNK
	set l([calc_addr 0 0 0x00cf]) DSPFNK
	set l([calc_addr 0 0 0x00d2]) TOTEXT
	set l([calc_addr 0 0 0x00d5]) GTSTCK
	set l([calc_addr 0 0 0x00d8]) GTTRIG
	set l([calc_addr 0 0 0x00db]) GTPAD
	set l([calc_addr 0 0 0x00de]) GTPDL
	set l([calc_addr 0 0 0x00e1]) TAPION
	set l([calc_addr 0 0 0x00e4]) TAPIN
	set l([calc_addr 0 0 0x00e7]) TAPIOF
	set l([calc_addr 0 0 0x00ea]) TAPOON
	set l([calc_addr 0 0 0x00ed]) TAPOUT
	set l([calc_addr 0 0 0x00f0]) TAPOOF
	set l([calc_addr 0 0 0x00f3]) STMOTR
	set l([calc_addr 0 0 0x00f6]) LFTQ
	set l([calc_addr 0 0 0x00f9]) PUTQ
	set l([calc_addr 0 0 0x00fc]) RIGHTC
	set l([calc_addr 0 0 0x00ff]) LEFTC
	set l([calc_addr 0 0 0x0102]) UPC
	set l([calc_addr 0 0 0x0105]) TUPC
	set l([calc_addr 0 0 0x0108]) DOWNC
	set l([calc_addr 0 0 0x010b]) TDOWNC
	set l([calc_addr 0 0 0x010e]) SCALXY
	set l([calc_addr 0 0 0x0111]) MAPXY
	set l([calc_addr 0 0 0x0114]) FETCH
	set l([calc_addr 0 0 0x0117]) STOREC
	set l([calc_addr 0 0 0x011a]) SETATR
	set l([calc_addr 0 0 0x011d]) READC
	set l([calc_addr 0 0 0x0120]) SETC
	set l([calc_addr 0 0 0x0123]) NSETCX
	set l([calc_addr 0 0 0x0126]) GTASPC
	set l([calc_addr 0 0 0x0129]) PNTINI
	set l([calc_addr 0 0 0x012c]) SCANR
	set l([calc_addr 0 0 0x012f]) SCANL
	set l([calc_addr 0 0 0x0132]) CHGCAP
	set l([calc_addr 0 0 0x0135]) CHGSND
	set l([calc_addr 0 0 0x0138]) RSLREG
	set l([calc_addr 0 0 0x013b]) WSLREG
	set l([calc_addr 0 0 0x013e]) RDVDP
	set l([calc_addr 0 0 0x0141]) SNSMAT
	set l([calc_addr 0 0 0x0144]) PHYDIO
	set l([calc_addr 0 0 0x0147]) FORMAT
	set l([calc_addr 0 0 0x014a]) ISFLIO
	set l([calc_addr 0 0 0x014d]) OUTDLP
	set l([calc_addr 0 0 0x0150]) GETVCP
	set l([calc_addr 0 0 0x0153]) GETVC2
	set l([calc_addr 0 0 0x0156]) KILBUF
	set l([calc_addr 0 0 0x0159]) CALBAS
}

namespace export codeanalyzer

} ;# namespace codeanalyzer

namespace import codeanalyzer::*
