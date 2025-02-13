# SDCDB Debugger in Tcl - Version 0.8
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
# add ?-recursive? path_to_source_dir
#       - Scan directory for C source files
# break line
#       - creates breakpoint in <file>:<line>
# list ?line?
#       - list source code at <file>:<line>[-<line>]
# info ?-break?
#       - Display information on source code under the program counter. The -break
#         parameter stops execution.
# step ?n?
#       - Executes next n lines of C code step by step, proceeding through subroutine calls.
#         n defaults to 1.
# quit
#       - Free all used memory.
#
# Known limitations:
# [*] don't create C files with same name in different folders (in projects with multiple
#     folders), since CDB files don't keep track of directories, just file names. SDCDB
#     will get lost and report the wrong position because of missing files during break or
#     step.
# [*] don't create projects with assembly and C files with the same name, since SDCC
#     already creates an .asm file for every .c file in your project. SDCDB will get lost
#     and report the wrong position because of missing files during break or step.
#
# For more information about the CDB file format: https://sourceforge.net/p/sdcc/wiki/Home/

namespace eval sdcdb {

variable initialized    0
variable c_files_count                  ;# C files reference
variable a_files_count                  ;# ASM files reference
array set c_files       {}              ;# pool of c source files
array set a_files       {}              ;# pool of a source files
array set addr2file     {}              ;# array that maps to source from address
array set g_func2addr   {}              ;# array that maps to address from source (global)
# array set c_<filename>2addr           ;# same, but dinamically created array for each SDCC module (C file)
# array set a_<filename>2addr           ;# same, but dinamically created array for each SDCC module (ASM file)
# array set <filename>_func2addr        ;# array that maps function to source (static)
variable current_file   {}              ;# debugger file
variable current_line   {}              ;# debugger line
variable cond           {}              ;# breakpoint check condition
variable old_PC         {}
variable times_left     0
proc ASM {} { return ".asm" }

set_help_proc sdcdb [namespace code sdcdb_help]
proc sdcdb_help {args} {
    if {[llength $args] == 1} {
        return {The SDCDB debugger in Tcl connects OpenMSX to the CDB file created by SDCC.

Recognized commands: open, add, break, list, step, next, info, whereis, laddr, map, quit

Type 'help sdcdb <command>' for more information about each command.
}
    }
    switch -- [lindex $args 1] {
        "open" { return {Opens CDB file and start debugging session

Syntax: sdcdb open <pathToCDBFile>
}}
        "add" { return {Adds directory to be scanned for source files

'dir' is the path to a directory that will be scanned for more source files to be added to the source database. -recursive may be specified to also look for files in subdirectories. You must call 'sdcdb add' with all files you want to include before you call 'sdcdb open' on the CDB file.

Syntax: sdcdb add ?-recursive? <dir>
}}
        "break" { return {Creates a breakpoint

Create a OpenMSX breakpoint, but using the C source files as reference. 'sdcdb info -break' replaces 'debug break' for extra details about C code execution.

Syntax: sdcdb break <file>:<line>
        sdcdb break <file>:<functionName>
        sdcdb break <functionName>
}}
        "list" { return {Lists contents of a C source file

Without parameters, 'sdcdb list' returns the C/assembly source code under the PC register. Obs.: assembly function names are not recognized.

Syntax: sdcdb list
        sdcdb list <file>:<line>
        sdcdb list <file>:<functionName>
        sdcdb list <functionName>
}}
        "laddr" { return {Lists contents of C/assembly source code in a specified memory address

Syntax: sdcdb laddr mem
}}
        "step" { return {Steps through next n lines of C code

The 'sdcdb step' command will proceed through subroutine calls. You may specify how many times 'sdcdb step' should execute (defaults to 1).

Syntax: sdcdb step ?n?
}}
        "next" { return {Executes next n lines of C code

The 'sdcdb next' command will not proceed through subroutine calls. You may specify how many times 'sdcdb next' should execute (defaults to 1).

Syntax: sdcdb next ?n?
}}
        "info" { return {Displays information about current line of source code

A '-break' parameter stops execution after displaying the information.

Syntax: sdcdb info ?-break?
}}
        "whereis" { return {Displays if source file was found in the database

Syntax: sdcdb whereis <sourceFileName>
}}
        "map" { return {Returns memory address from a C/assembly file line

Basically a dry-run version of 'sdcdb break'. If a functionName is used, it returns the beginning and ending address of the function.

Syntax: sdcdb map <file>:<line>
        sdcdb map <file>:<functionName>
        sdcdb map <functionName>
}}
        "quit" { return {Closes files and frees all memory.

Syntax: sdcdb quit}}
    }
}

proc debug_out {args} {
    variable debug
    if {$debug} {
        set chan stderr
        set msg [string map {"\n" "\\n"} [join $args " "]]
        puts $chan $msg
        flush $chan
    }
}

proc sdcdb {args} {
    if {[catch {set result [dispatcher {*}$args]} msg]} {
        variable debug
        if {$debug} {
            puts stderr $::errorInfo
        }
        error $msg
    }
    return $result
}

proc dispatcher {args} {
    set params "[lrange $args 1 end]"
    set cmd [lindex $args 0]
    switch -- $cmd {
        open    { return [sdcdb_open       {*}$params] }
        add     { return [sdcdb_add        {*}$params] }
        quit    { return [sdcdb_quit       {*}$params] }
    }
    # remaining commands need initialization
    variable initialized
    if {!$initialized} {
        error "You need a CDB file to use this command. Use the 'sdcdb open' command first"
    }
    switch -- $cmd {
        break   { return [sdcdb_break      {*}$params] }
        list    { return [sdcdb_list       {*}$params] }
        info    { return [sdcdb_info       {*}$params] }
        step    { return [sdcdb_step       {*}$params] }
        next    { return [sdcdb_next       {*}$params] }
        whereis { return [sdcdb_whereis    {*}$params] }
        laddr   { return [sdcdb_laddr      {*}$params] }
        map     { return [sdcdb_map        {*}$params] }
        default { error "Unknown command \"[lindex $args 0]\"." }
    }
}

proc sdcdb_open {path} {
    variable initialized
    if {$initialized} {
        sdcdb::quit
    }
    set file [glob -type f -directory $path *.cdb]
    if {[llength $file] ne 1} {
        error "unique regular CDB file not found"
    }
    sdcdb_add -recursive $path
    read_cdb $file
    set initialized 1
    process_data
}

proc complete {arrayname name list} {
    variable $arrayname
    if {![info exists ${arrayname}($name)]} {
        debug_out "$arrayname\($name\) ignored"; return 0
    }
    set ${arrayname}($name) [concat {*}[set ${arrayname}($name)] {*}$list]
    return 1
}

proc read_cdb {fname} {
    variable c_files_count
    variable addr2file
    set fh [open $fname "r"]
    # function pattern: search for "F:G$function_name$..." lines
    set func_pat {^F:(G|F([^$]+)|L([^$]+))\$([^$]+)\$.*}
    # ASM line number pattern: search for "L:A$filename$line:address" lines
    set aline_pat {^L:A\$([^$]+)\$([^$]+):([^$]+)$}
    # C line number pattern: search for "L:C$filename$line$level$block:address" lines
    set cline_pat {^L:C\$([^$]+)\$([^$]+)\$([^$]+)\$([^$]+):(\S+)$}
    # function begin pattern: search for "L:(G|F<name>|L<name>)$function$level$block:address" lines
    set func_bn_pat {^L:(G|F([^$]+)|L([^$]+))\$([^$]+)\$([^$]+)\$([^$]+):(\S+)$}
    # function end pattern: search for "L:X(G|F<name>|L<name>)$function$level$block:address" lines
    set func_ed_pat {^L:X(G|F([^$]+)|L([^$]+))\$([^$]+)\$([^$]+)\$([^$]+):(\S+)$}
    set c_count 0  ;# lines of C code
    set a_count 0  ;# lines of asm code
    set gf_count 0 ;# global functions
    set sf_count 0 ;# static functions
    while {[gets $fh line] != -1} {
        set match [regexp -inline $func_pat $line]
        if {[llength $match] == 5} {
            lassign $match {} context {} {} funcname
            switch -- [string index $context 0] {
                G {
                    variable g_func2addr
                    set g_func2addr($funcname) {}
                    debug_out "g_func2addr\($funcname\) created"
                }
                F {
                    set arrayname [string range $context 1 [string length $context]]_func2addr
                    variable $arrayname
                    set ${arrayname}($funcname) {}
                    debug_out "${arrayname}\($funcname\) created"
                }
                L {}
            }
            continue
        }
        set match [regexp -inline $cline_pat $line]
        if {[llength $match] == 6} {
            lassign $match {} filename linenum {} {} address
            incr c_files_count($filename)
            # Put line -> address mapping of array with dynamic name
            set arrayname c_[file rootname $filename]2addr
            if {$c_files_count($filename) eq 1} {
                debug_out "Created new dynamic array $arrayname"
            }
            variable $arrayname
            set ${arrayname}($linenum) [expr {"0x$address"}]
            set addr2file([expr {"0x$address"}]) [list $filename $linenum]
            debug_out "mapping C source ${arrayname}\($linenum\): [set ${arrayname}($linenum)]"
            incr c_count
            continue
        }
        set match [regexp -inline $aline_pat $line]
        if {[llength $match] == 4} {
            lassign $match {} filename linenum address
            incr a_files_count($filename[ASM])  ;# SDCC removes the file extension for some reason
            # Put line -> address mapping of array with dynamic name
            set arrayname a_[file rootname $filename]2addr
            if {$a_files_count($filename[ASM]) eq 1} {
                debug_out "Created new dynamic array $arrayname"
            }
            variable $arrayname
            set ${arrayname}($linenum) [expr {"0x$address"}]
            # Is it possible for assembly to override the C mappings?
            set addr2file([expr {"0x$address"}]) [list $filename[ASM] $linenum]
            debug_out "mapping asm source ${arrayname}\($linenum\): [set ${arrayname}($linenum)]"
            incr a_count
            continue
        }
        set match [regexp -inline $func_bn_pat $line]
        if {[llength $match] == 8} {
            lassign $match {} context {} {} funcname {} {} address
            # Put function begin record in array with dynamic name
            switch -- [string index $context 0] {
                G {
                    variable g_func2addr
                    if {[complete g_func2addr $funcname [list [expr {"0x$address"}]]]} {
                        debug_out "1:mapping function g_func2addr\($funcname\): [set g_func2addr($funcname)]"
                        incr gf_count
                    }
                }
                F {
                    set arrayname [string range $context 1 [string length $context]]_func2addr
                    variable $arrayname
                    if {[complete $arrayname $funcname [list [expr {"0x$address"}]]]} {
                        debug_out "1:mapping function ${arrayname}\($funcname\): [set ${arrayname}($funcname)]"
                        incr sf_count
                    }
                }
                L {}
            }
            continue
        }
        set match [regexp -inline $func_ed_pat $line]
        if {[llength $match] == 8} {
            lassign $match {} context {} {} funcname {} {} address
            # Put function end record in array with dynamic name
            switch -- [string index $context 0] {
                G {
                    variable g_func2addr
                    if {[complete g_func2addr $funcname [list [expr {"0x$address"}]]]} {
                        debug_out "mapping function g_func2addr\($funcname\): [set g_func2addr($funcname)]"
                    }
                }
                F {
                    set arrayname [string range $context 1 [string length $context]]_func2addr
                    variable $arrayname
                    if {[complete $arrayname $funcname [list [expr {"0x$address"}]]]} {
                        debug_out "mapping function ${arrayname}\($funcname\): [set ${arrayname}($funcname)]"
                    }
                }
                L {
                }
            }
            continue
        }
        debug_out "Ignored '$line'"
    }
    close $fh
    puts "[array size c_files_count] C files references added"
    puts "[array size a_files_count] assembly files references added"
    puts "$c_count C source lines found"
    puts "$a_count assembly source lines found"
    puts "$gf_count global function(s) registered"
    puts "$sf_count static function(s) registered"
}

proc fix_blank_spaces {arrayname} {
    variable $arrayname 
    set old_key {}
    foreach key [lsort -integer [array names $arrayname]] {
        if {$old_key ne {} && [expr {$key - 1}] != $old_key} {
            for {set i [expr {$old_key + 1}]} {$i < $key} {incr i} {
                #debug "Setting $arrayname\($i\) to ${arrayname}\($old_key\) = [set ${arrayname}($old_key)]"
                set ${arrayname}($i) [set ${arrayname}($old_key)]
            }
        }
        set old_key $key
    }
}

proc fix_last_address {arrayname} {
    variable $arrayname
    set old_key {}
    set sorted [lsort -integer [array names $arrayname]]
    foreach key $sorted {
        if {$old_key ne {} && [set ${arrayname}($old_key)] ne [set ${arrayname}($key)]} {
            set ${arrayname}($old_key) [list [set ${arrayname}($old_key)] [expr {[set ${arrayname}($key)] - 1}]]
        } elseif {$old_key ne {}} {
            set ${arrayname}($old_key) [list [set ${arrayname}($old_key)] [set ${arrayname}($old_key)]]
        }
        set old_key $key
    }
    if {[llength $sorted] > 0} {
        # change last value
        set last [lindex $sorted end]
        set ${arrayname}($last) [list [set ${arrayname}($last)] [set ${arrayname}($last)]]
    }
}

proc process_data {} {
    variable c_files
    foreach filename [array names c_files] {
        set arrayname c_[file rootname $filename]2addr
        variable $arrayname
        fix_last_address $arrayname
        fix_blank_spaces $arrayname
    }
    variable a_files
    foreach filename [array names a_files] {
        set arrayname a_[file rootname $filename]2addr
        variable $arrayname
        fix_last_address $arrayname
        fix_blank_spaces $arrayname
    }
    fix_blank_spaces addr2file
    return
}

proc normal_glob {dir pattern} {
    glob -nocomplain -type f -directory $dir $pattern
}

proc recursive_glob {dir pattern} {
    set result [list]
    foreach file [glob -nocomplain -directory $dir $pattern] {
        lappend result $file
    }
    foreach subdir [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $subdir]} {
            lappend result {*}[recursive_glob $subdir $pattern]
        }
    }
    return $result
}

