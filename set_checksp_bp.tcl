proc set_checksp_bp {addr} {
  # before call set ::addr_sp to [reg SP]
  debug breakpoint create -address "0x[format %x [expr $addr]]" -command "set ::addr_sp \[reg SP\]; puts \"::addr_sp = \$::addr_sp\""
  # after call stops if ::addr_sp not equals [reg SP]
  debug breakpoint create -address "0x[format %x [expr $addr + 3]]" -condition "\$::addr_sp != \[reg SP\]"
}
