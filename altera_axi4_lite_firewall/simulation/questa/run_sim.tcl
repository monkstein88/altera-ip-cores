# Note: After opening QuestaSim/Modelsim, change directory to this file's folder.

# Note: After opening QuestaSim/Modelsim, change directory to this file's folder.

# Create and map working library
if {[file exists work]} { file delete -force work }
vlib work
vmap work work

# Compile Design, SVA, and Testbench
vlog -sv +acc +cover=sbceft ../../rtl/axi_firewall_regs.v
vlog -sv +acc +cover=sbceft ../../rtl/axi_firewall_top.v
vlog -sv +acc ../../tb/axi_firewall_sva.sv
vlog -sv +acc ../../tb/axi_firewall_tb.v

# Optimize design with assertion visibility and code coverage flags
vopt axi_firewall_tb -o tb_opt +acc -cover sbceft -assertdebug

# Execute simulation (removed -c to keep interactive GUI mode)
vsim tb_opt -coverage -assertdebug
set NoQuitOnFinish 1
onbreak {resume}
run -all

# Save UCDB database and report assertion + code coverage
assertion report -verbose -recursive
coverage save coverage.ucdb
coverage report -detail -codeAll
# Comment out or remove this line to keep QuestaSim open:
# quit -f
