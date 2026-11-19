# build_bitstream.tcl - synthesis, implementation and bitstream for the
# project made by create_project.tcl, plus the reports the handout asks for.
#   vivado -mode batch -source C:/path/to/asteroids_student/scripts/build_bitstream.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
if {[catch {current_project}]} {
    open_project [file join $root vivado_proj asteroids.xpr]
}
set rpt [file join $root reports]
file mkdir $rpt

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }

open_run impl_1
report_timing_summary -file [file join $rpt timing_summary.txt]
report_utilization    -file [file join $rpt utilization.txt]
report_drc            -file [file join $rpt drc.txt]
set bit [glob -nocomplain [file join $root vivado_proj asteroids.runs impl_1 *.bit]]
puts "Bitstream: $bit"
puts "Reports in $rpt"