proc add_files_to_database {arrayname files} {
    variable $arrayname
    foreach path $files {
        set filename [file tail $path]
        if {[array get $arrayname $filename] ne {}} {
            debug_out "file '$filename' already registered in $arrayname, new entry ignored."
        }
        set ${arrayname}($filename) $path
    }
}

proc sdcdb_add {param {path {}}} {
    variable initialized
    if {$initialized} {
        error "CDB file already loaded. Type 'sdcdb quit' before you add more directories"
    }
    if {$param eq "-recursive"} {
        set function recursive_glob
    } else {
        set path $param
        set function normal_glob
    }
    set new_files [$function $path *.c]
    debug_out "adding files: [join $new_files {, }]"
    add_files_to_database c_files $new_files
    set new_files [$function $path *[ASM]]
    debug_out "adding files: [join $new_files {, }]"
    add_files_to_database a_files $new_files
}

proc sdcdb_list {args} {
    # parameter pattern 1: file:beginLine-endLine
    set pattern1 {([^:]+):(\d+)(-(\d+))?}
    # parameter pattern 2: file:functionName
    set pattern2 {([^:]+):(\S+)}
    # parameter pattern 3: functionName
    set pattern3 {(\S+)}
    set arg [lindex $args 0]
    set match [regexp -inline $pattern1 $arg]
    if {[llength $match] == 5} {
        lassign $match {} file start {} end
        return [list_file $file $start $end 0 1]
    }
    set match [regexp -inline $pattern2 $arg]
    if {[llength $match] == 3} {
        lassign $match {} file funcname
        return [list_fun $file $funcname]
    }
    set match [regexp -inline $pattern3 $arg]
    if {[llength $match] == 2} {
        lassign $match {} funcname
        return [list_fun {} $funcname]
    }
    list_pc
}

