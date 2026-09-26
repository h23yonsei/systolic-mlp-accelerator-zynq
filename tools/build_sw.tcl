# Build the PS-side application (mlp_app.elf) with Vitis.
#
#   xsct tools/build_sw.tcl                              # uses the committed 03-mlp-accelerator/mlp_accelerator.xsa
#   xsct tools/build_sw.tcl build/hw/mlp_accelerator.xsa # uses a platform rebuilt by tools/build_hw.tcl
#
# Run from the repository root with Vitis 2022.1 (xsct). The workspace goes to build/vitis/ and the
# executable to build/vitis/mlp_app/Debug/mlp_app.elf. Program the board and run it from the Vitis
# IDE or with xsct's connect/fpga/dow commands; results print over UART at 115200 baud.

set repo [file normalize [file dirname [info script]]/..]
set src  $repo/03-mlp-accelerator
set xsa  [expr {[llength $argv] > 0 ? [file normalize [lindex $argv 0]] : "$src/mlp_accelerator.xsa"}]
set ws   $repo/build/vitis

file delete -force $ws
file mkdir $ws
setws $ws

platform create -name mlp_platform -hw $xsa -os standalone -proc ps7_cortexa9_0 -out $ws
platform generate

app create -name mlp_app -platform mlp_platform -domain standalone_domain -template {Empty Application(C)}
foreach f [glob $src/sw/*] { file copy -force $f $ws/mlp_app/src/ }
app build -name mlp_app

set elf [glob -nocomplain $ws/mlp_app/Debug/mlp_app.elf]
if {$elf eq ""} { puts "APP: FAILED"; exit 1 }
puts "APP: OK - $elf"
