# create_game_rom_bmg.tcl - (re)create the game ROM IP with exactly the
# settings the design needs. Run in the Vivado Tcl console of your project:
#
#   source C:/path/to/asteroids_student/scripts/create_game_rom_bmg.tcl
#
# Initialises the ROM from game_data/game.coe.
# Deletes any existing game_rom_bmg first. Resulting ports (no enable, no reset):
#   clka, addra[10:0], douta[31:0]
# Run it again whenever the .coe file changes.

set root [file normalize [file join [file dirname [info script]] ..]]
set coe  [file join $root game_data game.coe]
if {![file exists $coe]} { error "game_data/game.coe not found in $root" }

set old [get_files -quiet game_rom_bmg.xci]
if {[llength $old]} {
    set olddir [file dirname [lindex $old 0]]
    catch { export_ip_user_files -of_objects $old -no_script -reset -force -quiet }
    remove_files $old
    catch { file delete -force $olddir }
    puts "removed old game_rom_bmg ($olddir)"
}

create_ip -name blk_mem_gen -vendor xilinx.com -library ip -module_name game_rom_bmg
set_property -dict [list \
    CONFIG.Interface_Type {Native} \
    CONFIG.Memory_Type {Single_Port_ROM} \
    CONFIG.Write_Width_A {32} CONFIG.Read_Width_A {32} CONFIG.Write_Depth_A {2048} \
    CONFIG.Enable_A {Always_Enabled} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortA_Output_of_Memory_Core {false} \
    CONFIG.Use_RSTA_Pin {false} \
    CONFIG.Load_Init_File {true} \
    CONFIG.Coe_File $coe \
    CONFIG.Fill_Remaining_Memory_Locations {true} \
    CONFIG.Remaining_Memory_Locations {0} \
] [get_ips game_rom_bmg]
generate_target all [get_ips game_rom_bmg]
catch { create_ip_run [get_ips game_rom_bmg] }

foreach p {Memory_Type Write_Width_A Write_Depth_A Enable_A Register_PortA_Output_of_Memory_Primitives Load_Init_File Coe_File} {
    puts "game_rom_bmg $p = [get_property CONFIG.$p [get_ips game_rom_bmg]]"
}
puts "game_rom_bmg created from $coe. Now reset the synthesis run and rebuild."
