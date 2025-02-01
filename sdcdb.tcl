# SDCDB connector - Version 1.0
#
# Copyright 2025 Pedro de Medeiros all rights reserved
#
# SDCDB connector uses SDCC integrated debugger to create breakpoints and much more.
#
# The main difference between SDCDB connector's breakpoints and the built-in OpenMSX
# breakpoints is the C code integration:
# [ ] allow users to create breakpoints on C code:
#     > sdcdb::break main.c:55
# [ ] print contents of a C variable:
#     > sdcdb::print status
# [ ] print type of a C variable:
#     > sdcdb::ptype status
# [ ] step to next C instruction:
#     > sdcdb::next
# [ ] list current C line:
#     > sdcdb::list.
# [ ] list C source code at line 100:
#     > sdcdb::list main.c:100
# 
# Caveat: you need the sdcdb debugger and sz80 simulator (µCsim) from the SDCC compiler
# collection to run SDCDB connector. Some package managers rename sz80 to ucsim_z80, so
# sdcdb won't work without renaming it or creating a symlink to sz80.
#
# Commands that SDCDB connector recognizes directly. You may call them with sdcdb::[COMMAND] [ARGS...]:
#
# connect [src DIRECTORY1:DIRECTORY2:...] [NAME]
#       - Invoke SDCDB and connect to it. You may specify paths to the source files
#         that SDCDB uses. NAME points to the IHX (NAME.ihx) and CDB (NAME.cdb) files
#         generated by SDCC (compile your code using SDCC -debug parameter).
# disconnect
#       - close connection to SDCDB, killing the process.
# break [LINE | FILE:LINE | FILE:FUNCTION | FUNCTION | *<address> ]
#       - creates breakpoint
# clear [LINE | FILE:LINE | FILE:FUNCTION | FUNCTION | *<address> ]
#       - deletes breakpoint
# list [LINE | FILE:LINE | FILE:FUNCTION | FUNCTION | *<address> ]
#       - list C source code or disassembly at <address>
# list.
#       - list C source code at current program counter
# ucsim [COMMAND]
#       - invoke µCsim command directly
#
# For more information about SDCDB: https://sourceforge.net/p/sdcc/wiki/Home/
# For more information about µCsim: https://www.ucsim.hu/

namespace eval sdcdb {

variable pipe    0

proc connect {} {
    variable pipe
    # Non-blocking comunication reading
    set pipe [open |[list sdcdb] r+]
    fconfigure $pipe -blocking 0 -buffering line
    fileevent $pipe readable [list handle_output $pipe]
    puts "SDCDB process opened."
}

proc handle_output {pipe} {
    if {[fblocked $pipe]} {
        puts "Process closed."
        fileevent $pipe readable {}
    }
    set output ""
    while {![fblocked $pipe]} {
        append output [read $pipe]
    }
    puts -nonewline stderr "output: $output"
    flush stdout
}

proc send_command {cmd} {
    puts "send_command called"
    variable pipe
    if {$pipe eq 0} {
        error "SDCDB connection not found, call connect first."
    }
    puts $pipe $cmd
    flush $pipe
}

proc disconnect {} {
    variable pipe
    if {$pipe eq 0} {
        error "SDCDB connection not found, call connect first."
    }
    close $pipe
    puts "SDCDB process closed."
    set pipe 0
}

proc test {} {
    variable pipe
    open_comm
    send_command [list touch c]
    after time 1 [list send_command [list touch a]]
    after time 2 [list send_command [list touch b]]
    after time 3 [list send_command [list ls]]
    after time 5 [list send_command [list exit]]
}

namespace export sdcdb

}

#namespace import sdcdb::*
