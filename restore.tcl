# restore address and range in memory (basically treat memory as ROM)
#
proc restore_addr {addr} {
    set oldvalue [peek $addr]
    debug set_watchpoint write_mem $addr {} "poke $addr $oldvalue"
}


proc restore_range {addr size} {
    set mem [debug read_block memory $addr $size]
    set addr2 [expr {$addr + $size}]
    debug set_watchpoint write_mem "$addr $addr2" {} "poke \$::wp_last_address \[scan \[string range \"$mem\" \[expr \$::wp_last_address - $addr\] 1\] %c\]"
}


proc restore_range2 {addr addr2} {
    set mem [debug read_block memory $addr [expr {$addr2 - $addr}]]
    debug set_watchpoint write_mem "$addr $addr2" {} "poke \$::wp_last_address \[scan \[string range \"$mem\" \[expr \$::wp_last_address - $addr\] 1\] %c\]"
}
