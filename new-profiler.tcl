# new-profiler.tcl has been replaced by _profilter.tcl inside the OpenMSX scripts folder.
# This code is for reuse and historical purposes only.
# TODO:
# (*) fix VDP command checking

variable tick_status 0
variable f_entries {}     ;# function entry points
variable f_returns {}     ;# function return points
variable f_beginnings {}  ;# funtion starting time
variable f_endings {}     ;# function returning time
variable v_beginnings {}  ;# vdp command starting time
variable v_endings {}     ;# vdp command ending time
variable vdpcmd_id 0
variable probe_bp {}
variable width 32
variable height 8
variable frame_begin 0
variable frame_end 0
variable flag_percent 1

proc DEBUG {} { return 1 }

proc _debug {text} {
	if {[DEBUG] eq 1} {
		puts stderr $text
	}
}

proc h {number} {
	if {$number eq {}} { return "null" }
	return [format %04x $number]
}

proc _enter_function {symbol} {
	#_debug "$symbol function called"
	# find function caller
	set caller [peek16 [reg SP]]
	# create caller's breakpoint
	variable f_returns
	dict set f_returns $caller [debug breakpoint create -once true -address 0x[h $caller] -command [list _exit_function $symbol]]
	# register time at the beginning of function
	variable f_beginnings
	dict set f_beginnings $symbol [machine_info time]
}

proc _exit_function {symbol} {
	#_debug "returned from $symbol function"
	variable f_beginnings
	if {![dict exists $f_beginnings $symbol]} {
		return
	}
	set begin [dict get $f_beginnings $symbol]
	dict unset f_beginnings $symbol

	set total [expr {[machine_info time] - $begin}]
	variable f_endings
	if {[dict exists $f_endings $symbol]} {
		dict set f_endings $symbol [expr {[dict get $f_endings $symbol] + $total}]
	} else {
		dict set f_endings $symbol $total
	}
}

proc _vdpcmd_start {} {
	variable vdpcmd_id
	#_debug "start vdpcmd_start #$vdpcmd_id"
	variable frame_begin
	variable frame_end
	variable v_beginnings
	set now [machine_info time]
	# get screen status when VDP is busy
	set status [expr {([debug read {VDP regs} 1] & 0x40) == 0 ? "(disabled)" : ($now > $frame_end ? "(vblank)" : "")}]
	dict set v_beginnings $vdpcmd_id [dict create begin $now status $status]
}

proc _vdpcmd_stop {} {
	#_debug "start vdpcmd_stop"
	set now [machine_info time]
	variable v_beginnings
	variable v_endings
	variable vdpcmd_id
	# error that happens when profiler is started between VDP command start and finish
	if {![dict exists $v_beginnings $vdpcmd_id]} { return }
	# update v_endings from v_beginnings
	dict with v_beginnings $vdpcmd_id {
		dict set v_endings $vdpcmd_id [dict create begin $begin end $now total [expr {$now - $begin}] status $status]
	}
	dict unset v_beginnings $vdpcmd_id
	#_debug "end vdpcmd_stop"
	incr vdpcmd_id
}

proc _tick {} {
	variable tick_status
	variable frame_begin
	variable frame_end
	if {$tick_status == 0} {
		set frame_begin [machine_info time]
		set frame_end 0
		set tick_status 1
	} else {
		set frame_end [machine_info time]
		_tick_stop
		set frame_begin $frame_end
		set frame_end 0
		set tick_status 0
	}
}

