# Escape Pod

A Bash script to create a network namespace that allows specific applications to escape a system-wide Wireguard VPN tunnel.

## Overview

When utilizing a system-wide WireGuard VPN, this tool facilitates the creation of a separate network namespace. This namespace routes traffic through the underlying internet connection, enabling specific applications to bypass the VPN tunnel. This capability is particularly beneficial for accessing endpoints that are blocked by Autonomous System Number (ASN) restrictions.

## Features

- Creates an isolated network namespace
- Sets up proper routing between namespaces
- Configures NAT for outbound connections
- Fully idempotent (can be run multiple times safely)
- Includes cleanup functionality
- Provides status checking

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/SarsaparillaSunrise/escape-pod.git
   cd escape-pod
   ```

2. Install the script:
   ```bash
   sudo cp escape-pod.sh /usr/local/bin/escape-pod
   sudo chmod +x /usr/local/bin/escape-pod
   ```

3. Install the systemd system service (optional):
   # Update wg-quick@INTERFACE.service with your interface name, in both places
   sudo cp escape-pod.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable escape-pod.service
   sudo systemctl start escape-pod.service
   ```

## Usage

### Manual Usage

```bash
# Create and configure the namespace
sudo escape-pod setup

# Check the status of the namespace
sudo escape-pod status

# Remove the namespace and clean up
sudo escape-pod cleanup
```

### Running Applications in the Namespace

To run an application through the regular internet connection (bypassing the VPN):

```bash
sudo ip netns exec home curl ipecho.net/plain
```

For convenience, create an alias in your ~/.bashrc or ~/.zshrc:

```bash
alias novpn='sudo ip netns exec home'
# Then use: novpn curl ipecho.net/plain
```

## Configuration

Edit the script (either ~/.local/bin/escape-pod or /usr/local/bin/escape-pod) to customize:

- `NS_NAME`: Name of the network namespace (default: "home")
- `VETH_HOST`: Name of the host-side virtual interface
- `VETH_NS`: Name of the namespace-side virtual interface
- `IP_HOST`: IP address for the host-side interface
- `IP_NS`: IP address for the namespace-side interface
- `DNS_SERVER`: IP address for the DNS server

## Troubleshooting

If you encounter issues:

```bash
# Check namespace status
sudo escape-pod status

# Test connectivity
sudo ip netns exec home ping -c 1 1.1.1.1

# Check DNS resolution
sudo ip netns exec home nslookup example.com 1.1.1.1
```
