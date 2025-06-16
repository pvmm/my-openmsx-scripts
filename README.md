# my-openmsx-scripts
My collection of openMSX scripts

* **dumpvdp.tcl**: dump VDP register I/O access to stderr;
* **restore.tcl**: `restore_mem` and `restore_range` functions restore memory written to;
* **mm.tcl**: `mm::toggle_access` captures writes to MSX-MUSIC registers $0-$7 when defining instrument 0;
* **_vgmrecorder.tcl**: modified VGM recording script that can write OPL3 VGMs;
* **_casrecorder.tcl**: simple script that appends binary/BASIC/ASCII file to a CAS file;
* **vdpdebugger.tcl**: script that allow user to create watchpoints in VRAM;
* **sdcdb.tcl**: SDCDB connector (WIP)
* **server.tcl**: create a TCP/IP server inside OpenMSX

## very buggy/immature code/WIP
* **codeanalyzer.tcl**: script that marks memory as CODE or DATA dynamically (as the program runs in OpenMSX). Useful for source code annotation;
