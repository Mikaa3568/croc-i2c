# Copyright 2025 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Philip Wiese      <wiesep@iis.ee.ethz.ch>


# Function to compare hierarchies alphabetically and by depth
proc compare_hierarchy {a b} {
    set cmp_alpha [string compare $a $b]
    if { $cmp_alpha != 0 } {
        return $cmp_alpha
    }
    return [expr {[llength [split $a "/"]] - [llength [split $b "/"]]}]
}

# Function to sort hierarchies alphabetically and by depth
proc sort_hierarchy {array_name} {
    upvar $array_name stats
    set hierarchies {}

    foreach key [array names stats] {
        set hierarchy [lindex [split $key ":"] 0]
        if { $hierarchy ni $hierarchies } { lappend hierarchies $hierarchy }
    }

    return [lsort -command compare_hierarchy $hierarchies]
}

# Compute accumulated totals for parent hierarchies
proc accumulate_totals {sorted_hierarchies stats_ref} {
    upvar $stats_ref stats

    foreach hierarchy [lreverse $sorted_hierarchies] {
        set parent_hierarchy [join [lrange [split $hierarchy "/"] 0 end-1] "/"]

        foreach cell_type {macro cover pad stdcell total} {
            foreach suffix {area inst} {
                set local_key ${hierarchy}:${cell_type}_local_$suffix
                set global_key ${hierarchy}:${cell_type}_global_$suffix
                set parent_global_key ${parent_hierarchy}:${cell_type}_global_$suffix

                if { ![info exists stats($global_key)] } {
                    set stats($global_key) 0
                }

                 if { [info exists stats($local_key)] } {
                    incr stats($global_key) $stats($local_key)
                }

                if { $parent_hierarchy eq "" } { continue }
                incr stats($parent_global_key) $stats($global_key)
            }
        }
    }
}

# Expand paths to include all parent hierarchies
proc expand_paths {sorted_hierarchies stats_ref} {
    upvar $stats_ref stats

    foreach hierarchy $sorted_hierarchies {
        set parent_hierarchy [join [lrange [split $hierarchy "/"] 0 end-1] "/"]
        if { $parent_hierarchy eq "" } { set parent_hierarchy "<top>" }

        foreach cell_type {macro cover pad stdcell total} {
            foreach suffix {area inst} {
                set local_key ${hierarchy}:${cell_type}_local_$suffix
                set global_key ${hierarchy}:${cell_type}_global_$suffix
                set parent_global_key ${parent_hierarchy}:${cell_type}_global_$suffix

                if { ![info exists stats($parent_global_key)] } {
                    set stats($parent_global_key) 0
                }
            }
        }
    }
}