proc _tick_stop {} {
	variable frame_begin
	variable frame_end
	variable flag_percent
	set frame_len [expr {$frame_end - $frame_begin}]

	# display functions that haven't finished
	variable f_beginnings
	foreach {symbol begin} $f_beginnings {
		set time [expr {$begin * 1000}]
		_debug "$symbol (unfinished) started at [format %.2f $time] miliseconds"
	}
	#set f_beginnings {}

	# display functions that have finished
	variable f_endings
	foreach {symbol total} $f_endings {
		if {$flag_percent} {
			set fraction [expr {$total / $frame_len}]
			_debug "$symbol: [format %00.2f%% $fraction]"
		} else {
			_debug "$symbol: [format %.10f [expr {1000 * $total}]] miliseconds"
		}
	}
	set f_endings {}

	# display vdp commands that have finished
	variable v_endings
	foreach {id vdpcmd} $v_endings {
		dict with vdpcmd {
			_debug "vdp cmd #$id: [format %00.2f%% [expr {$total / $frame_len}]] $status"
		}
	}
	set v_endings {}

	#if {![osd exists profile.$symbol]} {
	#	_profiler_osd_update
	#}

	# reset VDP command ID counter
	variable v_beginnings
	if {$v_beginnings eq {}} {
		variable vdpcmd_id 0
	}
	_debug "-----"
}

proc _profiler_start {args} {
	# load symbol file
	set filename {}
	switch -- [llength $args] {
		0 {
			set symbols [debug symbols lookup]
		}
		1 {
			lassign $args filename
			debug symbols load "$filename"
			set symbols [debug symbols lookup -filename "$filename"]
		}
		default {
			error "symbols file name expected"
			return
		}
	}
	if {[llength $symbols] == 0} {
		error "symbols not found"
		return
	}
	# scan symbols and create function breakpoints
	variable f_entries
	foreach entry $symbols {
		lassign $entry _ symbol _ addr
		_debug "registering breapoint at [h $addr] ($symbol)"
		dict set f_entries $symbol [debug breakpoint create -address 0x[h $addr] -command [list _enter_function $symbol]]
	}
	# create probe breakpoints on VDP commands
	set probe_bp [debug probe set_bp VDP.commandExecuting {[debug probe read VDP.commandExecuting] == 1} _vdpcmd_start]
	set probe_bp [debug probe set_bp VDP.commandExecuting {[debug probe read VDP.commandExecuting] == 0} _vdpcmd_stop]
	# create probe breakpoints on vertical refresh
	set probe_bp [debug probe set_bp VDP.IRQvertical {[debug probe read VDP.IRQvertical] == 0} _tick]
}

proc profiler_stop {} {
	variable f_entries
	foreach {key bp} $f_entries {
		catch {debug breakpoint remove $bp}
	}
	set f_entries {}

	variable f_returns
	foreach {key bp} $f_returns {
		catch {debug breakpoint remove $bp}
	}
	set f_returns {}

	variable f_beginnings
	set f_beginnings {}

	variable f_endings
	set f_endings {}

	variable probe_bp
	if {$probe_bp ne {}} {
		catch {debug probe remove_bp $probe_bp}
	}
}

proc _profiler_osd_update {} {
	if {![osd exists profile.$symbol]} {
		set rgba [osd_hya [expr $index * 0.14] 0.5 1.0]
		osd create rectangle profile.$symbol -x 0 -y 0 -w $width -h $height -scaled true -clip true -rgba 0x00000088
		osd create rectangle profile.$symbol.bar -x 0 -y 0 -w 0 -h $height -scaled true -rgba $rgba
		osd create text profile.$symbol.text -x 2 -y 1 -size 5 -scaled true -rgba 0xffffffff
	}
	osd configure profile.$symbol -x [expr ($index * $height / 240) * $width] -y [expr $index * $height % 240]
	osd configure profile.$symbol.bar -w [expr ($fraction < 0 ? 0 : $fraction > 1 ? 1 : $fraction) * $width]
	osd configure profile.$symbol.text -text [format "%s: %00.2f%%" $slotid [expr $fraction * 100]]
}

proc profiler_osd {} {
	puts "Profiler OSD started"
}

proc profiler_start {args} {
	puts "Profiler started"
	if {[DEBUG] ne 0} { 
		if {[catch {_profiler_start {*}$args} fid]} {
			puts stderr $::errorInfo
			error $::errorInfo
		}
	} else {
		_profiler_start {*}$args
	}
	return
}

