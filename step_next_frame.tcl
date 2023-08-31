proc PAUSED {} { return 1 }

set frame_status 0

after frame {debug break}

proc step_next_frame {} {
	global frame_status
	if {$frame_status eq [PAUSED]} {
		after frame {debug break}
		debug cont
	} else {
		set frame_status [PAUSED]
		after frame {debug break}
	}
	# suppress output
	return
}
