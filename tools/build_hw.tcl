# Build the MLP accelerator from the committed sources: project, bitstream, XSA and reports.
#
#   vivado -mode batch -nojournal -source tools/build_hw.tcl
#
# Run from the repository root with Vivado 2022.1. The Vivado project is generated in build/vivado/
# (never committed); results go to build/hw/:
#   mlp_accelerator.xsa (bitstream included), utilization_placed.rpt,
#   timing_summary_routed.rpt, utilization_hierarchical_synth.rpt

set repo [file normalize [file dirname [info script]]/..]
set src  $repo/03-mlp-accelerator
set proj $repo/build/vivado
set out  $repo/build/hw
file delete -force $proj
file mkdir $out

create_project mlp_accelerator $proj -part xc7z020clg484-1
set_property target_language Verilog [current_project]

add_files -norecurse [concat [glob $src/rtl/*.sv] [glob $src/rtl/*.v] [list $src/rtl/bram_init.hex]]
add_files -fileset constrs_1 -norecurse $src/constraints/zynq7020.xdc
add_files -fileset sim_1 -norecurse $src/tb/tb_mlp_top.sv
set_property top tb_mlp_top [get_filesets sim_1]
update_compile_order -fileset sources_1

# Block design: PS7 + AXI interconnect + reset + the accelerator (module reference), IRQ_F2P from o_PROC_DONE
source $src/bd/mlp_bd.tcl
set bd [get_files mlp_bd.bd]
generate_target all $bd
add_files -norecurse [make_wrapper -files $bd -top]
set_property top mlp_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%" ||
    ![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
    puts "BUILD: FAILED - synth_1: [get_property STATUS [get_runs synth_1]], impl_1: [get_property STATUS [get_runs impl_1]]"
    exit 1
}

open_run synth_1 -name synth_1
report_utilization -hierarchical -file $out/utilization_hierarchical_synth.rpt
close_design
open_run impl_1
report_utilization    -file $out/utilization_placed.rpt
report_timing_summary -max_paths 10 -report_unconstrained -file $out/timing_summary_routed.rpt
write_hw_platform -fixed -include_bit -force $out/mlp_accelerator.xsa
puts "BUILD: WNS = [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] ns"
puts "BUILD: OK - $out/mlp_accelerator.xsa"
exit 0
