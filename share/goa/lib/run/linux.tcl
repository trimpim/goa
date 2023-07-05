proc run_genode { } {
	global run_dir

	set orig_pwd [pwd]
	cd $run_dir
	eval spawn -noecho ./core
	cd $orig_pwd

	set timeout -1
	interact {
		\003 {
			send_user "Expect: 'interact' received 'strg+c' and was cancelled\n";
			exit
		}
		-i $spawn_id
	}
}


proc base_archives { } {
	global run_as

	return [list "$run_as/src/base-linux"]
}


proc bind_provided_services { &services } {
	# use upvar to access array
	upvar 1 ${&services} services

	# make sure to declare variables locally
	variable start_nodes routes archives modules

	set start_nodes { }
	set routes { }
	set archives { }
	set modules { }

	# instantiate NIC driver in uplink mode if required by runtime
	if {[info exists services(uplink)]} {
		if { [llength ${services(uplink)}] > 1 } {
			log "Ignoring all but the first provided <uplink/> service." }

		set uplink_node [lindex ${services(uplink)} 0]
		set uplink_label [query_from_string string(/uplink/@label) $uplink_node ""]

		append routes "\n\t\t\t\t\t" {<service name="Uplink"/>}

		_instantiate_uplink_client $uplink_label start_nodes archives modules

		unset services(uplink)
	}

	return [list $start_nodes $routes $archives $modules]
}


