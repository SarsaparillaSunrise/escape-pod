#!/usr/bin/bash
#
# Network namespace setup script for breaking out of wireguard tunnel
# Adapted from: https://www.procustodibus.com/blog/2023/04/wireguard-netns-for-specific-apps/
#
# This script creates a network namespace that can be used to run applications
# outside of a system-wide VPN/wireguard tunnel.
#
# Usage:
#   ./namespace.sh setup   - Create and configure the namespace
#   ./namespace.sh cleanup - Remove the namespace and cleanup
#   ./namespace.sh status  - Check if namespace exists and is configured

set -eo pipefail

# Configuration
NS_NAME="home"
VETH_HOST="to-home"
VETH_NS="from-home"
IP_HOST="10.99.99.4/31"
IP_NS="10.99.99.5/31"
IP_NS_ONLY="10.99.99.5"
ROUTE_PRIORITY=99
DNS_SERVER="1.1.1.1"

# Logging functions
log_info() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

log_warn() {
    echo -e "\033[0;33m[WARN]\033[0m $1"
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1" >&2
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check if namespace exists
namespace_exists() {
    ip netns list | grep -q "$NS_NAME"
    return $?
}

# Check if veth pair exists
veth_exists() {
    ip link show "$VETH_HOST" &>/dev/null
    return $?
}

# Setup the namespace and networking
setup_namespace() {
    log_info "Setting up network namespace '$NS_NAME'..."
    
    # Create namespace if it doesn't exist
    if ! namespace_exists; then
        log_info "Creating namespace '$NS_NAME'..."
        ip netns add "$NS_NAME"
    else
        log_info "Namespace '$NS_NAME' already exists"
    fi
    
    # Bring up loopback interface
    log_info "Configuring loopback interface..."
    ip -n "$NS_NAME" link set lo up
    
    # Create veth pair if it doesn't exist
    if ! veth_exists; then
        log_info "Creating veth pair..."
        ip link add "$VETH_HOST" type veth peer name "$VETH_NS" netns "$NS_NAME"
    else
        log_info "Veth pair already exists"
    fi
    
    # Configure host side of veth pair
    log_info "Configuring host side of veth pair..."
    ip address add "$IP_HOST" dev "$VETH_HOST" 2>/dev/null || log_warn "IP already assigned to $VETH_HOST"
    ip link set "$VETH_HOST" up
    
    # Configure namespace side of veth pair
    log_info "Configuring namespace side of veth pair..."
    ip -n "$NS_NAME" address add "$IP_NS" dev "$VETH_NS" 2>/dev/null || log_warn "IP already assigned to $VETH_NS"
    ip -n "$NS_NAME" link set "$VETH_NS" up
    ip -n "$NS_NAME" route add default via "${IP_HOST%/*}" 2>/dev/null || log_warn "Default route already exists"
    
    # Add routing rule if it doesn't exist
    if ! ip rule list | grep -q "from $IP_NS_ONLY lookup main"; then
        log_info "Adding routing rule..."
        ip rule add from "$IP_NS_ONLY" table main priority "$ROUTE_PRIORITY"
    else
        log_warn "Routing rule already exists"
    fi
    
    # Configure iptables for NAT and forwarding
    log_info "Configuring iptables rules..."
    
    # Check if rules already exist before adding
    if ! iptables -t nat -C POSTROUTING -s "$IP_NS_ONLY" -j MASQUERADE &>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$IP_NS_ONLY" -j MASQUERADE
    else
        log_warn "NAT rule already exists"
    fi
    
    if ! iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    else
        log_warn "FORWARD established rule already exists"
    fi
    
    if ! iptables -C FORWARD -s "$IP_NS_ONLY" -j ACCEPT &>/dev/null; then
        iptables -A FORWARD -s "$IP_NS_ONLY" -j ACCEPT
    else
        log_warn "FORWARD source rule already exists"
    fi
    
    # Setup DNS
    log_info "Setting up DNS configuration..."
    mkdir -p "/etc/netns/$NS_NAME"
    chmod -R o+rX /etc/netns
    cp /run/systemd/resolve/resolv.conf "/etc/netns/$NS_NAME" 2>/dev/null || \
        log_warn "Could not copy resolv.conf, DNS might not work in namespace"
    
    log_info "Network namespace setup complete!"
    log_info "Test with: sudo ip netns exec $NS_NAME ping -c 1 $DNS_SERVER"
}

# Cleanup the namespace and all related configurations
cleanup_namespace() {
    log_info "Cleaning up network namespace '$NS_NAME'..."
    
    # Remove iptables rules
    if iptables -t nat -C POSTROUTING -s "$IP_NS_ONLY" -j MASQUERADE &>/dev/null; then
        log_info "Removing NAT rule..."
        iptables -t nat -D POSTROUTING -s "$IP_NS_ONLY" -j MASQUERADE
    fi
    
    if iptables -C FORWARD -s "$IP_NS_ONLY" -j ACCEPT &>/dev/null; then
        log_info "Removing FORWARD source rule..."
        iptables -A FORWARD -s "$IP_NS_ONLY" -j ACCEPT
    fi
    
    # We don't remove the ESTABLISHED,RELATED rule as it might be used by other services
    
    # Remove routing rule
    if ip rule list | grep -q "from $IP_NS_ONLY lookup main"; then
        log_info "Removing routing rule..."
        ip rule del from "$IP_NS_ONLY" table main priority "$ROUTE_PRIORITY"
    fi
    
    # Remove veth pair (removing one side removes both)
    if veth_exists; then
        log_info "Removing veth pair..."
        ip link delete "$VETH_HOST"
    fi
    
    # Remove namespace
    if namespace_exists; then
        log_info "Removing namespace..."
        ip netns del "$NS_NAME"
    fi
    
    # Remove DNS config
    if [ -d "/etc/netns/$NS_NAME" ]; then
        log_info "Removing DNS configuration..."
        rm -rf "/etc/netns/$NS_NAME"
    fi
    
    log_info "Cleanup complete!"
}

# Check status of the namespace
check_status() {
    if namespace_exists; then
        log_info "Namespace '$NS_NAME' exists"
        
        # Check if veth pair exists
        if veth_exists; then
            log_info "Veth pair exists and is configured"
        else
            log_warn "Veth pair does not exist or is not properly configured"
        fi
        
        # Check if routing rule exists
        if ip rule list | grep -q "from $IP_NS_ONLY lookup main"; then
            log_info "Routing rule exists"
        else
            log_warn "Routing rule does not exist"
        fi
        
        # Check if iptables rules exist
        if iptables -t nat -C POSTROUTING -s "$IP_NS_ONLY" -j MASQUERADE &>/dev/null; then
            log_info "NAT rule exists"
        else
            log_warn "NAT rule does not exist"
        fi
        
        # Test connectivity from namespace
        log_info "Testing connectivity from namespace..."
        if ip netns exec "$NS_NAME" ping -c1 -W2 "$DNS_SERVER" &>/dev/null; then
            log_info "Connectivity test successful"
        else
            log_warn "Connectivity test failed"
        fi
    else
        log_info "Namespace '$NS_NAME' does not exist"
        return 1
    fi
    
    return 0
}

# Print usage information
print_usage() {
    echo "Usage: $0 {setup|cleanup|status}"
    echo
    echo "Commands:"
    echo "  setup   - Create and configure the network namespace"
    echo "  cleanup - Remove the namespace and all related configurations"
    echo "  status  - Check the status of the namespace"
    echo
    echo "Example usage:"
    echo "  $0 setup"
    echo "  sudo ip netns exec $NS_NAME ping -c1 $DNS_SERVER"
    echo "  sudo ip netns exec $NS_NAME curl icanhazip.com"
}

# Main function
main() {
    check_root
    
    case "$1" in
        setup)
            setup_namespace
            ;;
        cleanup)
            cleanup_namespace
            ;;
        status)
            check_status
            ;;
        *)
            print_usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
