# Copyright © 2024 Pedro de Medeiros (pedro.medeiros at gmail.com)

namespace eval mm {
variable is_enabled false
variable current_register
variable waiting_data false
variable file_name
variable original_file_name
# Default file name is "[OPENMSX_USER_DATA]/mm/ym2413.txt"
variable directory [file normalize $::env(OPENMSX_USER_DATA)/../mm]
variable file_handle
variable {reg_w#id}
variable {data_w#id}


proc set_file_name {{name "ym2413.txt"}} {
	variable original_file_name
	variable file_name
	variable directory

	set original_file_name $name
	set file_name [format %s%s%s $directory "/" $original_file_name]
	message "output file name set to $file_name"

	if {![file isdirectory $directory]} {
		file mkdir $directory
	}
}

proc is_instrument_0_reg {reg} {
	variable waiting_data
	variable current_register

	if {($reg >= 0 && $reg <= 7)} {
		set waiting_data true
		set current_register $reg
	} else {
		set waiting_data false
	}
}

proc is_instrument_0_data {value} {
	variable waiting_data
	variable file_handle
	variable current_register

	if {!$waiting_data} {
		return
	}

	puts -nonewline $file_handle "register: [format %02x $current_register], "
	puts            $file_handle    "value: [format %02x $value]"

	switch $current_register {
		0 {
			puts $file_handle "  Amplitude Modulation (M): [format   %s [expr ($value & 128) > 0 ? ON : OFF]]"
			puts $file_handle "               Vibrato (M): [format   %s [expr ($value &  64) > 0 ? ON : OFF]]"
			puts $file_handle "         Envelope Type (M): [format   %s [expr ($value &  32) > 0 ? \"Sustained\" : \"Percussive\"]]"
			puts $file_handle "        Key Scale Rate (M): [format   %s [expr ($value &  16) > 0 ? ON : OFF]]"
			puts $file_handle "            Multiplier (M): [format   %d [expr ($value &  15)]]"
		}
		1 {
			puts $file_handle "  Amplitude Modulation (C): [format   %s [expr ($value & 128) > 0 ? ON : OFF]]"
			puts $file_handle "               Vibrato (C): [format   %s [expr ($value &  64) > 0 ? ON : OFF]]"
			puts $file_handle "         Envelope Type (C): [format   %s [expr ($value &  32) > 0 ? \"Sustained\" : \"Percussive\"]]"
			puts $file_handle "        Key Scale Rate (C): [format   %s [expr ($value &  16) > 0 ? ON : OFF]]"
			puts $file_handle "            Multiplier (C): [format   %d [expr ($value &  15)]]"
		}
		2 {
			puts $file_handle "       Key Scale Level (M): [format   %d [expr ($value & 192) >> 6]]"
			puts $file_handle "           Total Level (M): [format   %d [expr ($value &  63)]]"
		}
		3 {
			puts $file_handle "       Key Scale Level (C): [format   %d [expr ($value & 192) >> 6]]"
			puts $file_handle "              Waveform (C): [format   %s [expr ($value &  16) > 0 ? \"Half Sine\" : \"Sine\"]]"
			puts $file_handle "              Waveform (M): [format   %s [expr ($value &   8) > 0 ? \"Half Sine\" : \"Sine\"]]"
			puts $file_handle "              Feedback (M): [format   %d [expr ($value &   7)]]"
		}
		4 {
			puts $file_handle "           Attack Rate (M): [format   %d [expr ($value & 240) >> 4]]"
			puts $file_handle "            Decay Rate (M): [format   %d [expr ($value & 15)]]"
		}
		5 {
			puts $file_handle "           Attack Rate (C): [format   %d [expr ($value & 240) >> 4]]"
			puts $file_handle "            Decay Rate (C): [format   %d [expr ($value & 15)]]"
		}
		6 {
			puts $file_handle "         Sustain Level (M): [format   %d [expr ($value & 240) >> 4]]"
			puts $file_handle "          Release Rate (C): [format   %d [expr ($value & 15)]]"
		}
		7 {
			puts $file_handle "         Sustain Level (M): [format   %d [expr ($value & 240) >> 4]]"
			puts $file_handle "          Release Rate (C): [format   %d [expr ($value & 15)]]"
		}
		default {
		}
	}
	flush $file_handle
	set waiting_data false
}

proc toggle_access {} {
	variable is_enabled
	variable file_name
	variable file_handle
	variable {reg_w#id}
	variable {data_w#id}

	message "mm [expr {$is_enabled ? "deactivated" : "activated"}]" 
	if {!$is_enabled} {
		set reg_w#id  [debug set_watchpoint write_io 0x7c {} {mm::is_instrument_0_reg  $::wp_last_value}]
		set data_w#id [debug set_watchpoint write_io 0x7d {} {mm::is_instrument_0_data $::wp_last_value}]
		set_file_name
		set file_handle [open $file_name a]
		set is_enabled true
	} else {
		close $file_handle
		debug remove_watchpoint ${reg_w#id}
		debug remove_watchpoint ${data_w#id}
		set is_enabled false
	}
}

namespace export toggle_access
namespace export set_file_name

} ;#namespace mm

# button2 is the MIDDLE button
bind "mouse button2 down" {mm::toggle_access}