# Print the report
proc print_report {sorted_hierarchies stats_ref block_ref dbu_per_uu} {
    upvar $stats_ref stats
    upvar $block_ref block

    upvar 1 when when
    upvar 1 filename filename

    # Set up report directory and filename
    if { ![info exists report_dir] } { set report_dir "reports" }
    if { ![info exists when] } { set when "croc.area" }
    if { ![info exists filename] } {
        set filename "$report_dir/$when.rpt"
        set fileId [open $filename w]
        close $fileId
    }

    # Print report headers
    report_puts "\n=========================================================================="
    report_puts "$when area by hierarchy"
    report_puts "--------------------------------------------------------------------------"

    set die_bbox [$block getDieArea]
    set die_area [expr [$die_bbox dx] * [$die_bbox dy]]
    set core_bbox [$block getCoreArea]
    set core_area [expr [$core_bbox dx] * [$core_bbox dy]]

    set die_area [expr $die_area / [expr $dbu_per_uu * $dbu_per_uu]]
    set core_area [expr $core_area / [expr $dbu_per_uu * $dbu_per_uu]]
    set num_ios [llength [$block getBTerms]]

    set total_area [expr $stats(<top>:total_global_area) / [expr $dbu_per_uu * $dbu_per_uu]]
    set stdcell_area [expr $stats(<top>:stdcell_global_area) / [expr $dbu_per_uu * $dbu_per_uu]]
    set macro_area [expr $stats(<top>:macro_global_area) / [expr $dbu_per_uu * $dbu_per_uu]]
    set cover_area [expr $stats(<top>:cover_global_area) / [expr $dbu_per_uu * $dbu_per_uu]]
    set pad_area [expr $stats(<top>:pad_global_area) / [expr $dbu_per_uu * $dbu_per_uu]]

    set total_active_area [expr $stdcell_area + $macro_area]

    if { $core_area > 0 } {
        set core_util [expr $total_active_area / $core_area]
        if { $core_area > $macro_area } {
        set stdcell_util [expr $stdcell_area / [expr $core_area - $macro_area]]
        } else {
        set stdcell_util 0.0
        }
    } else {
        set core_util -1.0
        set stdcell_util -1.0
    }

    report_puts ""
    report_puts "--------------------------------------------------------------------------------"
    report_puts "Design Area Summary"
    report_puts "--------------------------------------------------------------------------------"
    report_puts "Die Area:              $die_area um2"
    report_puts "Core Area:             $core_area um2"
    report_puts "Total Area:            $total_area um2"
    report_puts "Total Active Area:     $total_active_area um2"
    report_puts ""
    report_puts "Core Utilization:      $core_util"
    report_puts "Std Cell Utilization:  $stdcell_util"


    set indent_char "  "
    set max_width 79

    # Print header
    report_puts ""
    report_puts "--------------------------------------------------------------------------------"
    report_puts "Hierarchical Area Report"
    report_puts "--------------------------------------------------------------------------------"
    report_puts [format "%-*s %-79s %-79s %-79s %-s" $max_width "" \
        "Global Area (um^2)" \
        "Global Instances" \
        "Local Area (um^2)" \
        "Local Instances"
    ]
    report_puts [format "%-*s %-s %-s %-s %-s" $max_width ""  [string repeat "-" 79] [string repeat "-" 79] [string repeat "-" 79] [string repeat "-" 76]]

    set format_string [string repeat "%-15s " 20]

    report_puts [format "%-*s $format_string" \
        $max_width "Hierarchy Name" \
        "Total" "StdCell" "Macro" "Cover" "Pad" \
        "Total" "StdCell" "Macro" "Cover" "Pad" \
        "Total" "StdCell" "Macro" "Cover" "Pad" \
        "Total" "StdCell" "Macro" "Cover" "Pad"
    ]
    report_puts [string repeat "-" [expr {$max_width + 79+79+79+79}]]

    foreach hierarchy $sorted_hierarchies {
        set display_name [lindex [split $hierarchy "/"] end]

        # report_puts $hierarchy
        set indent [string repeat $indent_char [expr {[llength [split $hierarchy "/"]] - 1}]]

        foreach cell_type {total macro cover pad stdcell} {
            set global_key "${hierarchy}:${cell_type}_global"
            set local_key "${hierarchy}:${cell_type}_local"

            set global_areas($cell_type) [format "%.3f" [expr {[info exists stats(${global_key}_area)] ? $stats(${global_key}_area) / ($dbu_per_uu * $dbu_per_uu) : 0}]]
            set local_areas($cell_type) [format "%.3f" [expr {[info exists stats(${local_key}_area)] ? $stats(${local_key}_area) / ($dbu_per_uu * $dbu_per_uu) : 0}]]
            set global_insts($cell_type) [format "%d" [expr {[info exists stats(${global_key}_inst)] ? $stats(${global_key}_inst) : 0}]]
            set local_insts($cell_type) [format "%d" [expr {[info exists stats(${local_key}_inst)] ? $stats(${local_key}_inst) : 0}]]
        }

        report_puts [format "%-*s $format_string" \
        $max_width "$indent$display_name" \
        $global_areas(total) $global_areas(stdcell) $global_areas(macro) $global_areas(cover) $global_areas(pad) \
        $global_insts(total) $global_insts(stdcell) $global_insts(macro) $global_insts(cover) $global_insts(pad) \
        $local_areas(total) $local_areas(stdcell) $local_areas(macro) $local_areas(cover) $local_areas(pad) \
        $local_insts(total) $local_insts(stdcell) $local_insts(macro) $local_insts(cover) $local_insts(pad) \
        ]
    }

    # -----------------------------------------------------------------------
    # I2C Pin & Sub-module Summary
    # Printed after the hierarchy table whenever i_i2c is present.
    # -----------------------------------------------------------------------
    set i2c_found 0
    foreach h $sorted_hierarchies {
        if {[string match "*i_i2c" $h]} { set i2c_found 1; break }
    }
    if {$i2c_found} {
        report_puts ""
        report_puts "================================================================================"
        report_puts "I2C Master Pin Summary  (instance: ...i_user/i_i2c)"
        report_puts "================================================================================"
        report_puts ""
        report_puts "  Open-drain model: OE=1 pulls line LOW; OE=0 releases (external pull-up)"
        report_puts ""
        report_puts "  Chip top-level ports (bidirectional inout pads):"
        report_puts "    i2c_sda_io  \[inout\] -- pad_i2c_sda_io (sg13g2_IOPadInOut30mA)"
        report_puts "    i2c_scl_io  \[inout\] -- pad_i2c_scl_io (sg13g2_IOPadInOut30mA)"
        report_puts ""
        report_puts "  Internal signals (croc_chip -> croc_soc -> user_domain -> i_i2c):"
        report_puts "  +------------------+--------+--------------------------------------------+"
        report_puts "  | Signal           | Dir    | Description                                |"
        report_puts "  +------------------+--------+--------------------------------------------+"
        report_puts "  | i2c_sda_i        | input  | SDA sampled from pad (after pull-up)       |"
        report_puts "  | i2c_sda_o        | output | Always 0; line driven low when sda_oe=1    |"
        report_puts "  | i2c_sda_oe       | output | 1=pull SDA low (START/data/STOP bits)      |"
        report_puts "  | i2c_scl_i        | input  | SCL sampled from pad (clock-stretch detect)|"
        report_puts "  | i2c_scl_o        | output | Always 0; line driven low when scl_oe=1    |"
        report_puts "  | i2c_scl_oe       | output | 1=pull SCL low (controls SCL timing)       |"
        report_puts "  +------------------+--------+--------------------------------------------+"
        report_puts ""
        report_puts "  i_i2c sub-module hierarchy:"
        report_puts "    i_clkgen  -- SCL prescaler (16-bit divider -> clk_en pulses)"
        report_puts "    i_ctrl    -- Bit-level FSM  (START/STOP/WR/RD/ACK states)"
        report_puts "    i_regif   -- OBI register interface (PRESCALER/CTR/TXR/RXR/CR/SR)"
        report_puts ""
        report_puts "  OBI Register Map (byte offset, 32-bit word access):"
        report_puts "    0x00  PRESCALER_LO  [7:0]  SCL divider low byte"
        report_puts "    0x04  PRESCALER_HI  [7:0]  SCL divider high byte"
        report_puts "    0x08  CTR           [7]=EN (core enable), [6]=IEN (interrupt enable)"
        report_puts "    0x0C  TXR           [7:0]  transmit register (addr+RW or data)"
        report_puts "    0x10  RXR           [7:0]  receive register  (read-only)"
        report_puts "    0x14  CR            [7]=STA [6]=STO [5]=RD [4]=WR [3]=ACK [0]=IACK"
        report_puts "    0x18  SR            [7]=RxACK [6]=BUSY [5]=AL [1]=TIP [0]=IF"
        report_puts ""
        report_puts "  Default: prescaler=0x00F9(249) -> SCL=50MHz/(2*250)=100kHz (standard I2C)"
        report_puts "================================================================================"
    }
}

