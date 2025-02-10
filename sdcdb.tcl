# SDCDB Debugger in Tcl - Version 0.6
#
# Copyright 2025 Pedro de Medeiros all rights reserved
#
# A debugger written in Tcl that uses `SDCC --debug` parameter to create breakpoints and much more.
#
# The main difference between SDCC Debugger's breakpoints and the built-in OpenMSX breakpoints is the
# C code integration:
# [*] allow users to create breakpoints on C code:
#     > sdcdb break main.c:55
# [*] list C source code at line 100:
#     > sdcdb list main.c:100
# [*] and more things to come (WIP).
# 
# All commands that the SDCDB Debugger recognizes directly. You may call them with sdcdb [COMMAND] [ARGS...]:
#
# open path_to_CDB_file
#       - Read CDB file specified by a path parameter
# add path_to_source_dir
#       - Scan directory for C source files
# reload on|off|now
#       - Turns on or off checking if CDB file has changed on disk every 10 seconds
#         or force a synchronous reload.
# break line
#       - creates breakpoint in <file>:<line>
# list ?line?
#       - list source code at <file>:<line>[-<line>]
# step ?n?
#       - Executes next n lines of C code step by step, proceeding through subroutine calls.
#         n defaults to 1.
# next ?n?
#       - Executes next n lines of C code, not following subroutine calls. n defaults to 1.
# info ?-break?
#       - Display information on source code under the program counter. The -break
#         parameter stops execution.
# quit
#       - close CDB file and free all used memory
#
# For more information about the CDB file format: https://sourceforge.net/p/sdcc/wiki/Home/

