# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Tobias Senti      <tsenti@ethz.ch>
# - Jannis Schönleber <janniss@iis.ee.ethz.ch>
# - Philippe Sauter   <phsauter@iis.ee.ethz.ch>

# Stage 01: Initialization, Floorplan, and Power Grid
#
# This stage performs:
# - Reading and linking the netlist
# - Reading timing constraints
# - Connecting global power nets
# - Creating the floorplan (die/core area, macro placement, IO placement)
# - Generating the power distribution network
#
# Required environment variables:
#   PROJ_NAME    - Project name (e.g., "croc")
#   NETLIST      - Path to synthesized netlist
#   TOP_DESIGN   - Top module name
#
# Output checkpoint: 01_${PROJ_NAME}.floorplan

###############################################################################
# Setup
###############################################################################
source scripts/startup.tcl

utl::report "###############################################################################"
utl::report "# Stage 01: FLOORPLAN"
utl::report "###############################################################################"

utl::report "###############################################################################"
utl::report "# 01-01: Initialization"
utl::report "###############################################################################"

# Read and check design
utl::report "Read netlist: ${netlist}"
read_verilog $netlist
link_design $top_design

utl::report "Read constraints"
read_sdc src/constraints.sdc

utl::report "Check constraints"
check_setup -verbose                                      > ${report_dir}/01-01_${proj_name}_checks.rpt
report_checks -unconstrained -format end -no_line_splits >> ${report_dir}/01-01_${proj_name}_checks.rpt
report_checks -format end -no_line_splits                >> ${report_dir}/01-01_${proj_name}_checks.rpt
report_checks -format end -no_line_splits                >> ${report_dir}/01-01_${proj_name}_checks.rpt
utl::report "Connect global nets (power)"
source scripts/power_connect.tcl


utl::report "###############################################################################"
utl::report "# 01-02: Core and Die Area"
utl::report "###############################################################################"
# Dimensions:                          [um]
#   final chip size (4sqmm) 2000.0 x 2000.0
#   seal ring thickness       42.0 ,   42.0 x2
#   bonding pad               70.0 ,   70.0 x2
#   io cell depth            180.0 ,  180.0 x2
#   ---------------------------------------
#   -> OR die area          1916.0 x 1916.0
#   -> OR core area         1416.0 x 1416.0
# The sealring is added after OpenROAD
# hence the OR die area is the final chip size minus the sealring thickness on each side

set chipH    1916; # OR die height (top to bottom)
set chipW    1916; # OR die width (left to right)
set padD      180; # pad depth (edge to core)
set padW       80; # pad width (beachfront)
set padBond    70; # bonding pad size
set powerRing  80; # reserved space for power ring

# starting from the outside and working towards the core area on each side
set coreMargin [expr {$padD + $padBond + $powerRing}];

utl::report "Initialize Chip"
# coordinates are lower-left x and y, upper-right x and y
initialize_floorplan -die_area "0 0 $chipW $chipH" \
                     -core_area "$coreMargin $coreMargin [expr $chipW-$coreMargin] [expr $chipH-$coreMargin]" \
                     -site "CoreSite"


utl::report "###############################################################################"
utl::report "# 01-03: Padring"
utl::report "###############################################################################"
source src/padring.tcl


##########################################################################
# RAM sizes
##########################################################################
set RamMaster256x64   [[ord::get_db] findMaster "RM_IHPSG13_1P_256x64_c2_bm_bist"]
set RamSize256x64_W   [ord::dbu_to_microns [$RamMaster256x64 getWidth]]
set RamSize256x64_H   [ord::dbu_to_microns [$RamMaster256x64 getHeight]]


##########################################################################
# Chip and Core Area
##########################################################################
# core gets snapped to site-grid -> get real values
set coreArea      [ord::get_core_area]
set core_leftX    [lindex $coreArea 0]
set core_bottomY  [lindex $coreArea 1]
set core_rightX   [lindex $coreArea 2]
set core_topY     [lindex $coreArea 3]


