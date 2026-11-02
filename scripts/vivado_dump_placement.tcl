# Vivado: dump a routed checkpoint's placement in the form scripts/placement_fom.py
# and placement_analyse.py read (--vivado), and the site table they need.
#   vivado -mode batch -source scripts/vivado_dump_placement.tcl -tclargs route.dcp out_dir
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set f [open $out/cells_grid.txt w]
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE && PRIMITIVE_LEVEL != INTERNAL}] {
    set s [get_property LOC $c]; set t ""; set col ""; set row ""
    if {$s != ""} { set t [get_tiles -of_objects [get_sites $s]]; set col [get_property COLUMN $t]; set row [get_property ROW $t] }
    puts $f "[get_property NAME $c]\t[get_property REF_NAME $c]\t$s\t[get_property BEL $c]\t$t\t$col\t$row"
}
close $f
# site -> tile -> grid column/row (equal to nextpnr's himbaechel X/Y) -> site type
set f [open $out/sites.txt w]
foreach t [get_tiles] {
    set col [get_property COLUMN $t]; set row [get_property ROW $t]
    foreach s [get_sites -of_objects $t] { puts $f "$s\t$t\t$col\t$row\t[get_property SITE_TYPE $s]" }
}
close $f