# Save the report to a CSV file
proc save_report_csv {sorted_hierarchies filename stats_ref block_ref dbu_per_uu} {
    upvar $stats_ref stats
    upvar $block_ref block

    # Set up report directory and filename
    if { ![info exists report_dir] } { set report_dir "reports" }
    if { ![info exists filename] } {
        set filename "$report_dir/croc.area.csv"
    }
    set fileId [open $filename w]

    set die_bbox [$block getDieArea]
    set die_area [expr [$die_bbox dx] * [$die_bbox dy]]
    set core_bbox [$block getCoreArea]
    set core_area [expr [$core_bbox dx] * [$core_bbox dy]]

    set die_area [expr $die_area / [expr $dbu_per_uu * $dbu_per_uu]]
    set core_area [expr $core_area / [expr $dbu_per_uu * $dbu_per_uu]]
    set num_ios [llength [$block getBTerms]]

    set total_area [expr $stats(<top>:total_global_area) / [expr $dbu_per_uu * $dbu_per_uu]]
    set stdcell_area [expr $stats(<top>:stdcell_global_area) / [expr $dbu_per_uu * $dbu_per_uu]]
    set macro_area [expr $stats(<top>:macro_global_area) / [expr $dbu_per_uu * $dbu_per_uu]]
    set cover_area [expr $stats(<top>:cover_global_area) / [expr $dbu_per_uu * $dbu_per_uu]]
    set pad_area [expr $stats(<top>:pad_global_area) / [expr $dbu_per_uu * $dbu_per_uu]]

    set total_active_area [expr $stdcell_area + $macro_area]

    if { $core_area > 0 } {
        set core_util [expr $total_active_area / $core_area]
        if { $core_area > $macro_area } {
        set stdcell_util [expr $stdcell_area / [expr $core_area - $macro_area]]
        } else {
        set stdcell_util 0.0
        }
    } else {
        set core_util -1.0
        set stdcell_util -1.0
    }

    set format_string [string repeat ",%s" 20]

    puts $fileId [format "%s$format_string" \
        "Hierarchy Name" \
        "Total Global Area" "StdCell Global Area" "Macro Global Area" "Cover Global Area" "Pad Global Area" \
        "Total Global Instances" "StdCell Global Instances" "Macro Global Instances" "Cover Global Instances" "Pad Global Instances" \
        "Total Local Area" "StdCell Local Area" "Macro Local Area" "Cover Local Area" "Pad Local Area" \
        "Total Local Instances" "StdCell Local Instances" "Macro Local Instances" "Cover Local Instances" "Pad Local Instances" \
    ]

    foreach hierarchy $sorted_hierarchies {
        foreach cell_type {total macro cover pad stdcell} {
            set global_key "${hierarchy}:${cell_type}_global"
            set local_key "${hierarchy}:${cell_type}_local"

            set global_areas($cell_type) [format "%.3f" [expr {[info exists stats(${global_key}_area)] ? $stats(${global_key}_area) / ($dbu_per_uu * $dbu_per_uu) : 0}]]
            set local_areas($cell_type) [format "%.3f" [expr {[info exists stats(${local_key}_area)] ? $stats(${local_key}_area) / ($dbu_per_uu * $dbu_per_uu) : 0}]]
            set global_insts($cell_type) [format "%d" [expr {[info exists stats(${global_key}_inst)] ? $stats(${global_key}_inst) : 0}]]
            set local_insts($cell_type) [format "%d" [expr {[info exists stats(${local_key}_inst)] ? $stats(${local_key}_inst) : 0}]]
        }

        puts $fileId [format "%s$format_string" \
        "$hierarchy" \
        "$global_areas(total)" "$global_areas(stdcell)" "$global_areas(macro)" "$global_areas(cover)" "$global_areas(pad)" \
        "$global_insts(total)" "$global_insts(stdcell)" "$global_insts(macro)" "$global_insts(cover)" "$global_insts(pad)" \
        "$local_areas(total)" "$local_areas(stdcell)" "$local_areas(macro)" "$local_areas(cover)" "$local_areas(pad)" \
        "$local_insts(total)" "$local_insts(stdcell)" "$local_insts(macro)" "$local_insts(cover)" "$local_insts(pad)" \
        ]
    }

    close $fileId
}