##########################################################################
# Tracks 
##########################################################################
# We need to define the metal tracks 
# (where the wires on each metal should go)
make_tracks

# the height of a standard cell, useful to align things
set siteHeight        [ord::dbu_to_microns [[dpl::get_row_site] getHeight]]


utl::report "###############################################################################"
utl::report "# 01-04: Macro Placement"
utl::report "###############################################################################"
# Paths to the instances of macros
utl::report "Macro Names"
source src/instances.tcl

# Placing macros
# use these for macro placement
set floorPaddingX      12.0
set floorPaddingY      12.0
set floor_leftX       [expr $core_leftX + $floorPaddingX]
set floor_bottomY     [expr $core_bottomY + $floorPaddingY]
set floor_rightX      [expr $core_rightX - $floorPaddingX]
set floor_topY        [expr $core_topY - $floorPaddingY]
set floor_midpointX   [expr $floor_leftX + ($floor_rightX - $floor_leftX)/2]
set floor_midpointY   [expr $floor_bottomY + ($floor_topY - $floor_bottomY)/2]

utl::report "Place Macros"

# Bank0
set X [expr $floor_midpointX - $RamSize256x64_W/2]
set Y [expr $floor_topY - $RamSize256x64_H]
placeInstance $bank0_sram0 $X $Y R0

# Bank1
set X [expr $X]
set Y [expr $floor_bottomY]
placeInstance $bank1_sram0 $X $Y MX

# defined in init_tech.tcl
insertTapCells

cut_rows -halo_width_x 1 -halo_width_y 1
global_connect


utl::report "###############################################################################"
utl::report "# 01-04b: Placement Regions (using OpenDB odb API)"
utl::report "###############################################################################"
# -----------------------------------------------------------------------
# Placement Regions – correct OpenROAD/OpenDB Tcl API
# -----------------------------------------------------------------------
# Uses odb::dbRegion_create + setRegion (GUIDE = soft hint for placer)
# All calls are wrapped in catch{} so a bad inst name never aborts flow.
#
# Layout partition (seen from above, Y grows upward):
#
#   +---+---[ SRAM Bank0 ]---+---+
#   |   |                    |   |
#   | J |   CORE (CVE2)      | G |
#   | T |                    | P |
#   | A |--------------------| I |
#   | G |   UART / PERIPH    | O |
#   | / |                    |   |
#   | D +---[ SRAM Bank1 ]---+   |
#   | M |                    | I |
#   |   |                    | 2 |
#   |   |   I2C / USER       | C |
#   +---+--------------------+---+
#
# X: left 28% JTAG+DM | center 44% CORE/UART | right 28% GPIO+I2C
# Y: top 55% CORE+SRAMs | bottom 45% PERIPH+I2C

set _p_db    [ord::get_db]
set _p_block [[$_p_db getChip] getBlock]
set _p_dbu   [[$_p_db getTech] getDbUnitsPerMicron]

# Convert microns to DBU
proc _p_um2dbu {um} {
    global _p_dbu
    return [expr {int(round($um * $_p_dbu))}]
}

# Create a GUIDE region and assign instances to it (all errors non-fatal)
proc _p_make_region {rname x1 y1 x2 y2 inst_names} {
    global _p_block
    set n 0
    set reg ""
    catch { set reg [odb::dbRegion_create $_p_block $rname] }
    if {$reg eq "" || $reg eq "NULL"} {
        utl::report "  \[WARN\] Region $rname: creation failed (skipping)"
        return 0
    }
    catch { $reg setRegionType GUIDE }
    catch { odb::dbBox_create $reg \
        [_p_um2dbu $x1] [_p_um2dbu $y1] \
        [_p_um2dbu $x2] [_p_um2dbu $y2] }
    foreach iname $inst_names {
        catch {
            set inst [$_p_block findInst $iname]
            if {$inst ne "NULL" && $inst ne ""} {
                $inst setRegion $reg
                incr n
            }
        }
    }
    utl::report "  Region $rname (GUIDE): $n insts, bbox ${x1},${y1} -> ${x2},${y2} um"
    return 1
}