proc bind_required_services { &services } {
	# use upvar to access array
	upvar 1 ${&services} services

	# make sure to declare variables locally
	variable start_nodes routes archives modules

	set routes { }
	set start_nodes { }
	set archives { }
	set modules { }

	# route trace to parent if required by runtime
	if {[info exists services(trace)]} {
		append routes "\n\t\t\t\t\t" \
		              "<service name=\"TRACE\"> " \
		              "<parent/> " \
		              "</service>"
		unset services(trace)
	}

	# route RM to parent if required by runtime
	if {[info exists services(rm)]} {
		append routes "\n\t\t\t\t\t" \
		              "<service name=\"RM\"> " \
		              "<parent/> " \
		              "</service>"
		unset services(rm)
	}

	# always instantiate timer
	_instantiate_timer start_nodes archives modules

	# route timer if required by runtime
	if {[info exists services(timer)]} {
		append routes "\n\t\t\t\t\t" \
		              "<service name=\"Timer\"> " \
		              "<child name=\"timer\"/> " \
		              "</service>"
		unset services(timer)
	}

	# route nitpicker services if required by runtime
	set use_nitpicker 0
	if {[info exists services(event)]} {
		set use_nitpicker 1
		append routes "\n\t\t\t\t\t" \
		              "<service name=\"Event\"> " \
		              "<child name=\"nitpicker\"/> " \
		              "</service>"
		unset services(event)
	}

	if {[info exists services(capture)]} {
		set use_nitpicker 1
		append routes "\n\t\t\t\t\t" \
		              "<service name=\"Capture\"> " \
		              "<child name=\"nitpicker\"/> " \
		              "</service>"
		unset services(capture)
	}

	if {[info exists services(gui)]} {
		set use_nitpicker 1
		append routes "\n\t\t\t\t\t" \
		              "<service name=\"Gui\"> " \
		              "<child name=\"nitpicker\"/> " \
		              "</service>"
		unset services(gui)
	}

	if {$use_nitpicker} {
		_instantiate_nitpicker start_nodes archives modules }

	##
	# instantiate NIC router and driver if required by runtime
	if {[info exists services(nic)]} {
		if {[llength ${services(nic)}] > 1} {
			log "Ignoring all but the first <nic/> requirement." }

		set nic_node [lindex ${services(nic)} 0]
		set nic_label [query_from_string string(/nic/@label) $nic_node ""]

		append routes "\n\t\t\t\t\t" \
			{<service name="Nic"> <child name="nic_router"/> </service>}

		_instantiate_network $nic_label start_nodes archives modules

		unset services(nic)
	}

	##
	# instantiate file systems
	if {[info exists services(file_system)]} {
		foreach fs_node $services(file_system) {
			variable label writeable name

			set label     [query_from_string string(*/@label)     $fs_node  ""]
			set writeable [query_from_string string(*/@writeable) $fs_node  "no"]
			set name      "${label}_fs"

			append routes "\n\t\t\t\t\t" \
				"<service name=\"File_system\" label=\"$label\"> " \
				"<child name=\"$name\"/> " \
				"</service>"

			if {$label == "fonts"} {
				_instantiate_fonts_fs start_nodes archives modules
			} else {
				_instantiate_file_system $name $label $writeable start_nodes archives modules
			}
		}

		global run_dir var_dir
		# link all file systems to run_dir
		file link -symbolic "$run_dir/fs" "$var_dir/fs"

		unset services(file_system)
	}

	##
	# instantiate rtc driver if required by runtime
	if {[info exists services(rtc)]} {
		if {[llength ${services(rtc)}] > 1} {
			log "Ignoring all but the first required <rtc/> service" }

		append routes "\n\t\t\t\t\t" \
		              "<service name=\"Rtc\"> " \
		              "<child name=\"rtc_drv\"/> " \
		              "</service>"

		_instantiate_rtc start_nodes archives modules

		unset services(rtc)
	}

	##
	# add mesa gpu route if required by runtime
	if {[info exists services(rom)]} {
		set i [lsearch -regexp ${services(rom)} {label="mesa_gpu_drv.lib.so"}]
		set services(rom) [lreplace ${services(rom)} $i $i]

		append routes "\n\t\t\t\t\t" \
		              "<service name=\"ROM\" label=\"mesa_gpu_drv.lib.so\"> " \
		              "<parent label=\"mesa_gpu-softpipe.lib.so\"/> " \
		              "</service>"

		lappend modules mesa_gpu-softpipe.lib.so
	}

	##
	# instantiate report_rom for if clipboard Report or ROM required by runtime
	set clipboard_rom_node ""
	set clipboard_report_node ""
	if {[info exists services(rom)]} {
		set i [lsearch -regexp ${services(rom)} {label="clipboard"}]
		set clipboard_rom_node [lindex ${services(rom)} $i]
		set services(rom) [lreplace ${services(rom)} $i $i]
	}
	if {[info exists services(report)]} {
		set i [lsearch -regexp ${services(report)} {label="clipboard"}]
		set clipboard_report_node [lindex ${services(report)} $i]
		set services(report) [lreplace ${services(report)} $i $i]
	}

	if {$clipboard_rom_node != ""} {
		append routes {
					<service name="ROM" label="clipboard">} \
					{ <child name="clipboard"/> </service>}
	}

	if {$clipboard_report_node != ""} {
		append routes {
					<service name="Report" label="clipboard">} \
					{ <child name="clipboard"/> </service>}
	}

	if {$clipboard_rom_node != "" || $clipboard_report_node != ""} {
		_instantiate_clipboard start_nodes archives modules }

	##
	# instantiate external ROMs if required by runtime
	if {[info exists services(rom)]} {
		set provided_external_rom 0
		foreach rom_node $services(rom) {
			variable label_node label

			set label_node [query_from_string string(*/@label) $rom_node  ""]

			# here we only handle ROMs with a label
			if {$label_node == ""} { continue }

			set label [lindex [split [split $label_node "="] "\""] 0]

			set i [lsearch -regexp ${services(rom)} "label=\"$label\""]
			set services(rom) [lreplace ${services(rom)} $i $i]

			append routes "\n\t\t\t\t\t" \
			              "<service name=\"ROM\" label=\"$label\"> " \
			              "<child name=\"rom\"/> " \
			              "</service>"
			incr provided_external_rom
		}

		# only start one instance of the components
		if {$provided_external_rom > 0} {
			_instantiate_rom_provider start_nodes archives modules

			# link the rom directory
			global run_dir var_dir
			file link -symbolic "$run_dir/rom" "$var_dir/rom"
		}
	}

	return [list $start_nodes $routes $archives $modules ]
}


