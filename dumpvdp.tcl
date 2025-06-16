# Copyright © 2025 Pedro de Medeiros (pedro.medeiros at gmail.com)
# Dump VDP register I/O access to stderr
#
# call "start_dumpvdp" to begin.
namespace eval dumpvdp {

variable status "VAL"
variable value  {}
variable dirreg {} ;# direct register access
variable autinc 0  ;# auto increment
variable indreg {} ;# indirect register access
variable rdstat {} ;# ready to read VDP status register?
variable wp1
variable wp2
variable wp3

proc wt_ind {arg} {
	variable indreg
	variable autinc
	if {$indreg ne {}} {
		puts stderr "wrote byte 0x[format %x $arg] to vdp register $indreg indirectly"
		if {$autinc} { incr indreg }
	} else {
		puts stderr "wrote byte 0x[format %x $arg] to vdp register ??? indirectly"
	}
}

proc rd_sts {} {
	variable status "VAL" ;# reset in case of an out of sync problem
	variable rdstat
	if {$rdstat ne {}} {
		puts stderr "reading from vdp status register [expr {($rdstat & 15)}]"
	} else {
		puts stderr "reading from unspecified vdp status register"
	}
	#set rdstat {}
}

proc wt_dir {arg} {
	variable status
	variable dirreg
	variable indreg
	variable value
	variable autinc
	variable rdstat

	switch -- $status {
		"VAL" {
			set value $arg
			set status "REG" ;# next status
		}
		"REG" {
			# bit#8: reading (=0) or writing (=1) ?
			if {[expr {$arg & 0b10000000}] != 0} {
				set dirreg [expr {$arg & 0b00111111}]
				# detect VDP status read
				if {$dirreg == 15} {
					set rdstat $value
					if {($rdstat > 9) && ($rdstat < 16)} {
						puts "trying to read from invalid vdp status register $rdstat"
					}
				} elseif {$dirreg == 17} {
					# detect indirect VDP write
					set autinc [expr {($value & 0b10000000) == 0}]
					set indreg [expr {$value & 0b00111111}]
					puts stderr "set indirect access mode to register $indreg [expr {$autinc ? "with" : "without"}] autoincrement"
				} else {
					puts stderr "wrote byte 0x[format %x $value] to vdp register $dirreg directly"
				}
				set status "VAL" ;# next status
			}
		}
	}
}

} ;# namespace dumpvdp

namespace import dumpvdp::*;

# entry point
proc start_dumpvdp {} {
	variable dumpvdp::wp1
	variable dumpvdp::wp2
	variable dumpvdp::wp3
	set dumpvdp::wp1 [debug watchpoint create -type read_io  -address 0x99 -command {dumpvdp::rd_sts}]
	set dumpvdp::wp2 [debug watchpoint create -type write_io -address 0x99 -command {dumpvdp::wt_dir $::wp_last_value}]
	set dumpvdp::wp3 [debug watchpoint create -type write_io -address 0x9B -command {dumpvdp::wt_ind $::wp_last_value}]
	puts "dumpvdp watchpoints started"
}

proc stop_dumpvdp {} {
	variable dumpvdp::wp1
	variable dumpvdp::wp2
	variable dumpvdp::wp3
	debug watchpoint remove $dumpvdp::wp1
	debug watchpoint remove $dumpvdp::wp2
	debug watchpoint remove $dumpvdp::wp3
	puts "dumpvdp watchpoints stopped"
}