# Boundary coordinates (in microns)
set _pJL  $core_leftX
set _pJR  [expr {$core_leftX  + ($core_rightX - $core_leftX) * 0.28}]
set _pML  $_pJR
set _pMR  [expr {$core_rightX - ($core_rightX - $core_leftX) * 0.28}]
set _pGL  $_pMR
set _pGR  $core_rightX
set _pTB  [expr {$core_bottomY + ($core_topY - $core_bottomY) * 0.45}]
set _pTT  $core_topY
set _pBB  $core_bottomY
set _pBT  $_pTB

# Region 1: CVE2 Core (center-upper)
_p_make_region "CORE_REGION" \
    [expr {$_pML+4}] [expr {$_pTB+4}] \
    [expr {$_pMR-4}] [expr {$_pTT-$RamSize256x64_H-8}] \
    [list "$CROC/i_core_wrap"]

# Region 2: JTAG + Debug Module (left stripe)
_p_make_region "JTAGDM_REGION" \
    [expr {$_pJL+4}] [expr {$_pBB+4}] \
    [expr {$_pJR-4}] [expr {$_pTT-$RamSize256x64_H-8}] \
    [list "$CROC/i_dmi_jtag" "$CROC/i_dm_top.i_dm_top"]

# Region 3: UART + Peripherals (center-lower)
_p_make_region "PERIPH_REGION" \
    [expr {$_pML+4}] [expr {$_pBB+$RamSize256x64_H+8}] \
    [expr {$_pMR-4}] [expr {$_pTB-4}] \
    [list "$CROC/i_uart" "$CROC/i_clint" "$CROC/i_bootrom" \
          "$CROC/i_soc_ctrl" "$CROC/i_obi_timer"]

# Region 4: GPIO (right stripe upper)
_p_make_region "GPIO_REGION" \
    [expr {$_pGL+4}] [expr {$_pTB+4}] \
    [expr {$_pGR-4}] [expr {$_pTT-$RamSize256x64_H-8}] \
    [list "$CROC/i_gpio"]

# Region 5: I2C + User domain (right stripe lower)
# pad_i2c_sda_io and pad_i2c_scl_io are on NORTH edge, pins 13-14
_p_make_region "I2C_USER_REGION" \
    [expr {$_pGL+4}] [expr {$_pBB+4}] \
    [expr {$_pGR-4}] [expr {$_pBT-4}] \
    [list "$USER" "$USER/i_i2c"]

utl::report "Placement regions done (5 GUIDE regions created)"


utl::report "###############################################################################"
utl::report "# 01-04: Power Grid"
utl::report "###############################################################################"
source scripts/power_grid.tcl

utl::report "###############################################################################"
utl::report "# 01-05: I2C Area Report"
utl::report "###############################################################################"

# Report hierarchical area (includes user_domain with i2c instance)
set when "01_floorplan"
set filename "${report_dir}/01-05_${proj_name}_i2c_area.rpt"
set fileId [open $filename w]
close $fileId

# Helper to write into report file
proc rpt_puts { filename line } {
    set fid [open $filename a]
    puts $fid $line
    close $fid
}

rpt_puts $filename "================================================================================"
rpt_puts $filename "I2C / User Domain Area Report - Stage 01 (Post Floorplan)"
rpt_puts $filename "Generated by OpenROAD after floorplan step"
rpt_puts $filename "================================================================================"
rpt_puts $filename ""

# Get die/core area for context
set db      [::ord::get_db]
set block   [[$db getChip] getBlock]
set dbu_uu  [expr double([[$db getTech] getDbUnitsPerMicron])]

