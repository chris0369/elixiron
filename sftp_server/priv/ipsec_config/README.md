# IPSec Configuration for SFTP Server

This directory contains IPSec configuration files for the SFTP server component.

## Required Files

### ipsec.conf
Main IPSec configuration file for SFTP server. Should contain:

```
# Example structure - customize for your environment
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

conn %default
    ikelifetime=60m
    keylife=20m
    rekeymargin=3m
    keyingtries=1
    keyexchange=ikev2
    authby=secret

conn sftp-server
    left=%defaultroute
    leftsubnet=0.0.0.0/0
    leftfirewall=yes
    right=YOUR_SFTP_CLIENT_IP
    rightsubnet=YOUR_CLIENT_SUBNET
    auto=start
    # SFTP specific settings
    leftprotoport=22/tcp
    rightprotoport=22/tcp
```

### ipsec.secrets
Pre-shared keys and authentication secrets for SFTP connections. Should contain:

```
# Example structure - customize for your environment
# Format: left_id right_id : PSK "your_pre_shared_key"
%any %any : PSK "YOUR_STRONG_SFTP_PSK"

# For specific SFTP client connections:
# YOUR_SFTP_SERVER_IP YOUR_SFTP_CLIENT_IP : PSK "YOUR_SFTP_CONNECTION_KEY"
```

## Security Notes

- **Never commit these files to version control**
- Use strong, randomly generated pre-shared keys (minimum 32 characters)
- SFTP traffic should be encrypted both at IPSec and SSH levels
- Rotate keys regularly according to your security policy
- Ensure proper file permissions (600 for secrets file)
- Consider certificate-based authentication for production

## Environment Variables

You may want to use environment variables for sensitive values:

- `SFTP_IPSEC_PSK` - Pre-shared key for SFTP connections
- `SFTP_CLIENT_GATEWAY` - Allowed client gateway IP
- `SFTP_CLIENT_SUBNET` - Allowed client subnet configuration
- `SFTP_SERVER_PORT` - SFTP server port (default 22)

## SFTP-Specific Configuration

### Port Configuration
- Default SFTP port: 22
- Ensure IPSec configuration allows SSH/SFTP traffic
- Consider using non-standard ports for additional security

### Client Access Control
- Configure allowed client IP ranges
- Use specific PSKs for different client groups
- Implement proper firewall rules alongside IPSec

## Setup Instructions

1. Copy the example configurations above
2. Replace placeholder values with your SFTP network configuration
3. Generate strong pre-shared keys specific to SFTP access
4. Set appropriate file permissions:
   ```bash
   chmod 600 ipsec.secrets
   chmod 644 ipsec.conf
   ```
5. Coordinate with SFTP client administrators for key exchange
6. Test the configuration with SFTP client connections 