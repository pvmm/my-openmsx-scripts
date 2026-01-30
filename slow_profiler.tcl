# This code evolved into new-profiler.tcl and is no longer maintained.
# Copyright © 2026 Pedro de Medeiros (pedro.medeiros at gmail.com)
#
variable scope {}
variable cur_time 0
variable next_addr 0
variable jump_addr {}
variable call_addr {}
variable ret_addr {}
variable bios_slot 0
variable slot 1
variable old_sp 0
variable old_pc 0
variable old_time 0
variable timediff 0
variable bios_ret 0
variable bios_wp {}
variable exec_wp {}

proc env {varname {defaults {}}} {
	if {[info exists ::env($varname)]} {
		return $::env($varname);
	}
	return $defaults;
}       

proc h {number} {
	if {$number eq {}} { return {} }
	return [format %04x $number]
}

proc _debug {text} {
	if {[env DEBUG] eq 2} { 
		puts stderr $text
	}
}

proc _debug_scope {} {
	variable scope
	foreach item $scope {
		lassign $item start end
		puts stderr "[h $start] [h $end]"
	}
	puts stderr "------"
}

proc current_ret_addr {} {
	variable scope
	return [lindex [lindex $scope end] end]
}

proc sum_time {} {
	variable old_time
	set now [machine_info time]
	set timediff [expr {$now - $old_time}]
	set old_time $now
	return $timediff
}

proc pop {lst} {
	upvar 1 $lst curlist
	set curlist [lrange $curlist 0 end-1]
}

proc pop_scope {{addr {}}} {
	variable scope
	if {$addr ne {}} {
		set last_scope [lindex $scope end]
		lassign $last_scope start end
		if {$end != $addr} {
			error "scope end address [h $addr]($addr) not found in $scope"
			debug break
		}
		# if not BIOS RET?
		_debug "scope ([h $start], [h $end]) popped"
	}
	pop scope
}

proc _bios_call {} {
	_debug "bios_call: BIOS CALL detected"
	variable bios_ret 1
	variable bios_wp {}
}

proc _exec_mem {} {
	variable cur_time
	variable scope
	variable jump_addr
	variable call_addr
	variable ret_addr
	variable old_pc
	variable old_sp
	variable bios_slot
	variable bios_ret

	# first instruction fetch
	if {[reg PC] == $::wp_last_address} {
		set last_disasm [expr {[llength [debug disasm [reg PC]]] - 1}] 
	} else {
		#_debug "exec_mem: read_mem ignored"
		return
	}

	_debug "exec_mem: (status) pc=[h [reg PC]], wp_last_address=[h $::wp_last_address], bios_ret=$bios_ret, old_sp=[h $old_sp], ret_addr=[h $ret_addr]"

	# was CALL routine a BIOS call?
	if {$bios_ret == 1 && $call_addr ne {} && $call_addr != [reg PC]} {
		_debug "exec_mem: BIOS call ignored"
		set call_addr {}
	}
	# untreated JUMP routine is a BIOS call
	if {$bios_ret == 1 && $jump_addr ne {} && $jump_addr != [reg PC]} {
		_debug "exec_mem: BIOS call ignored (by JUMP)"
		pop_scope [reg PC]
	}
	set jump_addr {}

	# add time consumed to scope
	set cur_time [expr {$cur_time + [sum_time]}]
	_debug "exec_mem: current time = $cur_time"

	# check CALL result
	if {$call_addr != {} && [reg PC] == $call_addr && [reg SP] != $old_sp} {
		# CALL succeeded: create new scope
		set start [peek16 [expr {$old_pc + 1}]]
		set end [expr {$old_pc + 3}]
		_debug "exec_mem: new scope created at ([h $start], [h $end])"
		lappend scope "$start $end"
	}
	set call_addr {}

	# check RET result
	if {$ret_addr != {} && [reg PC] == $ret_addr && [reg SP] == $old_sp} {
		#_debug "SP = [reg SP] == [expr {$old_sp + 2}], $old_sp, [expr {$old_sp - 2}]?"
		#append timers {[name $scope] $cur_time}
		# RET succeeded: delete last scope
		lassign [lindex $scope end] start end
		_debug "exec_mem: scope ([h $start], [h $end]) deleted"
		pop_scope $end
	}
	set ret_addr {}

	# detect CALL/RET
	set disasm [debug disasm [reg PC]]
	_debug "exec_mem ($disasm)"
	set instr [lindex $disasm 0]
	switch -glob -- $instr {
		"jp*" {
			set jump_addr [peek16 [expr {[reg PC] + 1}]]
			_debug "exec_mem: JUMP: jump_addr=[h $jump_addr] *break*"
			#debug break
		}
		"jr*" {
			set jump_addr [expr {[reg PC] + [peek_s8 [expr {[reg PC] + 1}]] + 2}]
			_debug "exec_mem: relative JUMP: jump_addr=[h $jump_addr] *break*"
			#debug break
		}
		"call*" {
			set call_addr [peek16 [expr {[reg PC] + 1}]]
			set old_sp [reg SP]
			_debug "exec_mem: CALL: call_addr=[h $call_addr], old_sp=[h $old_sp] *break*"
			#debug break
		}
		"ret*" {
			# get stack return address
			set ret_addr [peek16 [reg SP]]
			set old_sp [expr {[reg SP] + 2}]
			_debug "exec_mem: RET: ret_addr=[h $ret_addr], old_sp=[h $old_sp] *break*"
			#debug break
		}
	}

	if {$bios_ret == 1} {
		_debug "exec_mem: clear bios_ret status"
		set bios_ret 0
		_detect_bios_call
	}
	set old_pc [reg PC]
}

proc _detect_bios_call {} {
	variable bios_wp
	variable bios_slot
	if {$bios_wp eq {}} {
		set bios_wp [debug set_watchpoint -once read_mem {0x0008 0x3fff} "\[pc_in_slot $bios_slot\]" _bios_call]
	}
}

proc on_reset {} {
	puts "reset detected"
}


proc _profiler_start {} {
	variable slot
	variable exec_wp
	# detect instruction execution
	set exec_wp [ debug set_watchpoint read_mem {0x0000 0xffff} "\[pc_in_slot $slot\]" _exec_mem]
	set after_reset_id [after boot [namespace code on_reset]]
}

proc profiler_start {args} {
	_debug "profiler_start called"		
	#if {[env DEBUG] ne 0} { 
		if {[catch {_profiler_start {*}$args} fid]} {
			puts stderr $::errorInfo
			error $::errorInfo
	}
	#} else {
	#	_profiler_start {*}$args
	#}
	return
}