proc list_file {file begin {end {}} {focus 0} {showerror 0}} {
    if {[file extension $file] eq ".c"} {
        set files c_files
    } elseif {[file extension $file] eq [ASM]} {
        set files a_files
    } else {
        error "Unknown or unspecified file extension"
    }
    variable $files
    set record [array get $files $file]
    if {$record eq {}} {
        if {$showerror} {
            error "file '$file' not found in database, add a directory that contains such file with 'sdcdb add <dir>'"
        }
        puts "$file: not found"
        return
    }
    debug_out "opening file [lindex $record 1]..."
    set fh [open [lindex $record 1] r]
    set pos 0
    # 10 lines by default
    if {$end eq {}} { set end [expr {$begin + 9}] }
    while {[gets $fh line] >= 0} {
        incr pos
        if {$pos >= $begin} {
            puts "[format %-5d $pos][expr {$pos == $focus ? "*" : ":"}]    $line"
        }
        if {$pos >= $end} { break }
    }
    close $fh
}

proc list_pc {{x0 -1} {x1 9}} {
    list_address [reg PC] $x0 $x1 1
}

proc list_address {address {x0 -1} {x1 9} {showerror 0}} {
    variable addr2file
    set address [expr {$address}]
    if {![info exists addr2file($address)]} {
        if {$showerror} {
            error "database address not found for 0x[h $address]"
        }
        return [puts "no file"]
    }
    lassign $addr2file($address) file begin
    list_file $file [expr {$begin + $x0}] [expr {$begin + $x1}] $begin
}

