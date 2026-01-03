
variable f_entries {}     ;# function entry points
variable f_returns {}     ;# function return points
variable f_beginnings {}  ;# time mark (beginning)
variable f_endings {}     ;# time mark (ending)
variable probe_bp {}
variable width 32
variable height 8
variable frame_begin 0
variable percent 1

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
	if {![dict exists $f_returns $caller]} {
		_debug "creating breakpoint to [h $caller]"
		dict set f_returns $caller [debug breakpoint create -address $caller -command [list _exit_function $symbol]]
  }
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
	set start [dict get $f_beginnings $symbol]
	dict unset f_beginnings $symbol

	variable f_endings
	set total [expr {[machine_info time] - $start}]
	dict set f_endings $symbol $total
}

proc _tick_start {} {
	variable frame_begin [machine_info time]
}

proc _tick_end {} {
	variable frame_begin
	set frame_end [machine_info time]
	set frame_len [expr {$frame_end - $frame_begin}]

	variable f_beginnings
	variable f_endings
	variable percent

	foreach {symbol start} $f_beginnings {
		if {$percent} {
			set fraction [expr {($frame_end - $start) / $frame_len}]
			_debug "$symbol (unfinished): [format %00.2f%% $fraction] "
		}
	}
	foreach {symbol total} $f_endings {
		if {$percent} {
			set fraction [expr {$total / $frame_len}]
			_debug "$symbol: [format %00.2f%% $fraction]"
		} else {
			_debug "$symbol: [format %.10f $total] seconds"
		}
	}
	set f_endings {}

	#if {![osd exists profile.$symbol]} {
	#	_profiler_osd_update
	#}
}

proc _vdpcmd_start {} {
	variable f_beginnings
	dict set f_beginnings vdp_cmd [machine_info time]
}

proc _vdpcmd_end {} {
	_exit_function vdp_cmd
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
	if {!$symbols} {
		error "symbols not found"
		return
	}
	# scan symbols and create function breakpoints
	variable f_entries
	foreach entry $symbols {
		lassign $entry _ symbol _ addr
		_debug "registering breapoint at [h $addr] ($symbol)"
		dict set f_entries $symbol [debug breakpoint create -address $addr -command [list _enter_function $symbol]]
	}
	# create probe breakpoints on VDP commands
	set probe_bp [debug probe set_bp VDP.commandExecuting {[debug probe read VDP.commandExecuting] == 1} _vdpcmd_start]
	set probe_bp [debug probe set_bp VDP.commandExecuting {[debug probe read VDP.commandExecuting] == 0} _vdpcmd_end]
	# create probe breakpoints on vertical refresh
	set probe_bp [debug probe set_bp VDP.IRQvertical {[debug probe read VDP.IRQvertical] == 0} _tick_start]
	set probe_bp [debug probe set_bp VDP.IRQvertical {[debug probe read VDP.IRQvertical] == 1} _tick_end]
}

proc profiler_end {} {
	variable f_entries
	foreach {key bp} $f_entries {
		catch { debug breakpoint remove $bp }
	}
	set f_entries {}

	variable f_returns
	foreach {key bp} $f_returns {
		catch { debug breakpoint remove $bp }
	}
	set f_returns {}

	variable f_beginnings
	set f_beginnings {}

	variable f_endings
	set f_endings {}

	variable probe_bp
	if {$probe_bp ne {}} {
		catch { debug probe remove_bp $probe_bp }
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