set die_bbox  [$block getDieArea]
set core_bbox [$block getCoreArea]
set die_w     [expr [$die_bbox dx]  / $dbu_uu]
set die_h     [expr [$die_bbox dy]  / $dbu_uu]
set core_w    [expr [$core_bbox dx] / $dbu_uu]
set core_h    [expr [$core_bbox dy] / $dbu_uu]

rpt_puts $filename [format "Die  Area : %.2f x %.2f um  = %.2f um2" $die_w  $die_h  [expr $die_w  * $die_h ]]
rpt_puts $filename [format "Core Area : %.2f x %.2f um  = %.2f um2" $core_w $core_h [expr $core_w * $core_h]]
rpt_puts $filename ""

# Count cells belonging to the i2c instance hierarchy
# After yosys flatten, instance names are flattened with backslash-escaped hierarchy
# Pattern: *i_croc_soc*i_user*i_i2c* (instance path in flattened netlist)
set i2c_stdcell_area  0.0
set i2c_cell_count    0

foreach inst [$block getInsts] {
    set inst_name [$inst getName]
    # Match instances that belong to the i2c hierarchy in user domain
    if { [string match "*i_user*i_i2c*" $inst_name] || \
         [string match "*i_croc_soc*i_user*" $inst_name] } {
        set master [$inst getMaster]
        if { ![$master isFiller] && ![$master isBlock] && ![$master isPad] } {
            set cell_area [expr [$master getWidth] * [$master getHeight] / ($dbu_uu * $dbu_uu)]
            set i2c_stdcell_area [expr $i2c_stdcell_area + $cell_area]
            incr i2c_cell_count
        }
    }
}

# Also search specifically for the i2c module hierarchy
set i2c_only_area   0.0
set i2c_only_count  0
foreach inst [$block getInsts] {
    set inst_name [$inst getName]
    if { [string match "*\\/i_i2c\\/*" $inst_name] || \
         [string match "*_i_i2c_*" $inst_name] || \
         [string match "*i_i2c*" $inst_name] } {
        set master [$inst getMaster]
        if { ![$master isFiller] && ![$master isBlock] && ![$master isPad] } {
            set cell_area [expr [$master getWidth] * [$master getHeight] / ($dbu_uu * $dbu_uu)]
            set i2c_only_area [expr $i2c_only_area + $cell_area]
            incr i2c_only_count
        }
    }
}

rpt_puts $filename "--------------------------------------------------------------------------------"
rpt_puts $filename "I2C Module (i_i2c) Cell Statistics"
rpt_puts $filename "--------------------------------------------------------------------------------"
rpt_puts $filename [format "  Standard Cells in i2c hierarchy : %d cells" $i2c_only_count]
rpt_puts $filename [format "  Total i2c stdcell area          : %.4f um2"  $i2c_only_area]
rpt_puts $filename ""
rpt_puts $filename "Note: After floorplan (pre-placement), cells are not yet placed."
rpt_puts $filename "      Area above is the sum of cell master bounding boxes (synthesis result)."
rpt_puts $filename "      For placed area, re-run this report after Stage 02 (placement)."
rpt_puts $filename ""

utl::report "I2C area report written to: ${filename}"
utl::report [format "  i2c cells: %d, total area: %.4f um2" $i2c_only_count $i2c_only_area]

# Also generate full hierarchical area report for the entire design
utl::report "Generating full hierarchical area report..."
source scripts/reports.tcl
set when "01_floorplan_area"
set filename "${report_dir}/01-05_${proj_name}_area_hierarchical.rpt"
set fileId [open $filename w]
close $fileId
report_area_hierarchical

utl::report "Hierarchical area report written to: ${report_dir}/01-05_${proj_name}_area_hierarchical.rpt"

# Save checkpoint
save_checkpoint 01_${proj_name}.floorplan
report_image "01_${proj_name}.floorplan" true

utl::report "###############################################################################"
utl::report "# Stage 01 complete: Checkpoint saved to ${save_dir}/01_${proj_name}.floorplan.zip"
utl::report "###############################################################################"

