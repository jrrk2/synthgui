# coverage.tcl <dcp> <out>: route status and clock coverage of a converted checkpoint (timing constraints only)
set dcp [lindex $argv 0]; set o [lindex $argv 1]
open_checkpoint $dcp
report_route_status -file $o/route_status.rpt
report_route_status -list_all_nets -file $o/route_status_nets.rpt
read_xdc -unmanaged $o/timing.xdc
report_clocks -file $o/clocks.rpt
report_clock_networks -file $o/clock_networks.rpt
check_timing -verbose -file $o/check_timing.rpt
report_clock_interaction -delay_type min_max -significant_digits 3 -file $o/clock_interaction.rpt
report_timing_summary -max_paths 10 -report_unconstrained -file $o/timing_summary.rpt
set f [open $o/regs_by_clock.tsv w]
set seq [get_cells -hier -filter {IS_SEQUENTIAL || IS_PRIMITIVE && (REF_NAME =~ RAMB* || REF_NAME =~ DSP* || REF_NAME =~ *SERDES* || REF_NAME =~ IDELAY* || REF_NAME =~ FIFO*)}]
foreach c $seq {
  set ck [get_pins -quiet -of $c -filter {IS_CLOCK}]
  set clks {}
  foreach p $ck { foreach k [get_clocks -quiet -of $p] { lappend clks $k } }
  puts $f "[get_property REF_NAME $c]\t$c\t[lsort -unique $clks]"
}
close $f
report_drc -checks {RTSTAT-1 RTSTAT-2 RTSTAT-3 RTSTAT-4 RTSTAT-5 RTSTAT-6 RTSTAT-9 RTSTAT-10} -file $o/drc_rtstat.rpt
