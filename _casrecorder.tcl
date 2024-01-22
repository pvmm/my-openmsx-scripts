namespace eval cas {
variable active false

variable directory [file normalize $::env(OPENMSX_USER_DATA)/../cas_recordings]
variable file_prefix "tape"
variable file_name ""
variable full_file_name
variable BIN_PREFIX_SIZE 7
variable prefix

variable HEADER [binary format H* "1FA6DEBACC137D74"]
variable BINARY [binary format H* "D0D0D0D0D0D0D0D0D0D0"]
variable BASIC  [binary format H* "D3D3D3D3D3D3D3D3D3D3"]
variable ASCII  [binary format H* "EAEAEAEAEAEAEAEAEAEA"]

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
		concat start add stop abort
	}
}

proc set_file_name {{name ""}} {
	variable file_prefix
	variable directory
	variable file_name
	variable prefix OFF

	if {[string length $name] > 0} {
		set file_name $name
	}
	if {[string length $file_name] == 0} {
		set file_name $file_prefix
		set prefix ON
	}
	if {[file extension $file_name] eq ".cas"} {
		set file_name [file rootname $file_name]
	}

	if {!$prefix} {
		variable full_file_name [file join $directory "$file_name.cas"]
	} else {
		variable full_file_name [utils::get_next_numbered_filename $directory $file_name ".cas"]
	}
	if {[file exists $full_file_name]} {
		variable full_file_name [utils::get_next_numbered_filename $directory $file_name ".cas"]
	}

	return $full_file_name
}

proc cas_rec_set_file_name {{name ""}} {
	message "Setting CAS file name to [cas::set_file_name $name]..."
}

proc cas_rec {args} {
	set add_index [lsearch -exact $args "add"]
	if {$add_index >= 0} {
		set name [lindex $args $add_index+1]
		return [cas::cas_rec_add $name]
	}

	if {[lsearch -exact $args "abort"] >= 0} {
		return [cas::cas_rec_end true]
	}

	if {[lsearch -exact $args "stop"] >= 0} {
		return [cas::cas_rec_end false]
	}

	set start_index [lsearch -exact $args "start"]
	if {$start_index >= 0} {
		variable active
		if {$active} {
			error "Tape file already defined, please stop it before running start again."
		}
		if {$start_index == ([llength $args])} {
			cas_rec_set_file_name [lindex $args $start_index+1]
		} else {
			cas_rec_set_file_name
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
}

proc cas_rec_add {file_name} {
	variable active
	if {!$active} {
		error "Tape file not created."
	}
	if {![file exists $file_name]} {
		error "File $file_name not found."
	}
	set fsize [file size $file_name]
	if {$fsize == 0} {
		error "File $file_name is empty."
	}
	# Get file prefix
	set fp [open $file_name r]
	set prefix [scan [read $fp 1] %c]

	variable HEADER
	variable tape_data
	switch $prefix {
		255 {
			message "Adding BASIC file..."
			append tape_data $HEADER
			variable BASIC
			append tape_data $BASIC
			# cassette file ID
			append tape_data [string range "[file rootname $file_name]     " 0 5]
			append tape_data $HEADER
			# file contents
			append tape_data [read $fp [expr {$fsize - 1}]]
			# 16 byte boundary padding with zero
			set len [expr (8 - [string length $tape_data] % 8) % 8]
			append tape_data [string repeat [binary format c 0] $len]
			append tape_data [string repeat [binary format c 0] 8]
		}
		254 {
			message "Adding binary file..."
			variable BIN_PREFIX_SIZE
			if {$fsize < $BIN_PREFIX_SIZE} {
				error "File $file_name ends abruptly."
			}
			append tape_data $HEADER
			variable BINARY
			append tape_data $BINARY
			# cassette file ID
			append tape_data [string range "[file rootname $file_name]     " 0 5]
			append tape_data $HEADER
			# start address
			append tape_data [read $fp 2]
			# end address
			append tape_data [read $fp 2]
			# exec address
			append tape_data [read $fp 2]
			# file contents
			append tape_data [read $fp [expr {$fsize - 7}]]
			# 8 byte boundary padding with zero
			set len [expr (8 - [string length $tape_data] % 8) % 8]
			append tape_data [string repeat [binary format c 0] $len]
		}
		default {
			message "Adding ASCII file..."
			append tape_data $HEADER
			variable ASCII
			append tape_data $ASCII
			# cassette file ID
			append tape_data [string range "[file rootname $file_name]     " 0 5]
			append tape_data $HEADER
			# file contents
			append tape_data "[binary format c ${prefix}][read $fp $fsize]"
			# EOF
			# 256 byte boundary padding with 0x1A
			set len [expr 256 - [string length $tape_data] % 256]
			append tape_data [string repeat [binary format c 0x1A] $len]
		}
	}

	close $fp
}

proc cas_rec_end {abort} {
	variable active
	if {!$active} {
		error "No tape file active currently..."
	}

	variable tape_data
	if {!$abort} {
		variable full_file_name
		set file_handler [open $full_file_name "w"]
		fconfigure $file_handler -encoding binary -translation binary
		puts -nonewline $file_handler $tape_data
		close $file_handler

		variable file_name
		set stop_message "Tape recording stopped, wrote data to [file tail $full_file_name]."
	} else {
		set stop_message "Tape recording aborted, no data written."
		set tape_data ""
	}

	set active false
	message $stop_message
	return $stop_message
}

namespace export cas_rec

}

namespace import cas::*