proc _instantiate_timer { &start_nodes &archives &modules } {
	upvar 1 ${&start_nodes} start_nodes
	upvar 1 ${&archives} archives
	upvar 1 ${&modules} modules

	append start_nodes {
			<start name="timer" caps="100">
				<resource name="RAM" quantum="1M"/>
				<provides><service name="Timer"/></provides>
				<route>
					<service name="PD">  <parent/> </service>
					<service name="CPU"> <parent/> </service>
					<service name="LOG"> <parent/> </service>
					<service name="ROM"> <parent/> </service>
				</route>
			</start>
	}

	lappend modules timer
}


proc _instantiate_nitpicker { &start_nodes &archives &modules } {
	upvar 1 ${&start_nodes} start_nodes
	upvar 1 ${&archives} archives
	upvar 1 ${&modules} modules

	global run_as

	append start_nodes {
			<start name="drivers" caps="1000">
				<resource name="RAM" quantum="32M" constrain_phys="yes"/>
				<binary name="init"/>
				<route>
					<service name="ROM" label="config"> <parent label="drivers.config"/> </service>
					<service name="Timer">   <child name="timer"/> </service>
					<service name="Capture"> <child name="nitpicker"/> </service>
					<service name="Event">   <child name="nitpicker"/> </service>
					<any-service> <parent/> </any-service>
				</route>
			</start>

			<start name="report_rom" caps="100">
				<resource name="RAM" quantum="1M"/>
				<provides> <service name="Report"/> <service name="ROM"/> </provides>
				<config verbose="no">
					<policy label_prefix="focus_rom" report="nitpicker -> hover"/>
				</config>
				<route>
					<service name="PD">  <parent/> </service>
					<service name="CPU"> <parent/> </service>
					<service name="LOG"> <parent/> </service>
					<service name="ROM"> <parent/> </service>
				</route>
			</start>

			<start name="focus_rom" caps="100">
				<binary name="rom_filter"/>
				<resource name="RAM" quantum="1M"/>
				<provides> <service name="ROM"/> </provides>
				<config>
					<input name="hovered_label" rom="hover" node="hover">
						<attribute name="label" />
					</input>
					<output node="focus">
						<attribute name="label" input="hovered_label"/>
					</output>
				</config>
				<route>
					<service name="ROM" label="hover"> <child name="report_rom"/> </service>
					<service name="PD">  <parent/> </service>
					<service name="CPU"> <parent/> </service>
					<service name="LOG"> <parent/> </service>
					<service name="ROM"> <parent/> </service>
				</route>
			</start>

			<start name="nitpicker" caps="100">
				<resource name="RAM" quantum="4M"/>
				<provides>
					<service name="Gui"/> <service name="Capture"/> <service name="Event"/>
				</provides>
				<route>
					<service name="ROM" label="focus"> <child name="focus_rom"/> </service>
					<service name="PD">  <parent/> </service>
					<service name="CPU"> <parent/> </service>
					<service name="LOG"> <parent/> </service>
					<service name="ROM"> <parent/> </service>
					<service name="Timer">  <child name="timer"/> </service>
					<service name="Report"> <child name="report_rom"/> </service>
				</route>
				<config focus="rom">
					<capture/> <event/>
					<report hover="yes"/>
					<domain name="pointer" layer="1" content="client" label="no" origin="pointer" />
					<domain name="default" layer="2" content="client" label="no" hover="always"/>

					<policy label_prefix="pointer" domain="pointer"/>
					<default-policy domain="default"/>
				</config>
			</start>

			<start name="pointer" caps="100">
				<resource name="RAM" quantum="1M"/>
				<route>
					<service name="PD">  <parent/> </service>
					<service name="CPU"> <parent/> </service>
					<service name="LOG"> <parent/> </service>
					<service name="ROM"> <parent/> </service>
					<service name="Gui"> <child name="nitpicker"/> </service>
				</route>
				<config/>
			</start>
	}

	lappend modules nitpicker \
	                pointer \
	                fb_sdl \
	                event_filter \
	                drivers.config \
	                event_filter.config \
	                en_us.chargen \
	                special.chargen \
	                report_rom \
	                rom_filter

	lappend archives "$run_as/src/nitpicker"
	lappend archives "$run_as/src/report_rom"
	lappend archives "$run_as/src/rom_filter"
	lappend archives "$run_as/pkg/drivers_interactive-linux"
}