namespace eval sdcdb {

set ::env(DEBUG) 1
variable c_files_count          ;# C files reference
array set c_files     {}        ;# pool of c source files
array set addr2file   {}        ;# array that maps source from address
array set g_file2addr {}        ;# array that maps address from source (global)
# array set <filename>2addr     ;# same, but dinamically created array for each SDCC module (C file)

set_help_proc sdcdb [namespace code sdcdb_help]
proc sdcdb_help {args} {
    if {[llength $args] == 1} {
        return {The SDCDB debugger in Tcl connects OpenMSX to the CDB file created by SDCC.

Recognized commands: open, add, reload, break, list, next, step, info, quit

Type 'help sdcdb <command>' for more information about each command.
}
    }
    switch -- [lindex $args 1] {
        "open" { return {Opens CDB file and start debugging session

Syntax: sdcdb open <pathToCDBFile>
}}
        "add" { return {Adds directory to be scanned for source files

'dir' is the path to a directory that will be scanned for more source files to be added to the database.

Syntax: sdcdb add <dir>
}}
        "reload" { return {Turns on/off file checking

Turn on/off checking if CDB file has changed and reload it if true. A 'now' parameter can be specified and it forces instanteneous reloading.

Syntax: cdb reload on|off|now
}}
        "break" { return {Creates a breakpoint

Create a OpenMSX breakpoint, but using the C source files as reference. 'sdcdb info -break' replaces 'debug break' for extra details about C code execution.

Syntax: sdcdb break <file>:<line>
        sdcdb break <file>:<functionName>
        sdcdb break <functionName>
}}
        "list" { return {Lists contents of a C source file

Without parameters, 'sdcdb list' returns the C source code under the PC register.

Syntax: sdcdb list <file>:<line>
        sdcdb list <file>:<functionName>
        sdcdb list <functionName>
}}
        "next" { return {Executes next n lines of C code

The 'sdcdb next' command will not proceed through subroutine calls. You may specify how many times 'sdcdb next' should execute (defaults to 1).

Syntax: sdcdb next ?n?
}}
        "step" { return {Steps through next n lines of C code

The 'sdcdb step' command will proceed through subroutine calls. You may specify how many times 'sdcdb step' should execute (defaults to 1).

Syntax: sdcdb step ?n?
}}
        "info" { return {Displays information about current line of source code

A '-break' parameter stops execution after displaying the information.

Syntax: sdcdb info ?-break?
}}
        "quit" { return {Closes files and frees all memory.

Syntax: sdcdb quit}}
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
        if {[catch {set result [dispatcher {*}$args]} fid]} {
            puts stderr $::errorInfo
            error $::errorInfo
        }
    } else {
        set result [dispatcher {*}$args]
    }
    return $result
}

proc dispatcher {args} {
    set params "[lrange $args 1 end]"
    set cmd [lindex $args 0]
    switch -- $cmd {
        "open"  { return [sdcdb_open       {*}$params] }
        add     { return [sdcdb_add        {*}$params] }
        quit    { return [sdcdb_quit       {*}$params] }
    }
    # remaining commands need initialization
    variable c_files_count
    if {![info exists c_files_count]} {
        error "SDCDB not initialized"
    }
    switch -- $cmd {
        reload  { return [sdcdb_reload     {*}$params] }
        "break" { return [sdcdb_break      {*}$params] }
        "list"  { return [sdcdb_list       {*}$params] }
        "next"  { return [sdcdb_next       {*}$params] }
        step    { return [sdcdb_step       {*}$params] }
        "info"  { return [sdcdb_info       {*}$params] }
        default { error "Unknown command \"[lindex $args 0]\"." }
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

proc sdcdb_open {path} {
    set file [glob -type f -directory $path *.cdb]
    if {[llength $file] ne 1} {
        error "unique regular CDB file not found"
    }
    warn "reading $file..."
    read_cdb $file
}

proc complete {arrayname name list} {
    upvar $arrayname var
    if {![info exists var($name)]} { warn "$arrayname\($name\) ignored"; return 0 }
    set var($name) [concat {*}$var($name) {*}$list]
    return 1
}

proc read_cdb {fname} {
    variable c_files_count
    variable addr2file
    set fh [open $fname "r"]
    # function pattern: search for "F:G$function_name$..." lines
    # 'F:G$debug_break$0_0$0({2}DF,SV:S),Z,0,0,0,0,0'
    set func_pat {^F:(G|F([^$]+)|L([^$]+))\$([^$]+)\$.*}
    # line number pattern: search for "L:C$filename$line$level$block:address" lines
    set line_pat {^L:C\$([^$]+)\$([^$]+)\$([^$]+)\$([^$]+):(\S+)$}
    # function begin pattern: search for "L:(G|F<name>|L<name>)$function$level$block:address" lines
    set func_bn_pat {^L:(G|F([^$]+)|L([^$]+))\$([^$]+)\$([^$]+)\$([^$]+):(\S+)$}
    # function end pattern: search for "L:X(G|F<name>|L<name>)$function$level$block:address" lines
    set func_ed_pat {^L:X(G|F([^$]+)|L([^$]+))\$([^$]+)\$([^$]+)\$([^$]+):(\S+)$}
    set c_count 0  ;# lines of C code
    set gf_count 0 ;# global functions
    set sf_count 0 ;# static functions
    while {[gets $fh line] != -1} {
        set match [regexp -inline $func_pat $line]
        if {[llength $match] == 5} {
            lassign $match {} context {} {} funcname
            switch -- [string index $context 0] {
                G {
                    variable g_file2addr
                    set g_file2addr($funcname) {}
                    warn "g_file2addr\($funcname\) created"
                }
                F {
                    set arrayname [string range $context 1 [string length $context]]2addr
                    upvar ${arrayname} var
                    variable var
                    set var($funcname) {}
                    warn "${arrayname}\($funcname\) created"
                }
                L {
                    ;#error "not implemented yet '$line' \[1\]"
                }
            }
            continue
        }
        set match [regexp -inline $line_pat $line]
        if {[llength $match] == 6} {
            lassign $match {} filename linenum {} {} address
            incr c_files_count($filename)
            if {$c_files_count($filename) eq 1} { warn "Added C file '$filename'" }
            # Put line -> address mapping of array with dynamic name
            set arrayname [file rootname $filename]2addr
            upvar ${arrayname} var
            variable var
            set var($linenum) $address
            set addr2file($address) { file $filename line $linenum }
            warn "${arrayname}\($linenum\): $var($linenum)"
            incr c_count
            continue
        }
        set match [regexp -inline $func_bn_pat $line]
        if {[llength $match] == 8} {
            lassign $match {} context {} {} funcname {} {} address
            #warn "func_bn_pat found at '$line': $context, $funcname, $address"
            # Put function begin record in array with dynamic name
            switch -- [string index $context 0] {
                G {
                    variable g_file2addr
                    if {[complete g_file2addr $funcname [list begin $address]]} {
                        warn "g_file2addr\($funcname\): $g_file2addr($funcname)"
                        incr gf_count
                    }
                }
                F {
                    set arrayname [string range $context 1 [string length $context]]2addr
                    upvar ${arrayname} var
                    variable var
                    if {[complete var $funcname [list begin $address]]} {
                        warn "${filename}2addr\($funcname\): $var($funcname)"
                        incr sf_count
                    }
                }
                L {
                    ;#error "not implemented yet '$line' \[2\]"
                }
            }
            continue
        }
        set match [regexp -inline $func_ed_pat $line]
        if {[llength $match] == 8} {
            lassign $match {} context {} {} funcname {} {} address
            # Put function end record in array with dynamic name
            switch -- [string index $context 0] {
                G {
                    variable g_file2addr
                    if {[complete g_file2addr $funcname [list end $address]]} {
                        warn "X: g_file2addr\($funcname\): $g_file2addr($funcname)"
                    }
                }
                F {
                    set arrayname [string range $context 1 [string length $context]]2addr
                    upvar ${arrayname} var
                    global var
                    if {[complete var $funcname [list end $address]]} {
                        warn "X: ${arrayname}\($funcname\): $var($funcname)"
                    }
                }
                L {
                    ;#error "not implemented yet '$line' \[3\]"
                }
            }
            continue
        }
        ;#warn "Ignored '$line'"
    }
    close $fh
    output "[array size c_files_count] C files references added"
    output "$c_count C source lines found"
    output "$gf_count global function(s) registered"
    output "$sf_count static function(s) registered"
}

proc sdcdb_add {path} {
    set new_files [glob -type f -directory $path *.c]
    warn "adding files: [join $new_files {, }]"
    variable c_files
    foreach path $new_files {
        set filename [file tail $path]
        if {[array get c_files $filename] ne {}} {
            warn "file '$filename' already registered, new entry ignored."
        }
        set c_files($filename) $path
    }
}

proc sdcdb_list {arg} {
    set pattern1 {([^:]+):(\d+)?(-(\d+))}
    set pattern2 {([^:]+):(\S+)}
    set pattern3 {(\S+)}
    set match [regexp -inline $pattern1 $arg]
    if {[llength $match] == 4} {
        lassign $match {} filename start end
        return list_file $filename $start $end
    }
    set match [regexp -inline $pattern2 $arg]
    if {[llength $match] == 3} {
        lassign $match {} filename funcname
        # TODO: list_function
    }
    set match [regexp -inline $pattern3 $arg]
    if {[llength $match] == 2} {
        lassign $match {} funcname
        # TODO: list_function
    }
    # TODO: scan addr2file near PC to find C source file and lineno.
}

proc list_file {file start {end {}}} {
    variable c_files
    if {[array get c_files $file] eq {}} {
        error "file not found in source list, add a directory that contains such file with 'sdcdb add <dir>'"
    }
    # TODO: open file and list its source line by line at [start:end]
}

# scan file database then global database for function name
proc scanfunc {filename funcname} {
    set arrayname [file rootname $filename]2addr
    upvar ${arrayname} var
    variable var
    if {![info exists var]} {
        error "source file not found"
    }
    set record [array get var $funcname]
    if {$record eq {}} {
        # not found in file, search globally
        variable g_file2addr
        set record [array get g_file2addr $funcname]
    }
    return [eval list [lindex $record 1]]
}

# reverse function search (global first, then search all files)
proc scanfunc_r {funcname} {
    variable g_file2addr
    set record [array get g_file2addr $funcname]
    if {$record eq {}} {
        foreach filename c_files {
            set arrayname [file rootname $filename]2addr
            upvar ${arrayname} var
            variable var
            if {[info exists var($funcname)]} {
                set record [array get var $line]
                break
            }
        }
    }
    return [lindex $record 1]
}

proc scanline {file line} {
    set arrayname [file rootname $file]2addr
    upvar ${arrayname} var
    variable var
    if {![info exists var]} {
        error "source file not found"
    }
    set record [array get var $line]
    if {$record eq {}} {
        error "line $line not found in file '$file'"
    }
    return [lindex $record 1]
}

proc sdcdb_break {pos {cond {}} {cmd {sdcdb info -break}}} {
    set pattern1 {([^:]+):(\d+)}
    set pattern2 {([^:]+):(\S+)}
    set pattern3 {(\S+)}
    set match [regexp -inline $pattern1 $pos]
    if {[llength $match] == 3} {
        lassign $match {} filename linenum
        set address [scanline $filename $linenum]
        if {$address ne {}} {
            return [debug breakpoint create -address $address -condition $cond -command $cmd]
        } else {
            error "address not found"
        }
    }
    set match [regexp -inline $pattern2 $pos]
    if {[llength $match] == 3} {
        lassign $match {} filename funcname
        set address [scanfunc $filename $funcname]
        if {$address ne {}} {
            return [debug breakpoint create -address $address -condition $cond -command $cmd]
        } else {
            error "function not found"
        }
    }
    set match [regexp -inline $pattern3 $pos]
    if {[llength $match] == 2} {
        lassign $match {} funcname
        set address [scanfunc_r $funcname]
        if {$address eq {}} {
            error "function not found"
        }
        return [debug breakpoint create -address $address -condition $cond -command $cmd]
    } else {
        error "error parsing break command"
    }
}

proc sdcdb_next {{times 1}} {
    debug break  ;# just to be sure
    for {set i $times} {$i > 0} {decr i} {
        do_debug_step over
    }
}

proc sdcdb_step {{times 1} {next {}}} {
    debug break  ;# just to be sure
    for {set i $times} {$i > 0} {decr i} {
        do_debug_step in
    }
}

proc do_debug_step {{type {}}} {
    variable addr2file
    set once 0
    if {[array get addr2file [reg pc] ne {}} {
        lassign $addr2file($address) {} file {} line
        set count 0
        while {new_file eq file && new_line eq line} {
            if {$type eq over} { step over } else { step in }
            lassign $addr2file([rec pc]) {} new_file {} new_line
            incr count
            if {new_line eq {} && !$once} {
                output "no debug information at this level, skipping until there is."
                incr once
            }
        }
        output "$count ML instructions passed"
    } else {
        output "no debug information at this level, stopping."
    }
}

proc sdcdb_info {arg} {
    variable addr2file
    set address [reg pc]
    if {[array get addr2file $pc] ne {}} {
        lassign $addr2file($pc) filename linenum
        if {[array get c_files $filename] eq {}} {
            error "Cannot localize source code file: '$filename' missing. Use 'sdcdb add <path>' to add more source files to the database."
        }
        sdcdb_list linenum
    } else {
        error "address mapping not found for 0x[format %04x $address]"
    }
    if {arg eq "-break"} {
        debug break
    }
}

proc sdcdb_quit {} {
    variable c_files
    if {[info exists c_files]} {
        foreach filename c_files {
            set arrayname [file rootname $filename]2addr
            upvar ${arrayname} var
            variable var
            unset var
        }
        unset c_files
        variable c_files_count
        unset c_files_count
        variable addr2file
        unset addr2file
        variable g_file2addr
        unset g_file2addr
        output "done"
    }
}

namespace export sdcdb
#namespace emsemble create

}

# Import sdcdb exported functions
namespace import sdcdb::*
