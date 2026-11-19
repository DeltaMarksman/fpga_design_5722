# create_obj_ram_bmg.tcl - (re)create the object RAM IP with exactly the
# settings the design needs. Run in the Vivado Tcl console of your project:
#
#   source C:/path/to/asteroids_student/scripts/create_obj_ram_bmg.tcl
#
# Deletes any existing obj_ram_bmg first. Resulting ports (no enables, no resets):
#   clka, wea[0:0], addra[5:0], dina[95:0], douta[95:0]
#   clkb, web[0:0], addrb[5:0], dinb[95:0], doutb[95:0]

set old [get_files -quiet obj_ram_bmg.xci]
if {[llength $old]} {
    set olddir [file dirname [lindex $old 0]]
    catch { export_ip_user_files -of_objects $old -no_script -reset -force -quiet }
    remove_files $old
    catch { file delete -force $olddir }
    puts "removed old obj_ram_bmg ($olddir)"
}

create_ip -name blk_mem_gen -vendor xilinx.com -library ip -module_name obj_ram_bmg
set_property -dict [list \
    CONFIG.Interface_Type {Native} \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Use_Byte_Write_Enable {false} \
    CONFIG.Write_Width_A {96} CONFIG.Read_Width_A {96} CONFIG.Write_Depth_A {64} \
    CONFIG.Write_Width_B {96} CONFIG.Read_Width_B {96} \
    CONFIG.Operating_Mode_A {READ_FIRST} CONFIG.Operating_Mode_B {READ_FIRST} \
    CONFIG.Enable_A {Always_Enabled} CONFIG.Enable_B {Always_Enabled} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortA_Output_of_Memory_Core {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Core {false} \
    CONFIG.Use_RSTA_Pin {false} CONFIG.Use_RSTB_Pin {false} \
    CONFIG.Load_Init_File {false} \
] [get_ips obj_ram_bmg]
generate_target all [get_ips obj_ram_bmg]
catch { create_ip_run [get_ips obj_ram_bmg] }

foreach p {Memory_Type Write_Width_A Write_Width_B Read_Width_B Write_Depth_A Operating_Mode_A Enable_A Enable_B Register_PortA_Output_of_Memory_Primitives Register_PortB_Output_of_Memory_Primitives} {
    puts "obj_ram_bmg $p = [get_property CONFIG.$p [get_ips obj_ram_bmg]]"
}
puts "obj_ram_bmg created. Now reset the synthesis run and rebuild."