proc sdcdb_laddr {address} {
    list_address $address
}

proc list_fun {filename funcname} {
    lassign [search_func $filename $funcname] begin end
    variable addr2file
    set record [lindex [array get addr2file $begin] 1]
    if {$record eq {}} {
        error "database function '$funcname' not found"
    }
    lassign $record {} lbegin
    lassign [lindex [array get addr2file $end] 1] {} lend
    list_file $filename [expr {$lbegin - 1}] $lend 0 1
}

# scan static file database then global database for function name
proc search_func {filename funcname} {
    # search for static function first
    if {$filename ne {}} {
        set arrayname [file rootname $filename]_func2addr
        variable $arrayname
        if {[info exists ${arrayname}($funcname)]} {
            return [lindex [array get $arrayname $funcname] 1]
        }
    }
    # not a static function in file, searching globally
    variable g_func2addr
    set record [lindex [array get g_func2addr $funcname] 1]
    # Check if filename matches
    if {$filename ne {}} {
        variable addr2file
        lassign [lindex [array get addr2file [lindex $record 0]] 1] tmp
        if {$tmp ne {} && $tmp ne $filename} {
            error "'$funcname' not found in file '$filename' according to database"
        }
    }
    if {$record eq {}} {
        error "'$funcname' not found in file database"
    }
    return $record
}

