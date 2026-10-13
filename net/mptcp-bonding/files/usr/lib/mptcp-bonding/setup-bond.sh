#!/bin/sh
# mptcp-bonding client helper — WAN endpoint setup and MPTCP bonding.
#
# Purpose: Enumerate the router's upstream WAN links (Crows-Nest WiFi gateways,
# mobile hotspots, other TollGates) and configure them as MPTCP endpoints
# for bonded multi-path TCP traffic toward the convergence-point VPS.
#
# This script integrates with OpenWrt's network configuration and can be called
# manually or via hotplug events to dynamically manage MPTCP endpoints.

set -eu

SUBFLOWS=2
MPTCP_SYSCTL="/proc/sys/net/mptcp"

usage() {
	cat <<EOF
Usage: setup-bond.sh <action> [options]

Actions:
  setup      [server] [subflows]  Configure MPTCP bonding endpoints
  add        <interface>           Add single interface as MPTCP endpoint  
  remove     <interface>          Remove interface as MPTCP endpoint
  list                             List current MPTCP endpoints
  enable                          Enable MPTCP bonding service
  disable                         Disable MPTCP bonding service
  test-connection <server>        Test connectivity to MPTCP server

Examples:
  setup-bond.sh setup 192.168.1.100 3
  setup-bond.sh add wan0
  setup-bond.sh list
  setup-bond.sh enable
EOF
}

# Check if MPTCP is available in kernel
check_mptcp_support() {
	if [ ! -d "$MPTCP_SYSCTL" ]; then
		echo "ERROR: MPTCP not supported by kernel" >&2
		return 1
	fi
	
	if ! command -v ip >/dev/null 2>&1; then
		echo "ERROR: ip command not found" >&2
		return 1
	fi
	
	if ! ip mptcp help 2>/dev/null | grep -q "endpoint"; then
		echo "ERROR: ip mptcp endpoint commands not available" >&2
		return 1
	fi
	
	return 0
}

# Get list of active WAN interfaces from OpenWrt network config
get_wan_interfaces() {
	local interfaces=""
	
	if command -v uci >/dev/null 2>&1; then
		# Get all network interfaces marked as wan or with wan role
		uci show network | grep -E 'network\.(\w+)\.interface=(wan|multiwan)' | cut -d. -f2 | sort -u
	else
		# Fallback: common WAN interface names
		for iface in wan wan0 wan1 wan2 wwan0 wwan1 eth1 eth2; do
			if [ -d "/sys/class/net/$iface" ]; then
				echo "$iface"
			fi
		done
	fi
}

# Get IP address for an interface
get_interface_ip() {
	local interface="$1"
	
	if [ -z "$interface" ]; then
		return 1
	fi
	
	# Use OpenWrt network functions if available
	if [ -f "/lib/functions/network.sh" ]; then
		. /lib/functions/network.sh
		network_get_ipaddr ip "$interface"
		echo "$ip"
	else
		# Fallback to ip command
		ip -4 addr show "$interface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1
	fi
}

# Check if interface has connectivity
test_interface_connectivity() {
	local interface="$1"
	local test_ip="8.8.8.8"
	
	if [ -z "$interface" ]; then
		return 1
	fi
	
	# Ping through the interface
	ping -I "$interface" -c 1 -W 2 "$test_ip" >/dev/null 2>&1
}

# Add MPTCP endpoint for an interface
add_mptcp_endpoint() {
	local interface="$1"
	local ipaddr
	
	if [ -z "$interface" ]; then
		echo "ERROR: interface name required" >&2
		return 1
	fi
	
	ipaddr=$(get_interface_ip "$interface")
	if [ -z "$ipaddr" ]; then
		echo "ERROR: no IP address found for $interface" >&2
		return 1
	fi
	
	# Check if endpoint already exists
	if ip mptcp endpoint show 2>/dev/null | grep -q "$ipaddr.*$interface"; then
		echo "MPTCP endpoint $ipaddr on $interface already exists"
		return 0
	fi
	
	# Add the endpoint
	if ip mptcp endpoint add "$ipaddr" dev "$interface" subflow 2>/dev/null; then
		echo "Added MPTCP endpoint $ipaddr on $interface"
		return 0
	else
		echo "ERROR: failed to add MPTCP endpoint $ipaddr on $interface" >&2
		return 1
	fi
}

# Remove MPTCP endpoint for an interface
remove_mptcp_endpoint() {
	local interface="$1"
	local ipaddr
	
	if [ -z "$interface" ]; then
		echo "ERROR: interface name required" >&2
		return 1
	fi
	
	ipaddr=$(get_interface_ip "$interface")
	if [ -z "$ipaddr" ]; then
		echo "WARNING: no IP address found for $interface" >&2
		return 0
	fi
	
	# Remove the endpoint
	if ip mptcp endpoint del "$ipaddr" dev "$interface" 2>/dev/null; then
		echo "Removed MPTCP endpoint $ipaddr on $interface"
		return 0
	else
		echo "WARNING: failed to remove MPTCP endpoint $ipaddr on $interface" >&2
		return 1
	fi
}