proc _instantiate_network { nic_label &start_nodes &archives &modules } {
	upvar 1 ${&start_nodes} start_nodes
	upvar 1 ${&archives} archives
	upvar 1 ${&modules} modules

	global run_as

	append start_nodes {
			<start name="nic_drv" caps="100" ld="no">
				<binary name="linux_nic_drv"/>
				<resource name="RAM" quantum="4M"/>
				<provides> <service name="Nic"/> </provides>}
	if {$nic_label != ""} {
		append start_nodes {
				<config tap="} $nic_label {"/>}
	}
	append start_nodes {
				<route>
					<service name="Uplink"> <child name="nic_router"/> </service>
					<any-service> <parent/> </any-service>
				</route>
			</start>

			<start name="nic_router" caps="200">
				<resource name="RAM" quantum="10M"/>
				<provides>
					<service name="Uplink"/>
					<service name="Nic"/>
				</provides>
				<config verbose_domain_state="yes">
					<default-policy domain="default"/>
					<policy label="nic_drv -> " domain="uplink"/>
					<domain name="uplink">
						<nat domain="default" tcp-ports="1000" udp-ports="1000" icmp-ids="1000"/>
					</domain>
					<domain name="default" interface="10.0.1.1/24">
						<dhcp-server ip_first="10.0.1.2" ip_last="10.0.1.253"/>
						<tcp dst="0.0.0.0/0">
							<permit-any domain="uplink"/>
						</tcp>
						<udp dst="0.0.0.0/0">
							<permit-any domain="uplink"/>
						</udp>
						<icmp dst="0.0.0.0/0" domain="uplink"/>
					</domain>
				</config>
				<route>
					<service name="Timer"> <child name="timer"/> </service>
					<any-service> <parent/> </any-service>
				</route>
			</start>
	}

	lappend modules linux_nic_drv nic_router

	lappend archives "$run_as/src/linux_nic_drv"
	lappend archives "$run_as/src/nic_router"
}


proc _instantiate_uplink_client { uplink_label &start_nodes &archives &modules } {
	upvar 1 ${&start_nodes} start_nodes
	upvar 1 ${&archives} archives
	upvar 1 ${&modules} modules

	global project_name run_as

	append start_nodes "\n" {
			<start name="nic_drv" caps="100" ld="no">
				<binary name="linux_nic_drv"/>
				<resource name="RAM" quantum="4M"/>
				<provides> <service name="Uplink"/> </provides>}
	if {$uplink_label != ""} {
		append start_nodes {
				<config tap="} $uplink_label {"/>}
	}
	append start_nodes {
				<route>
					<service name="Uplink"> <child name="} $project_name {"/> </service>
					<any-service> <parent/> </any-service>
				</route>
			</start>
	}

	lappend modules linux_nic_drv

	lappend archives "$run_as/src/linux_nic_drv"
}


proc _instantiate_fonts_fs { &start_nodes &archives &modules } {
	upvar 1 ${&start_nodes} start_nodes
	upvar 1 ${&archives} archives
	upvar 1 ${&modules} modules

	global run_as

	append start_nodes {
		<start name="fonts_fs" caps="100">
			<binary name="vfs"/>
			<resource name="RAM" quantum="2M"/>
			<provides> <service name="File_system"/> </provides>
			<route>
				<service name="ROM" label="config"> <parent label="fonts_fs.config"/> </service>
				<service name="PD">  <parent/> </service>
				<service name="CPU"> <parent/> </service>
				<service name="LOG"> <parent/> </service>
				<service name="ROM"> <parent/> </service>
			</route>
		</start>
	}

	lappend modules vfs fonts_fs.config

	lappend archives $run_as/pkg/fonts_fs
}