proc search_file {file line} {
    set tmp [file rootname $file]
    if {[file extension $file] eq ".c"} {
        set arrayname c_${tmp}2addr
        variable c_${tmp}2addr
    } else {
        set arrayname a_${tmp}2addr
        variable a_${tmp}2addr
    }
    if {![info exists $arrayname]} {
        error "'$file': source file not found ($arrayname)"
    }
    set result [array get $arrayname $line]
    if {$result eq {}} {
        error "line $line not found in file '$file'"
    }
    lindex $result 1
}

# recurring pattern
proc map_source_params {pos fun1 fun2 fun3 args} {
    # parameter pattern 1: file:beginLine
    set pattern1 {([^:]+):(\d+)}
    # parameter pattern 2: file:functionName
    set pattern2 {([^:]+):(\S+)}
    # parameter pattern 3: functionName
    set pattern3 {(\S+)}
    set match [regexp -inline $pattern1 $pos]
    if {[llength $match] == 3} {
        return [$fun1 {*}[lrange $match 1 end] {*}$args]
    }
    set match [regexp -inline $pattern2 $pos]
    if {[llength $match] == 3} {
        return [$fun2 {*}[lrange $match 1 end] {*}$args]
    }
    set match [regexp -inline $pattern3 $pos]
    if {[llength $match] == 2} {
        return [$fun3 {*}[lrange $match 1 end] {*}$args]
    }
    # ignore the rest
}

proc sdcdb_map {pos} {
    map_source_params $pos map_fline map_ffunc map_func
}

proc map_fline {filename linenum} {
    search_file $filename $linenum
}

proc map_ffunc {filename funcname} {
    search_func $filename $funcname
}

proc map_func {funcname} {
    search_func {} $funcname
}

