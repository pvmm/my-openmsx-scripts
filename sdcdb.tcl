# SDCDB Debugger in Tcl - Version 1.0
#
# Copyright 2025 Pedro de Medeiros all rights reserved
#
# A debugger written in Tcl that uses `SDCC --debug` parameter to create breakpoints and much more.
#
# The main difference between SDCC Debugger's breakpoints and the built-in OpenMSX
# breakpoints is the C code integration:
# [*] allow users to create breakpoints on C code:
#     > sdcdb break main.c:55
# [*] list C source code at line 100:
#     > sdcdb list main.c:100
# [*] and more things to come (WIP).
# 
# Commands that the SDCDB Debugger recognizes directly. You may call them with sdcdb [COMMAND] [ARGS...]:
#
# open path_to_CDB_file
#       - Read CDB file specified by a path parameter
# adddir path_to_source_dir
#       - Scan directory for C source file
# reload on|off|now
#       - Turns on or off checking if CDB file has changed on disk every 10 seconds
#         or force a reload.
# quit
#       - close CDB file and free all used memory
# break line
#       - creates breakpoint in <file>:<line>
# list ?line?
#       - list source code at <file>:<line>[-<line>]
# step
#       - Executes one line of C code.
# next
#       - Executes one line of C code, proceeding through subroutine calls.
#
# For more information about the CDB file format: https://sourceforge.net/p/sdcc/wiki/Home/

namespace eval sdcdb {

set ::env(DEBUG) 1
variable ucsim   {}
variable target  {}
variable pipe    0
variable sdcdb   sdcdb  ;# path to sdcdb
variable message ""
variable context none
variable srcpath .
variable context {}
variable command        ;# last command sent to debugger
variable empty   0      ;# last response was empty?

# new vars
variable c_files        ;# pool of c source files
variable c_files_ref    ;# C files reference
variable asm_files_ref  ;# ASM files reference
variable cdb_path
variable cdb_file
variable mem            ;# find source from address

set_help_proc sdcdb [namespace code sdcdb_help]
proc sdcdb_help {args} {
        if {[llength $args] == 1} {
                return {The cdb reader script connects OpenMSX to the CDB file created by SDCC.
Recognized commands: open, adddir, reload, break, list, quit
}
        }
        switch -- [lindex $args 1] {
                "open" { return {Open CDB file and start debugging session.

Syntax: sdcdb open path_to_cdb_file
}}
                "add_dir" { return {Scan directory for source files.

Syntax: sdcdb add_dir dir

dir is a directory that will be scanned for source code.
}}
                "reload" { return {Turn on/off file checking.
Turn on/off checking if CDB file has changed and reload it if true. A 'now' parameter can be specified and it forces reloading instanteneously.

Syntax: cdb reload on|off|now
}}
                "break" { return {Creates a breakpoint.
Create a OpenMSX breakpoint, but using the a C source file as reference.

Syntax: sdcdb break file:line

file:line where the breakpoint will be created.
}}
                "list" { return {Lists contents of a C source file.

Syntax: sdcdb list file:line
}}
                "list." { return {Lists contents of C source at the PC register.

Syntax: sdcdb list.
}}
                "quit" { return {Close CDB file and free all memory.

Syntax: sdcdb quit
}}
}
}

proc output {args} {
    set chan stdout
    if {[llength $args] == 1} {
        puts $chan [lindex $args 0]
    } else {
        puts [lindex $args 0] $chan [lindex $args 1]
    }
    flush $chan
}

proc warn {msg} {
    if {[env DEBUG]} {
        set chan stderr
        set msg [string map {"\n" "\\n"} $msg]
        puts $chan $msg
        flush $chan
    }
}

proc env {varname {defaults {}}} {
    if {[info exists ::env($varname)]} {
        return $::env($varname);
    }
    return $defaults;
}

proc sdcdb {args} {
    if {[env DEBUG]} {
        if {[catch {dispatcher {*}$args} fid]} {
            puts stderr $::errorInfo
            error $::errorInfo
        }
    } else {
        dispatcher {*}$args
    }
    return
}

proc dispatcher {args} {
    set params "[lrange $args 1 end]"
    switch -- [lindex $args 0] {
        "open"       { return [sdcdb_open       {*}$params] }
        "adddir"     { return [sdcdb_adddir     {*}$params] }
        "reload"     { return [sdcdb_reload     {*}$params] }
        "break"      { return [sdcdb_break      {*}$params] }
        "list"       { return [sdcdb_list       {*}$params] }
        "list."      { return [sdcdb_list.      {*}$params] }
        "step"       { return [sdcdb_step       {*}$params] }
        "quit"       { return [sdcdb_quit       {*}$params] }
        default      { error "Unknown command \"[lindex $args 0]\"." }
    }
}

proc file_in_path {program} {
    foreach dir [split $::env(PATH) ":"] {
        set path [file join $dir $program]
        # check if it is a file and has executable permission
        if {[file isfile $path] && [file executable $path]} {
            return $path
        }
    }
    return {}
}

proc sdcdb_select {path {msg {}}} {
    variable pipe
    if {$pipe ne 0} {
        error "connection already established"
    }
    variable sdcdb
    if {[file exists $path] && [file executable $path]} {
        set sdcdb $path
        return
    }
    if {$msg eq {}} {
        set msg "SDCDB binary \"$path\" not found in PATH"
    }
    if {[file dirname $path] eq "."} {
        set tmp [file_in_path $path]
        if {$tmp ne {}} {
            set sdcdb $tmp
            return
        }
    }
    error $msg
}

proc sdcdb_open {path} {
    set file [glob -type f -directory $path *.cdb]
    if {[llength $file] ne 1} {
        error "unique and valid CDB file not found"
    }
    variable cdb_path $path
    variable cdb_file $file
    set cdb [file join $path $file]
    debug "reading $cdb..."
    read_cdb $cdb
}

proc read_cdb {cdb} {
    variable c_files_ref
    set fh [open cdb "r"]]
    # search for "L:C$filename$line$level$block$endAddress" lines
    set pattern {L:C\$([^$]+)\$([^$]+)\$([^$]+)\$([^$]+)\$:(\W+)}
    while {[gets $file line] != -1} {
        set match [regexp $pattern $line]
        if {[llength $match] > 1} {
            lassign $match filename linenum {} {} endAddress
            incr c_files_ref($filename)
            if {$c_files_ref($filename) eq 1} { debug "Added C file '$filename'" }
            variable c_$filename($linenum) $endAddress
	    variable mem($endAddress) { file $filename line $linenum }
            debug "$filename: added line $linenum: $endAddress"
        }
        incr count
    }
    close $fh
    debug "[llength c_files_ref] C files added"
    debug "$count lines found"
}