proc _instantiate_file_system { name label writeable &start_nodes &archives &modules } {
	upvar 1 ${&start_nodes} start_nodes
	upvar 1 ${&archives} archives
	upvar 1 ${&modules} modules

	global var_dir run_as

	append start_nodes {
			<start name="} $name {" caps="100" ld="no">
				<binary name="lx_fs"/>
				<resource name="RAM" quantum="1M"/>
				<provides> <service name="File_system"/> </provides>
				<config>
					<default-policy root="/fs/} $label {" writeable="} $writeable {" />
				</config>
				<route>
					<service name="PD">  <parent/> </service>
					<service name="CPU"> <parent/> </service>
					<service name="LOG"> <parent/> </service>
					<service name="ROM"> <parent/> </service>
				</route>
			</start>
	}

	# create folder in var_dir
	set fs_dir "$var_dir/fs/$label"
	if {![file isdirectory $fs_dir]} {
		log "creating file-system directory $fs_dir"
		file mkdir $fs_dir
	}

	lappend modules lx_fs

	lappend archives "$run_as/src/lx_fs"
}


proc _instantiate_rom_provider { &start_nodes &archives &modules } {
	upvar 1 ${&start_nodes} start_nodes
	upvar 1 ${&archives} archives
	upvar 1 ${&modules} modules

	global run_as var_dir

	append start_nodes {
			<start name="rom_fs" ld="no" caps="100">
				<binary name="lx_fs"/>
				<resource name="RAM" quantum="1M"/>
				<provides> <service name="File_system"/> </provides>
				<config>
					<default-policy root="/rom" writeable="no"/>
				</config>
				<route>
					<service name="CPU"> <parent/> </service>
					<service name="LOG"> <parent/> </service>
					<service name="PD">  <parent/> </service>
					<service name="ROM"> <parent/> </service>
				</route>
			</start>
			<start name="rom" caps="100">
				<binary name="fs_rom"/>
				<resource name="RAM" quantum="1M"/>
				<provides> <service name="ROM"/> </provides>
				<config/>
				<route>
					<service name="File_system"> <child name="rom_fs"/> </service>
					<service name="CPU"> <parent/> </service>
					<service name="LOG"> <parent/> </service>
					<service name="PD">  <parent/> </service>
					<service name="ROM"> <parent/> </service>
				</route>
			</start>
	}

	# create folder in var_dir
	set fs_dir "$var_dir/rom"
	if {![file isdirectory $fs_dir]} {
		log "creating file-system directory $fs_dir"
		file mkdir $fs_dir
	}

	lappend modules fs_rom lx_fs

	lappend archives $run_as/src/fs_rom
	lappend archives $run_as/src/lx_fs
}


proc _instantiate_rtc { &start_nodes &archives &modules } {
	upvar 1 ${&start_nodes} start_nodes
	upvar 1 ${&archives} archives
	upvar 1 ${&modules} modules

	global run_as

	append start_nodes {
			<start name="rtc_drv" caps="100" ld="no">
				<binary name="linux_rtc_drv"/>
				<resource name="RAM" quantum="1M"/>
				<provides> <service name="Rtc"/> </provides>
				<route> <any-service> <parent/> </any-service> </route>
			</start>
	}

	lappend modules linux_rtc_drv

	lappend archives "$run_as/src/linux_rtc_drv"
}


proc _instantiate_clipboard { &start_nodes &archives &modules } {
	upvar 1 ${&start_nodes} start_nodes
	upvar 1 ${&archives} archives
	upvar 1 ${&modules} modules

	global project_name run_as

	append start_nodes {
			<start name="clipboard" caps="100">
				<binary name="report_rom"/>
				<resource name="RAM" quantum="2M"/>
				<provides>
					<service name="Report"/>
					<service name="ROM"/>
				</provides>
				<config verbose="yes">
					<policy label_suffix="clipboard" report="} $project_name { -> clipboard"/>
				</config>
				<route>
					<service name="PD">  <parent/> </service>
					<service name="CPU"> <parent/> </service>
					<service name="LOG"> <parent/> </service>
					<service name="ROM"> <parent/> </service>
				</route>
			</start>
	}

	lappend modules report_rom

	lappend archives "$run_as/src/report_rom"
}
