namespace eval cas {
variable active false

variable directory [file normalize $::env(OPENMSX_USER_DATA)/../cas_recordings]
variable original_filename "tape%i"

variable tape_data

set_help_proc cas_rec [namespace code cas_rec_help]
proc cas_rec_help {args} {
        switch -- [lindex $args 1] {
                "start"    {return {CAS recording will be initialised. By default the file name will be tape0001.cas, but when it already exists, tape0002.cas etc...

Syntax: cas_rec new [CAS file name]

Create a memory region to store files in a tape. A file name can be specified if desired.
}}
                "add" {return {Detect file type and add it to the current tape.

Syntax: cas_rec stop
}}
                "stop" {return {Stop recording and save the data to the openMSX user directory in cas_recordings. By default the filename will be tape0001.cas, when this exists tape0002.cas etc...

Syntax: cas_rec stop
}}
                "abort"  {return {Abort an active recording without saving the data.

Syntax: cas_rec abort
}}
                default {return {Record a CAS file to be used by the casseteplayer interface in openMSX.

Syntax: cas_rec <sub-command> [arguments if needed]

Where sub-command is one of:
start, stop, abort.

Use 'help cas_rec <sub-command>' to get more help on specific sub-commands.
}}
        }
}

set_tabcompletion_proc cas_rec [namespace code tab_casrec]

proc tab_casrec {args} {
	variable supported_chips
	if {[lsearch -exact $args "start"] >= 0} {
		concat [CAS file name]
	} else {
		concat start stop abort
	}
}

proc set_next_filename {} {
        variable original_filename
        variable directory
        variable file_name [utils::get_next_numbered_filename $directory $original_filename ".cas"]
}

proc cas_rec_set_filename {filename} {
        variable original_filename

        if {[file extension $filename] eq ".cas"} {
                set filename [file rootname $filename]
        }
        set original_filename $filename
	if {[file exists $filename]} {
        	set_next_filename
	}
}

cas_rec_set_filename "tape"

proc cas_rec {args} {
	if {[lsearch -exact $args "add"] >= 0} {
		return [cas::cas_rec_add $filename]
	}

	if {[lsearch -exact $args "abort"] >= 0} {
		return [cas::cas_rec_end true]
	}

	if {[lsearch -exact $args "stop"] >= 0} {
		return [cas::cas_rec_end false]
	}

	set index [lsearch -exact $args "start"]
	if {$index >= 0} {
		if {$active} {
			error "Tape file already defined, please stop it before running start again."
		}
		if {$start_index == ([llength $args])} {
			cas_rec_set_filename [lindex $args $start_index+1]
		}
		return [cas::cas_rec_start]
	}

	error "Invalid input detected, use tab completion"
}

proc cas_rec_start {} {
	variable active true

	variable directory
	file mkdir $directory

	variable tape_data ""
	variable temp_tape_data ""

	variable file_name
	message "Tape $file_name initiated."
}

proc find_all_scc {} {
	set result [list]
	for {set ps 0} {$ps < 4} {incr ps} {
		for {set ss 0} {$ss < 4} {incr ss} {
			set device_list [machine_info slot $ps $ss 2]
			if {[llength $device_list] != 0} {
				set device [lindex $device_list 0]
				set device_info_dict [machine_info device $device]
				set device_type [dict get $device_info_dict "type"]
				if {[string match -nocase *scc* $device_type]} {
					lappend result $ps $ss 1
				} elseif {[dict exists $device_info_dict "mappertype"]} {
					set mapper_type [dict get $device_info_dict "mappertype"]
					if {[string match -nocase *scc* $mapper_type] ||
					    [string match -nocase manbow2 $mapper_type] ||
					    [string match -nocase KonamiUltimateCollection $mapper_type]} {
						lappend result $ps $ss 0
					}
				}
			}
			if {![machine_info issubslotted $ps]} break
		}
	}
	return $result
}

proc find_all_sfg {} {
	set result [list]
	for {set ps 0} {$ps < 4} {incr ps} {
		for {set ss 0} {$ss < 4} {incr ss} {
			set device_list [machine_info slot $ps $ss 0]
			if {[llength $device_list] != 0} {
				set device [lindex $device_list 0]
				set device_info_dict [machine_info device $device]
				set device_type [dict get $device_info_dict "type"]
				# expected string is "YamahaSFG"
				if {[string match -nocase *sfg* $device_type]} {
					lappend result $ps $ss
				}
			}
			if {![machine_info issubslotted $ps]} break
		}
	}
	return $result
}

proc write_psg_address {} {
	variable psg_register $::wp_last_value
}

proc write_psg_data {} {
	variable psg_register
	if {$psg_register >= 0 && $psg_register < 14} {
		update_time
		variable music_data
		append music_data [binary format ccc 0xA0 $psg_register $::wp_last_value]
	}
}

proc write_opll_address {} {
	variable opll_register $::wp_last_value
}

proc write_opll_data {} {
	variable opll_register
	if {$opll_register >= 0} {
		update_time
		variable music_data
		append music_data [binary format ccc 0x51 $opll_register $::wp_last_value]
	}
}

proc write_y2151_address {} {
	variable y2151_register $::wp_last_value
}
proc write_y2151_data {} {
	variable y2151_register
	if {$y2151_register >= 0} { # initialised to -1
		update_time
		variable music_data
		append music_data [binary format ccc 0x54 $y2151_register $::wp_last_value]
	}
}

proc write_y8950_address {} {
	variable y8950_register $::wp_last_value
}

proc write_y8950_data {} {
	variable y8950_register
	if {$y8950_register >= 0} {
		update_time
		variable music_data
		append music_data [binary format ccc 0x5C $y8950_register $::wp_last_value]
	}
}

proc write_opl4_address_wave {} {
	variable opl4_register_wave $::wp_last_value
}

proc write_opl4_data_wave {} {
	variable opl4_register_wave
	if {$opl4_register_wave >= 0} {
		update_time
		# VGM spec: Port 0 = FM1, port 1 = FM2, port 2 = Wave. It's
		# based on the datasheet A1 & A2 use.
		variable music_data
		append music_data [binary format cccc 0xD0 0x2 $opl4_register_wave $::wp_last_value]
	}
}

proc write_opl4_address_1 {} {
	variable opl4_register $::wp_last_value
	variable active_fm_register 0
}

proc write_opl4_address_2 {} {
	variable opl4_register $::wp_last_value
	variable active_fm_register 1
}

proc write_opl4_data {} {
	variable opl4_register
	variable active_fm_register
	if {$opl4_register >= 0} {
		update_time
		variable music_data
		append music_data [binary format cccc 0xD0 $active_fm_register $opl4_register $::wp_last_value]
	}
}

proc write_opl3_address_1 {} {
	variable opl3_register $::wp_last_value
	variable opl3_port 0xC0
}

proc write_opl3_address_2 {} {
	variable opl3_register $::wp_last_value
	variable opl3_port 0xC2
}

proc write_opl3_data {} {
	variable opl3_register
	if {$opl3_register >= 0} {
		update_time
		variable opl3_port
		variable music_data
		switch $opl3_port {
			0xC0 { append music_data [binary format ccc 0x5E $opl3_register $::wp_last_value] }
			0xC2 { append music_data [binary format ccc 0x5F $opl3_register $::wp_last_value] }
		}
	}
}

proc scc_data {} {
	# Thanks ValleyBell, BiFi

	# if 9800h is written, waveform channel 1   is set in 9800h - 981fh, 32 bytes
	# if 9820h is written, waveform channel 2   is set in 9820h - 983fh, 32 bytes
	# if 9840h is written, waveform channel 3   is set in 9840h - 985fh, 32 bytes
	# if 9860h is written, waveform channel 4,5 is set in 9860h - 987fh, 32 bytes
	# if 9880h is written, frequency channel 1 is set in 9880h - 9881h, 12 bits
	# if 9882h is written, frequency channel 2 is set in 9882h - 9883h, 12 bits
	# if 9884h is written, frequency channel 3 is set in 9884h - 9885h, 12 bits
	# if 9886h is written, frequency channel 4 is set in 9886h - 9887h, 12 bits
	# if 9888h is written, frequency channel 5 is set in 9888h - 9889h, 12 bits
	# if 988ah is written, volume channel 1 is set, 4 bits
	# if 988bh is written, volume channel 2 is set, 4 bits
	# if 988ch is written, volume channel 3 is set, 4 bits
	# if 988dh is written, volume channel 4 is set, 4 bits
	# if 988eh is written, volume channel 5 is set, 4 bits
	# if 988fh is written, channels 1-5 on/off, 1 bit

	#VGM port format:
	#0x00 - waveform
	#0x01 - frequency
	#0x02 - volume
	#0x03 - key on/off
	#0x04 - waveform (0x00 used to do SCC access, 0x04 SCC+)
	#0x05 - test register

	update_time

	variable music_data
	if       {0x9800 <= $::wp_last_address && $::wp_last_address < 0x9880} {
		append music_data [binary format cccc 0xD2 0x0 [expr {$::wp_last_address - 0x9800}] $::wp_last_value]
	} elseif {0x9880 <= $::wp_last_address && $::wp_last_address < 0x988A} {
		append music_data [binary format cccc 0xD2 0x1 [expr {$::wp_last_address - 0x9880}] $::wp_last_value]
	} elseif {0x988A <= $::wp_last_address && $::wp_last_address < 0x988F} {
		append music_data [binary format cccc 0xD2 0x2 [expr {$::wp_last_address - 0x988A}] $::wp_last_value]
	} elseif {$::wp_last_address == 0x988F} {
		append music_data [binary format cccc 0xD2 0x3 0x0 $::wp_last_value]
	}
}

proc scc_plus_data {} {
	# if b800h is written, waveform channel 1 is set in b800h - b81fh, 32 bytes
	# if b820h is written, waveform channel 2 is set in b820h - b83fh, 32 bytes
	# if b840h is written, waveform channel 3 is set in b840h - b85fh, 32 bytes
	# if b860h is written, waveform channel 4 is set in b860h - b87fh, 32 bytes
	# if b880h is written, waveform channel 5 is set in b880h - b89fh, 32 bytes
	# if b8a0h is written, frequency channel 1 is set in b8a0h - b8a1h, 12 bits
	# if b8a2h is written, frequency channel 2 is set in b8a2h - b8a3h, 12 bits
	# if b8a4h is written, frequency channel 3 is set in b8a4h - b8a5h, 12 bits
	# if b8a6h is written, frequency channel 4 is set in b8a6h - b8a7h, 12 bits
	# if b8a8h is written, frequency channel 5 is set in b8a8h - b8a9h, 12 bits
	# if b8aah is written, volume channel 1 is set, 4 bits
	# if b8abh is written, volume channel 2 is set, 4 bits
	# if b8ach is written, volume channel 3 is set, 4 bits
	# if b8adh is written, volume channel 4 is set, 4 bits
	# if b8aeh is written, volume channel 5 is set, 4 bits
	# if b8afh is written, channels 1-5 on/off, 1 bit

	#VGM port format:
	#0x00 - waveform
	#0x01 - frequency
	#0x02 - volume
	#0x03 - key on/off
	#0x04 - waveform (0x00 used to do SCC access, 0x04 SCC+)
	#0x05 - test register

	update_time

	variable music_data
	if       {0xB800 <= $::wp_last_address && $::wp_last_address < 0xB8A0} {
		append music_data [binary format cccc 0xD2 0x4 [expr {$::wp_last_address - 0xB800}] $::wp_last_value]
	} elseif {0xB8A0 <= $::wp_last_address && $::wp_last_address < 0xb8aa} {
		append music_data [binary format cccc 0xD2 0x1 [expr {$::wp_last_address - 0xB8A0}] $::wp_last_value]
	} elseif {0xB8AA <= $::wp_last_address && $::wp_last_address < 0xB8AF} {
		append music_data [binary format cccc 0xD2 0x2 [expr {$::wp_last_address - 0xB8AA}] $::wp_last_value]
	} elseif {$::wp_last_address == 0xB8AF} {
		append music_data [binary format cccc 0xD2 0x3 0x0 $::wp_last_value]
	}

	variable scc_plus_used true
}

proc cas_rec_end {abort} {
	variable active
	if {!$active} {
		error "No recording currently..."
	}

	# remove all watchpoints that were created
	variable watchpoints
	foreach watch $watchpoints {
		if {[catch {
			debug remove_watchpoint $watch
		} errorText]} {
			puts "Failed to remove watchpoint $watch... using savestates maybe? Continue anyway."
		}
	}
	set watchpoints [list]

	if {!$abort} {
		update_time

		variable tick_time 0
		variable music_data
		variable temp_music_data 

		append temp_music_data $music_data [binary format c 0x66]

		set header "Vgm "
		# file size
		append header [little_endian_32 [expr {[string length $temp_music_data] + 0x100 - 4}]]
		# VGM version 1.7
		append header [little_endian_32 0x161] [zeros 4]

		# YM2413 clock
		variable fm_logged
		if {$fm_logged} {
			append header [little_endian_32 3579545]
		} else {
			append header [zeros 4]
		}

		# GD3 offset
		append header [zeros 4]

		# Number of ticks
		variable ticks
		append header [little_endian_32 $ticks]
		set ticks 0
		append header [zeros 20]
		# End of 2612

		variable y2151_logged
		if {$y2151_logged} {
			append header [little_endian_32 3579545]
		} else {
			append header [zeros 4]
		}

		# Data starts at offset 0x100
		append header [little_endian_32 [expr {0x100 - 0x34}]] [zeros 32]

		# Y8950 clock
		variable y8950_logged
		if {$y8950_logged} {
			append header [little_endian_32 3579545]
		} else {
			append header [zeros 4]
		}

		# YMF262 clock
		variable opl3_logged
		if {$opl3_logged} {
			append header [little_endian_32 14318182]
		} else {
			append header [zeros 4]
		}

		# YMF278B clock
		variable moonsound_logged
		if {$moonsound_logged} {
			append header [little_endian_32 33868800]
		} else {
			append header [zeros 4]
		}

		append header [zeros 16]

		# AY8910 clock
		variable psg_logged
		if {$psg_logged} {
			append header [little_endian_32 1789773]
		} else {
			append header [zeros 4]
		}

		append header [zeros 36]

		# SCC clock
		variable scc_logged
		if {$scc_logged} {
			set scc_clock 1789773
			variable scc_plus_used
			if {$scc_plus_used} {
				# enable bit 31 for SCC+ support, that's how it's done
				# in VGM I've been told. Thanks Grauw.
				set scc_clock [expr {$scc_clock | 1 << 31}]
			}
			append header [little_endian_32 $scc_clock]
		} else {
			append header [zeros 4]
		}

		append header [zeros 96]

		variable file_name
		variable directory

		# Title hacks
		variable mbwave_title_hack
		variable mbwave_basic_title_hack
		if {$mbwave_title_hack || $mbwave_basic_title_hack} {
			set title_address [expr {$mbwave_title_hack ? 0xffc6 : 0xc0dc}]
			set file_name [string map {/ -} [debug read_block "Main RAM" $title_address 0x32]]
			set file_name [string trim $file_name]
			set file_name [format %s%s%s%s $directory "/" $file_name ".vgm"]
		}

		set file_handle [open $file_name "w"]
		fconfigure $file_handle -encoding binary -translation binary
		puts -nonewline $file_handle $header
		puts -nonewline $file_handle $temp_music_data
		close $file_handle

		set stop_message "VGM recording stopped, wrote data to $file_name."
	} else {
		set stop_message "VGM recording aborted, no data written..."
	}

	set active false
	variable start_time 0
	variable loop_amount 0

	message $stop_message
	return $stop_message
}

namespace export cas_rec

}

namespace import cas::*
