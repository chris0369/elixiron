# IPSec Configuration

This directory contains IPSec configuration files for the desktop integration server.

## Required Files

### ipsec.conf
Main IPSec configuration file. Should contain:

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

conn desktop-integration
    left=%defaultroute
    leftsubnet=0.0.0.0/0
    leftfirewall=yes
    right=YOUR_REMOTE_GATEWAY_IP
    rightsubnet=YOUR_REMOTE_SUBNET
    auto=start
```

### ipsec.secrets
Pre-shared keys and authentication secrets. Should contain:

```
# Example structure - customize for your environment
# Format: left_id right_id : PSK "your_pre_shared_key"
%any %any : PSK "YOUR_STRONG_PRE_SHARED_KEY"

# Or for specific connections:
# YOUR_LOCAL_IP YOUR_REMOTE_IP : PSK "YOUR_CONNECTION_SPECIFIC_KEY"
```

## Security Notes

- **Never commit these files to version control**
- Use strong, randomly generated pre-shared keys (minimum 32 characters)
- Rotate keys regularly according to your security policy
- Ensure proper file permissions (600 for secrets file)
- Consider using certificate-based authentication for production

## Environment Variables

You may want to use environment variables for sensitive values:

- `IPSEC_PSK` - Pre-shared key
- `IPSEC_REMOTE_GATEWAY` - Remote gateway IP
- `IPSEC_REMOTE_SUBNET` - Remote subnet configuration

## Setup Instructions

1. Copy the example configurations above
2. Replace placeholder values with your actual network configuration
3. Generate strong pre-shared keys
4. Set appropriate file permissions:
   ```bash
   chmod 600 ipsec.secrets
   chmod 644 ipsec.conf
   ```
5. Test the configuration in a development environment first 