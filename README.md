# my-openmsx-scripts
My collection of openMSX scripts

* **dumpvdp.tcl**: dump VDP register I/O access to stderr;
* **restore.tcl**: `restore_mem` and `restore_range` functions restore memory written to;
* **mm.tcl**: `mm::toggle_access` captures writes to MSX-MUSIC registers $0-$7 when defining instrument 0;
* **vgmrecorder.tcl**: modified VGM recording script that can write OPL3 VGMs;
* **casrecorder.tcl**: simple script that appends binary/BASIC/ASCII file to a CAS file;
* **vdpdebugger.tcl**: script that allow user to create watchpoints in VRAM;
* **sdcdb.tcl**: SDCDB connector (WIP)
* **server.tcl**: create a TCP/IP server inside OpenMSX
* **check_debug_msgs.tcl**: checks if Tcl debugging is working

## very buggy/immature/WIP code
* **codeanalyzer.tcl**: script that marks memory as CODE or DATA dynamically (as the program runs in OpenMSX). Useful for source code annotation;

## deprecated/unmaintained code
* **slow_profiler.tcl** is deprecated code that has since evolved into **new-profiler.tcl**.
* **new-profiler.tcl** is no longer being developed since a more useful version lives in OpenMSX now as **_profiler.tcl**.
