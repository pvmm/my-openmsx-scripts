# A watchpoint that stops when a specified PSG register receives a specified value.
# Change PSG_REG and PSG_VALUE according to your needs.
#
# source: https://www.msx.org/wiki/PSG_Registers
#
set PSG_PORT0         0xA0      ;# default PSG port (change it if scanning a second PSG)
set PSG_VALUE         0x00      ;# replace with the desired register value to debug break on
set PSG_REG           0x00      ;# replace with the PSG register you want to check
set last_psg_reg      0         ;# used internally

;# data port is always PSG_PORT0 + 1
variable PSG_PORT1    [expr {$PSG_PORT0 + 1}]

debug watchpoint create -type write_io -address $PSG_PORT0 -condition {$::wp_last_value == $PSG_REG} -command {
	set last_psg_reg $::wp_last_value
}

debug watchpoint create -type write_io -address $PSG_PORT1 -condition {
	$last_psg_reg == $PSG_REG && $::wp_last_value == $PSG_VALUE
}
