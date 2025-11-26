proc set_checksp_bp {args} {
  if {[llength $args] == 1} {
    set type {-addr}
    lassign $args addr
  } elseif {[llength $args] == 2} {
    lassign $args type addr
  } else {
    error {wrong # args: should be "set_checksp_bp ?-addr|-symbol? address_or_symbol}
  }
  if {[lsearch -exact [list "-addr" "-symbol"] $type] == -1} {
    error "1st parameter should be -addr or -symbol"
  }
  if {$type eq "-symbol"} { set addr [expr $::sym($addr)] }
  # before call set ::addr_sp to [reg SP]
  debug breakpoint create -address "0x[format %x [expr $addr]]" -command "set ::addr_sp \[reg SP\]; puts \"::addr_sp = \$::addr_sp\""
  # after call stops if ::addr_sp not equals [reg SP]
  debug breakpoint create -address "0x[format %x [expr $addr + 3]]" -condition "\$::addr_sp != \[reg SP\]"
}