proc sdcdb_addsrc {path} {
    set new_files [glob -type f -directory $path *.c]
    variable c_files
    lappend c_files {*}$new_files
}

proc sdcdb_list {arg} {
    set pattern {([^:]+):(\d+)?(-(\d+))}
    set match [regexp -inline $pattern $arg]
    if {[llength $match] > 1} {
        lassign $match file start end
        list_file $file $start $end
    } else {
        error "syntax error"
    }
}

proc sdcdb_list. {} {
    # TODO: scan mem near PC to find C source file and lineno.
}

proc list_file {file start {end {}} {
    variable c_files
    set index [lsearch $c_files $file]
    if {$index eq -1}
        error "file not found in source list, add a directory that contains such file with 'sdcdb addsrc <dir>'"
    }
    # TODO: list file source
}

proc sdcdb_connect {args} {
    variable sdcdb
    variable srcpath
    sdcdb_select $sdcdb "Use \"sdcdb select <path>\" to point to the SDCDB binary"
    output "Opening SDCDB process..."
    variable pipe
    if {[llength $args] == 1} {
        set target [lindex $args 0]
    } elseif {[llength $args] == 2} {
        lassign $args srcpath target
    } else {
        error "wrong # args: should be connect ?src? target"
    }
    variable command [list $sdcdb -v -mz80 --directory=$srcpath $target -z -b]
    warn "command: $command"
    variable context connection
    set pipe [open |$command [list RDWR NONBLOCK]]
    fconfigure $pipe -blocking 0 -buffering line
    fileevent $pipe readable [list sdcdb::handle_output]
}

