# run_testbenches.tcl - run every Task 10 testbench in the Vivado simulator
# and print each PASS / FAIL line. Run after create_project.tcl:
#
#   vivado -mode batch -source C:/path/to/asteroids_student/scripts/run_testbenches.tcl
#
# or, with the project already open, from the Tcl console:
#   source C:/path/to/asteroids_student/scripts/run_testbenches.tcl

set root [file normalize [file join [file dirname [info script]] ..]]
if {[catch {current_project}]} {
    open_project [file join $root vivado_proj asteroids.xpr]
}

set tbs {tb_vga_timing tb_button_debounce tb_ps2_rx tb_kbd_state
         tb_ge_collide tb_ge_boundary tb_ge_split tb_binary2bcd tb_hud_digits}

foreach tb $tbs {
    puts "=================== $tb ==================="
    set_property top $tb [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]
    set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
    if {[catch {launch_simulation -simset sim_1 -mode behavioral} err]} {
        puts "ERROR: $tb did not compile or run: $err"
        continue
    }
    catch {close_sim -force}
}
puts "Done. Each testbench printed its own PASS / FAIL line above (also in vivado_proj/asteroids.sim/sim_1/behav/xsim/simulate.log)."