sta::define_cmd_args "report_area_hierarchical" { [-csv] [-filenameCSV filename]}
proc report_area_hierarchical {args} {
    sta::parse_key_args "check_antennas" args \
    keys {-filenameCSV} \
    flags {-csv}

    upvar 1 when when
    upvar 1 filename filename

    # Get database references
    set db [::ord::get_db]
    set block [[$db getChip] getBlock]
    set dbu_per_uu [expr double([[$db getTech] getDbUnitsPerMicron])]

    # Initialize statistics dictionary
    array set stats {}

    # Clear the stats array
    foreach key [array names stats] {
        unset stats($key)
    }

    # Collect statistics per hierarchy level
    foreach inst [$block getInsts] {
        set inst_master [$inst getMaster]
        if { [$inst_master isFiller] } continue

        set inst_area [expr [$inst_master getWidth] * [$inst_master getHeight]]
        set inst_path [$inst getName]
        regsub -all {\\/} $inst_path _ inst_path
        set inst_path "<top>/$inst_path"
        set parent_hierarchy [join [lrange [split $inst_path "/"] 0 end-1] "/"]

        set type [expr {
            [$inst_master isBlock] ? "macro" :
            [$inst_master isCover] ? "cover" :
            [$inst_master isPad] ? "pad" : "stdcell"
        }]

        foreach suffix {area inst} {
            incr stats(${parent_hierarchy}:${type}_local_$suffix) [expr {$suffix eq "area" ? $inst_area : 1}]
            incr stats(${parent_hierarchy}:total_local_$suffix) [expr {$suffix eq "area" ? $inst_area : 1}]
        }
    }

    # Sort hierarchies
    set sorted_hierarchies [sort_hierarchy stats]

    # Expand paths to include all parent hierarchies
    expand_paths $sorted_hierarchies stats
    set sorted_hierarchies [sort_hierarchy stats]

    # Accumulate totals for parent hierarchies
    accumulate_totals $sorted_hierarchies stats

    if { [info exists flags(-csv)] } {
        if { ![info exists keys(-filenameCSV)] } {
            set keys(-filenameCSV) "croc.area.csv"
        }
        save_report_csv $sorted_hierarchies $keys(-filenameCSV) stats block $dbu_per_uu
    } else {
        # Print the hierarchical area report
        print_report $sorted_hierarchies stats block $dbu_per_uu
    }
}


################################################################################
# Example usage
################################################################################
# load_checkpoint "07_croc.final"
# report_area_hierarchical
# report_area_hierarchical -csv -filenameCSV "reports/croc.area.csv"