proc handle_output {} {
    variable pipe
    if {[eof $pipe]} {
        output "SDCDB process died."
        fileevent $pipe readable {}
        close $pipe
        variable pipe 0
        return
    }
    set response [read $pipe]
    set response [string trimright $response "(sdcdb) "]
    set response [string trimright $response "\n"]
    variable empty
    variable command
    if {$response ne {}} {
        warn "response: {$response}"
        set empty 0
    } elseif {$response eq $command} {
        warn "response: *repeat*"
        return
    } elseif {$empty eq 0} {
        warn "response: *empty*"
        incr empty
    }
    variable context
    warn "context is $context"
    switch -- $context {
        connection {
            # Look for file "<>.ihx" pattern
            set pattern {file (\S+)}
            set matches [regexp -inline $pattern $response]
            if {[llength $matches] < 2} {
                output "target not found"
                sdcdb_disconnect
                return
            }
            variable target [lindex $matches 1]
            output "$target target found"
            # Look for {\+ (\S+) -P -r 9756} pattern
            set pattern {\+ (\S+)}
            set matches [regexp -inline $pattern $response]
            if {[llength $matches] > 0} {
                variable sdcdb
                set filename [lindex $matches 1]
                warn "$filename simulator expected."
                set path [file dirname $sdcdb]
                # look for ucsim in same directory of sdcdb
                variable ucsim [file join $path $filename]
                if {![file executable $ucsim]} {
                    if {$path eq "."} {
                        output "\"$filename\" simulator not found in PATH"
                    } else {
                        output "\"$filename\" simulator not found in \"$path\""
                    }
                    sdcdb_disconnect
                    return
                } else {
                    output "\"$filename\" simulator found"
                }
                ;#send_command "set opt 8 f"
            } else {
                output "Parser error: simulator name not found"
            }
        }
        break0 {
            # Breakpoint <n> at 0x<address>: file <file>.c, line <line>.
            #set pattern {Breakpoint (\d+) at 0x(\w+): file (\S+), line (\d+).}
            #set matches [regexp -inline $pattern $response]
            set context break1
            send_command "info break"
        }
        break1 {
            # Num Type           Disp Enb Address    What
            # 1   breakpoint     keep y   0x0000480d at main.c:52
            set pattern {(\d+)\s+(\S+)\s+(\S+)\s(\S)\s+0x(\S+) at ([^:]+):(\d+)}
            set matches [regexp -inline $pattern $response]
            if {[llength $matches] > 0} {
                lassign $matches {} bpnum {} {} {} address file line
                output "[debug set_bp "0x$address"]: breakpoint at 0x$address"
            } else {
                set context none
                output "Parser error: breakpoint not found"
                return
            }
            set context break2
            send_command "d$bpnum"
        }
        break2 {
            set pattern {Deleted breakpoint (\d+)}
            set matches [regexp -inline $pattern $response]
            if {![llength $matches]} {
                output "Parser error: breakpoint not found"
            }
            set context none
        }
        output {
            if {$response ne {}} {
                output $response
            }
            set context none
        }
        debug {
            if {$response ne {}} {
                warn $response
            }
            set context none
        }
        default {
            set context none
        }
    }
}

proc send_command {cmd} {
    warn "send_command($cmd)"
    variable pipe
    if {$pipe eq 0} {
        error "SDCDB connection not found, call connect first."
    }
    if {[catch {puts $pipe [string trimright $cmd "\n"]; flush $pipe} err]} {
        output "Error sending command: $err"
    }
    variable command $cmd
}

proc sdcdb_disconnect {} {
    variable pipe
    if {$pipe eq 0} {
        error "SDCDB connection not found, call connect first."
    }
    fileevent $pipe readable {}
    close $pipe
    output "SDCDB process closed."
    set pipe 0
}

proc sdcdb_break {arg} {
    set pattern {([^:]+):(\d+)}
    set matches [regexp -inline $pattern $arg]

    if {[llength $matches] > 0} {
        variable context break0
        send_command [list break $arg]
    } else {
        error "error parsing break command"
    }
}

proc sdcdb_ucsim {args} {
    variable context output
    send_command ![join $args]
}

# direct access to send_command
proc sdcdb_sc {args} {
    variable context output
    send_command [join $args]
}

namespace export sdcdb
#namespace emsemble create

}

# Import sdcdb exported functions
namespace import sdcdb::*