# List current MPTCP endpoints
list_mptcp_endpoints() {
	echo "Current MPTCP endpoints:"
	ip mptcp endpoint show 2>/dev/null || echo "  No MPTCP endpoints configured"
}

# Set up MPTCP bonding for all WAN interfaces
setup_mptcp_bonding() {
	local server="$1"
	local subflows="${2:-$SUBFLOWS}"
	local wan_interfaces
	local success_count=0
	
	if [ -z "$server" ]; then
		echo "ERROR: server address required" >&2
		usage
		return 1
	fi
	
	echo "Setting up MPTCP bonding for server: $server ($subflows subflows)"
	
	# Get list of WAN interfaces
	wan_interfaces=$(get_wan_interfaces)
	if [ -z "$wan_interfaces" ]; then
		echo "ERROR: no WAN interfaces found" >&2
		return 1
	fi
	
	echo "Found WAN interfaces: $wan_interfaces"
	
	# Apply subflow limit to running kernel
	if [ -w "$MPTCP_SYSCTL/subflows" ]; then
		echo "$subflows" > "$MPTCP_SYSCTL/subflows"
		echo "Set net.mptcp.subflows = $subflows"
	else
		echo "WARNING: cannot set subflows (kernel sysctl not writable)"
	fi
	
	# Clear existing endpoints
	echo "Clearing existing MPTCP endpoints..."
	ip mptcp endpoint flush 2>/dev/null || true
	
	# Add endpoints for each WAN interface
	for interface in $wan_interfaces; do
		if [ -d "/sys/class/net/$interface" ]; then
			if test_interface_connectivity "$interface"; then
				if add_mptcp_endpoint "$interface"; then
					success_count=$((success_count + 1))
				fi
			else
				echo "WARNING: $interface has no connectivity, skipping"
			fi
		else
			echo "WARNING: interface $interface not found, skipping"
		fi
	done
	
	if [ $success_count -eq 0 ]; then
		echo "ERROR: failed to add any MPTCP endpoints" >&2
		return 1
	fi
	
	echo "Successfully added $success_count MPTCP endpoints"
	
	# Update UCI configuration if available
	if command -v uci >/dev/null 2>&1; then
		uci -q set mptcp-bonding.main.server="$server"
		uci -q set mptcp-bonding.main.subflows="$subflows"
		uci -q set mptcp-bonding.main.enabled=1
		uci commit mptcp-bonding
		echo "Updated /etc/config/mptcp-bonding -> server=$server, subflows=$subflows"
	fi
	
	return 0
}

# Enable MPTCP bonding service
enable_mptcp_bonding() {
	if command -v /etc/init.d/mptcp-bonding >/dev/null 2>&1; then
		/etc/init.d/mptcp-bonding enable
		/etc/init.d/mptcp-bonding start
		echo "MPTCP bonding service enabled and started"
	else
		echo "WARNING: mptcp-bonding init script not found"
	fi
}

# Disable MPTCP bonding service
disable_mptcp_bonding() {
	if command -v /etc/init.d/mptcp-bonding >/dev/null 2>&1; then
		/etc/init.d/mptcp-bonding stop
		/etc/init.d/mptcp-bonding disable
		echo "MPTCP bonding service stopped and disabled"
	fi
	
	# Clear MPTCP endpoints
	ip mptcp endpoint flush 2>/dev/null || true
	echo "Cleared MPTCP endpoints"
}

# Test connectivity to MPTCP server
test_server_connection() {
	local server="$1"
	local port="${2:-65101}"
	
	if [ -z "$server" ]; then
		echo "ERROR: server address required" >&2
		return 1
	fi
	
	echo "Testing connectivity to $server:$port"
	
	if nc -z -w 3 "$server" "$port" 2>/dev/null; then
		echo "SUCCESS: Connection to $server:$port is reachable"
		return 0
	else
		echo "ERROR: Cannot connect to $server:$port" >&2
		return 1
	fi
}

# Main script logic
main() {
	local action="$1"
	
	[ $# -ge 1 ] || { usage; exit 2; }
	
	# Check MPTCP support
	check_mptcp_support || exit 1
	
	case "$action" in
		setup)
			[ $# -ge 2 ] || { echo "ERROR: server address required" >&2; usage; exit 2; }
			setup_mptcp_bonding "$2" "$3"
			;;
		add)
			[ $# -ge 2 ] || { echo "ERROR: interface name required" >&2; usage; exit 2; }
			add_mptcp_endpoint "$2"
			;;
		remove)
			[ $# -ge 2 ] || { echo "ERROR: interface name required" >&2; usage; exit 2; }
			remove_mptcp_endpoint "$2"
			;;
		list)
			list_mptcp_endpoints
			;;
		enable)
			enable_mptcp_bonding
			;;
		disable)
			disable_mptcp_bonding
			;;
		test-connection)
			[ $# -ge 2 ] || { echo "ERROR: server address required" >&2; usage; exit 2; }
			test_server_connection "$2" "$3"
			;;
		*)
			echo "ERROR: unknown action: $action" >&2
			usage
			exit 2
			;;
	esac
}

# Run main function with all arguments
main "$@"