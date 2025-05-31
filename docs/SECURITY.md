# Security Guidelines

## Overview

This repository contains an Elixir + Electron project with SFTP server capabilities. Due to the nature of the project, several directories contain or will contain sensitive data that must not be committed to version control.

## Sensitive Data Locations

### 🔐 Critical - Never Commit These

1. **SSH Private Keys**
   - `elixir_server/priv/keys/` - Contains SSH private keys
   - `sftp_server/priv/sftp_server/system_keys/` - SFTP server host keys

2. **Configuration Files**
   - `elixir_server/priv/ipsec_config/` - IPSec configuration with secrets
   - `sftp_server/priv/ipsec_config/` - IPSec configuration with secrets

3. **User Data**
   - `sftp_server/priv/sftp_server/sftp_data/` - User files and directories

4. **Environment Variables**
   - `.env` files containing passwords, tokens, or API keys

### Build Artifacts - Excluded for Performance

1. **Node.js Dependencies**
   - `electron_app/node_modules/` - Large dependency tree

2. **Elixir Build Artifacts**
   - `_build/` directories - Compiled Elixir code
   - `deps/` directories - Downloaded dependencies
   - `mix.lock` files - Dependency lock files

## Security Best Practices

### For Developers

1. **Never commit sensitive files** - The `.gitignore` files are configured to prevent this
2. **Use environment variables** for secrets instead of hardcoding
3. **Rotate any keys** that may have been accidentally committed
4. **Review commits** before pushing to ensure no sensitive data is included

### Key Management

1. **Generate fresh SSH keys** for each environment
2. **Store keys securely** outside the repository
3. **Use proper file permissions** (600 for private keys)
4. **Document key purposes** and rotation schedules

### Environment Setup

1. **Copy example configurations** and customize for your environment
2. **Never commit real credentials** to version control
3. **Use secret management tools** in production environments

## Directory Structure

The repository maintains directory structure through `.gitkeep` files to help developers understand the expected layout while excluding sensitive contents.

## Incident Response

If sensitive data is accidentally committed:

1. **Immediately rotate** any exposed credentials
2. **Follow GitHub's guide** for removing sensitive data from repository history
3. **Notify team members** to update their local clones
4. **Review and update** security practices

## References

- [GitHub: Removing sensitive data from a repository](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)
- [Git Secrets Detection Tools](https://github.com/awslabs/git-secrets)
- [OWASP Secrets Management](https://owasp.org/www-community/vulnerabilities/Use_of_hard-coded_password)

## Contact

For security concerns or questions, please contact the development team through secure channels. 