proc sdcdb_break {pos {cond {}} {cmd {sdcdb info -break}}} {
    map_source_params $pos break_fline break_ffunc break_func $cond $cmd
}

proc break_fline {filename linenum cond cmd} {
    set record [search_file $filename $linenum]
    if {$record eq {}} {
        error "address not found"
    } else {
        debug breakpoint create -address [lindex $record 1] -condition $cond -command $cmd
    }
}

proc break_ffunc {filename funcname cond cmd} {
    lassign [search_func $filename $funcname] start {}
    if {$start eq {}} {
        error "function not found"
    } else {
        debug breakpoint create -address $start -condition $cond -command $cmd
    }
}

proc break_func {funcname cond cmd} {
    lassign [search_func {} $funcname] start {}
    if {$start eq {}} {
        error "function not found"
    }
    debug breakpoint create -address $start -condition $cond -command $cmd
}

proc check {} {
    variable old_PC
    return [reg PC] != $old_PC
}

proc print_status {file line} {
    puts "file: $file:$line, position: 0x[h [reg PC]]"
    list_pc -1 1
}

proc update_step {{type {step}}} {
    set record [find_source [reg PC]]
    variable current_file
    variable current_line
    if {$record ne {} && $record ne [list $current_file $current_line]} {
        lassign $record current_file current_line
        variable times_left
        incr times_left -1
        if {$times_left <= 0} { print_status $current_file $current_line }
        debug break
    }
    variable times_left
    if {$times_left > 0} {
        # still looping
        after break "sdcdb::update_step $type"
        $type  ;# call "step" or "step_over"
    }
}

proc find_source {address} {
    variable addr2file
    # get current source file
    set record [lindex [array get addr2file [reg PC]] 1]
    return $record
}

proc prepare_step {{n 1}} {
    debug break  ;# just to be sure
    # get current position in source code
    set record [find_source [reg PC]]
    lassign $record file line
    lassign [search_file $file $line] begin end
    debug_out "search_file: $file, $line -> [search_file $file $line]"
    if {$begin ne {} && $end ne {}} {
        variable current_file $file
        variable current_line $line
    } else {
        puts "Possibly out of scope, skipping till we get back."
    }
    variable times_left $n
}

proc sdcdb_step {{n 1}} {
    after break "sdcdb::update_step"
    prepare_step $n
    debug step
}

proc sdcdb_next {{n 1}} {
    after break "sdcdb::update_step step_over"
    prepare_step $n
    step_over
}

proc print_info {} {
    variable addr2file
    if {[array get addr2file [reg PC]] eq {}} {
        error "line mapping not found for 0x[h [reg PC]]"
    }
    lassign $addr2file([reg PC]) file line
    if {$file eq {}} {
        error "address [h [reg PC]] not found in database."
    }
    print_status $file $line
}

proc sdcdb_info {arg} {
    if {$arg eq "-break"} {
        debug break
    }
    if {[catch {print_info} fid]} {
        puts $fid
    }
}

proc sdcdb_whereis {file} {
    foreach files {c_files a_files} {
        variable $files
        if {[info exists ${files}($file)]} {
            return "'$file' found in database (as '[set ${files}($file)]')"
        }
    }
    return "'$file' not found in database"
}

proc sdcdb_quit {} {
    variable initialized
    if {$initialized} {
        variable c_files
        foreach filename [array names c_files] {
            set arrayname c_[file rootname $filename]2addr
            variable $arrayname
            catch {unset $arrayname}
            set arrayname [file rootname $filename]_func2addr
            variable $arrayname
            catch {unset $arrayname}
        }
        variable a_files
        foreach filename [array names a_files] {
            set arrayname a_[file rootname $filename]2addr
            variable $arrayname
            catch {unset $arrayname}
        }
        catch {unset c_files}
        variable c_files_count
        catch {unset c_files_count}
        variable addr2file
        catch {unset addr2file}
        variable g_func2addr
        catch {unset g_func2addr}
        set initialized 0
    }
}

proc h {address} {
    return [format %04X $address]
}

namespace export sdcdb

}

# Import sdcdb exported functions
namespace import sdcdb::*

set sdcdb::debug false
