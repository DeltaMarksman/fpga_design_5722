# create_project.tcl - build the Vivado project for the Asteroids final project.
# Written for Vivado 2017.4 (plain Tcl, no newer-only commands).
#
# Run from anywhere:
#   vivado -mode batch -source C:/path/to/asteroids_student/scripts/create_project.tcl
# or in the Vivado Tcl console:
#   source C:/path/to/asteroids_student/scripts/create_project.tcl
#
# Result: <asteroids_student>/vivado_proj/asteroids.xpr  (Basys3, xc7a35tcpg236-1)
# Put your testbenches (tb_*.v) in <asteroids_student>/tb/ and re-run to add them.

set root     [file normalize [file join [file dirname [info script]] ..]]
set projdir  [file join $root vivado_proj]
set projname asteroids
set part     xc7a35tcpg236-1

if {[file exists $projdir]} {
    puts "NOTE: $projdir exists; deleting it to recreate the project."
    file delete -force $projdir
}

create_project $projname $projdir -part $part
# Basys3 board file is optional; ignore if the board is not installed.
catch { set_property board_part digilentinc.com:basys3:part0:1.1 [current_project] }
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# ---- design sources ----
set hdl [file join $root HDL_Incomplete]
set vfiles [glob -nocomplain -directory $hdl *.v]
add_files -norecurse $vfiles
set vh [file join $hdl ge_defs.vh]
add_files -norecurse $vh
set_property file_type {Verilog Header} [get_files ge_defs.vh]
set_property is_global_include true [get_files ge_defs.vh]
set_property include_dirs [list $hdl] [get_filesets sources_1]
set_property top top_basys3 [current_fileset]

# ---- constraints ----
add_files -fileset constrs_1 -norecurse [file join $hdl basys3.xdc]

# ---- simulation sources (testbenches) ----
set tbs [glob -nocomplain -directory [file join $root tb] tb_*.v]
if {[llength $tbs]} {
    add_files -fileset sim_1 -norecurse $tbs
    set_property include_dirs [list $hdl] [get_filesets sim_1]
} else {
    puts "NOTE: no tb/tb_*.v files yet; add them and re-run to include them."
}

# ---- Block Memory Generator IP (needs game_data/game.coe) ----
foreach s {create_game_rom_bmg.tcl create_obj_ram_bmg.tcl} {
    if {[catch { source [file join $root scripts $s] } err]} {
        puts "WARNING: $s failed in this Vivado version: $err"
        puts "         Create that IP by hand in the IP Catalog (see the handout)."
    }
}

update_compile_order -fileset sources_1
puts "Project created: [file join $projdir $projname.xpr]"
