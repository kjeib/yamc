# YAMC - Yet Another Machine Configurator

YAMC is a shell-based tool for remote machine configuration and management, allowing you to execute installation scripts, configuration tasks, and maintenance operations on remote machines through SSH.

## Overview

YAMC enables you to:
- Install and configure software packages on remote machines
- Run maintenance tasks on remote machines
- Maintain a library of reusable configuration modules
- Execute local preparation tasks before remote execution
- Share local module files with the remote machine seamlessly

## Architecture

YAMC follows these key principles:
1. Initial setup is usually done once per target host with the `init` command (recommended)
2. Each configuration task is organized as a module in its own directory
3. Modules can contain both local and remote execution scripts
4. Local directory contents are shared with the remote system via SSH and SSHFS
5. Environment variables pass data between local and remote execution phases

## Usage

```
# Initialize a host first (recommended once per host)
yamc init -h remote_hostname [-u username] [-v] [-t timeout]

# Run modules
yamc -h remote_hostname [-u username] [-e var=value] [-v] [-t timeout] module [subfunction] [args...]
```

- `init`: Initialization command that sets up SSH key authentication and ensures SSHFS exists on the remote host
- `-h remote_hostname`: Required. Specifies the target machine to configure
- `-u username`: Optional. SSH username (defaults to current user)
- `-e var=value`: Optional. Environment variables to pass to scripts (can be used multiple times)
- `-v`: Optional. Enable verbose output for debugging
- `-t timeout`: Optional. SSH connection timeout in seconds (default: 30)
- `module`: Required. The name of the module directory containing the scripts
- `subfunction`: Optional. The script to run (defaults to "setup")
- `args`: Optional. Additional arguments passed to the module scripts

### Examples

```bash
# Initialize a new machine for YAMC (required once per host)
# Must use a regular user account with sudo privileges
yamc init -h new_machine_hostname -u regular_user

# Configure DHCP server
yamc -h new_machine_hostname dhcp

# Edit DHCP configuration
yamc -h new_machine_hostname dhcp edit

# Set timezone with argument as root user
yamc -h new_server -u root timezone America/New_York
```

## How It Works

### Initialization Phase

When you run `yamc init -h hostname -u username`:

1. YAMC checks for a local SSH key, generating one if needed
2. The SSH key is installed on the remote machine using ssh-copy-id for the specified user
3. SSHFS is installed on the remote machine if not already present
4. Host preferences are saved to `~/.yamc/hostname.env`

Important: The initialization must be run with the regular, unprivileged user account on the remote machine. This user must have sudo privileges to install packages. This initialization only needs to be run once per host, setting up passwordless SSH authentication and all required dependencies.

### Module Execution Phase

When you run `yamc -h hostname module`:

1. YAMC ensures local prerequisites are available (e.g., local `sftp-server` path cached in `~/.yamc/yamc.env`)
2. It optionally loads host preferences from `~/.yamc/hostname.env` (if present)
3. If a `setup.loc` script exists, it's executed locally to prepare resources
4. A temporary directory is created for data exchange
5. Variables `MOD_DIR` and `MOD_TMP` are created to reference paths for both machines
6. The local module directory is shared with the remote machine using an SFTP server and SSHFS in slave mode
7. The remote script is executed on the target machine, with access to local files
8. After execution, the temporary resources are cleaned up

Note: `yamc init` is still the recommended onboarding step. However, if the host is already reachable via SSH and has `sshfs` installed, modules can run even if `~/.yamc/hostname.env` does not exist on the current local machine.

### SSH File Sharing Implementation

YAMC uses a named pipe and SFTP server approach to share local directories with the remote system:

```bash
reverse_sshfs_mount() {
  local localpath="$1"
  local remotehost="$2"
  local remotepath="$3"
  local fifo="/tmp/revsshfs-$$"

  mkfifo -m600 "$fifo"

  trap 'ssh "$remotehost" fusermount -u "$remotepath"; rm -f "$fifo"' EXIT INT TERM

  < "$fifo" "$SFTP_SERVER" |
    ssh "$remotehost" sshfs -o slave ":$localpath" "$remotepath" > "$fifo"
}
```

How this works:
1. Creates a named pipe (FIFO) as a communication channel
2. Sets up a trap to handle cleanup on exit
3. Runs a local SFTP server and connects its input/output to the named pipe
4. Connects via SSH to the remote machine and runs SSHFS in slave mode
5. SSHFS connects back to the local SFTP server through the SSH connection's standard I/O

Advantages of this approach:
- Uses a single SSH connection for both file sharing and commands
- More efficient than setting up separate tunnels
- Secure (uses SSH encryption)
- Real-time access to local files without separate file transfers

## Modules

Modules are organized as directories containing:

- `setup`: The main script executed on the remote machine (default)
- `setup.loc`: Optional script executed locally before SSH connection
- Any other files or subdirectories used by the scripts
- Additional subfunction scripts with corresponding `.loc` files

When a subfunction is specified, YAMC will look for and execute scripts named after that subfunction instead of "setup". For example, if you run `yamc -h host module edit`, YAMC will execute:
- `module/edit.loc` locally (if it exists)
- `module/edit` on the remote machine

Environment variables created in the `.loc` scripts will be available to the remote scripts.

### Module Help (`help` / `help.loc`)

Every module can ship a `help.loc` script that prints site-aware usage. It runs locally — there is no SSH, no `-h` flag is required, and it has read-only access to the module's `yamc.local/<module>/` resources via `RES_DIR`.

```bash
yamc help              # aggregate over yamc.local/<module>/ with installed modules
yamc help dhcp         # one module
yamc dhcp help         # symmetric form, identical to 'yamc help dhcp'
```

If `<module>/help.loc` is missing, YAMC prints a generic fallback (paths, README pointer, discovered subcommand names).

**`help.loc` contract:**

- **Local only.** Sourced in a subshell; treat it as read-only. Do not modify the system.
- **Inputs:** `MOD_DIR`, `RES_DIR`, `RES_BASE`, `YAMC_MODULE`, `INSTALL_DIR`, `RESOURCES_ROOT`.
- **Output:** human-readable text on stdout. Keep it short and actionable:
  - Site facts (e.g., server names from `cluster.conf`)
  - One-line subcommand summaries
  - Suggested `yamc -h <host> <module> <subcommand>` invocations
- **Do not** dump full configs (no `cat hosts.conf`).
- **Gracefully degrade** when `RES_DIR` is empty or expected files are missing.

Run `yamc help <module>` after editing `help.loc` to verify output.

### Environment Variables

These environment variables are available to all scripts:

- `MOD_DIR`: Path to the module directory (different on local vs. remote)
- `MOD_TMP`: Path to the temporary directory for file exchange
- `ssh_user`: The username used for SSH connection
- `tgt_host`: The target hostname being configured
- Any variables defined in the `.loc` script
- Any variables passed through the command line with `-e var=value`

## Module Implementation Examples

Current implemented modules:

- `test`: Test module for verifying YAMC functionality (see Testing section below)
- `timezone`: Sets the machine's timezone
- `locale`: Sets the machine's locale
- `pref`: Installs user preferences like .bash_profile and .inputrc
- `mounter`: Installs an NFS mount script and desktop shortcut

Planned modules:
- `upgrade`: Upgrade all packages
- `dhcp`: Configure the machine as a DHCP server
- `bind9`: Configure the machine as a DNS server
- `mailserver`: Set up a mail server

## Installation

YAMC can be installed system-wide or run directly from the source directory.

### System-wide Installation

To install YAMC system-wide with default settings:

```bash
git clone https://github.com/gotchoices/yamc.git
cd yamc
sudo ./install.sh
```

This will:
- Install core scripts to `/usr/local/lib/yamc/`
- Create symlinks in `/usr/local/bin/` for `yamc` and `yamcity`
- Install modules to `/usr/local/lib/yamc/modules/`
- Install documentation to `/usr/local/share/doc/yamc/`

#### Custom Installation Location

You can customize the installation location:

```bash
# Install to a different prefix
sudo ./install.sh --prefix /opt

# Install to specific directories
sudo ./install.sh --lib-dir ~/lib/yamc --bin-dir ~/bin
```

#### Uninstalling

To uninstall YAMC:

```bash
sudo ./install.sh --uninstall
```

### Running Without Installation

You can also run YAMC directly from the source directory:

```bash
git clone https://github.com/gotchoices/yamc.git
cd yamc
./yamc -h hostname init
./yamc -h hostname module
```

### Using Custom Modules

YAMC searches for modules in multiple locations (in order):

1. Absolute path (if module name is a full path)
2. Relative to current directory
3. User's personal modules (`$HOME/.yamc/modules/`)
4. System-wide custom modules (`/etc/yamc/modules/`)
5. Installed modules directory (e.g., `/usr/local/lib/yamc/modules/`)

To create and use your own modules:

```bash
# Create a user module directory
mkdir -p ~/.yamc/modules/mymodule

# Create the required setup script
touch ~/.yamc/modules/mymodule/setup
chmod +x ~/.yamc/modules/mymodule/setup

# Use the module
yamc -h hostname mymodule
```

## Prerequisites

- Bash shell environment
- SSH client on the local machine
- SSH server on the remote machine
- SSHFS package on the remote machine (will be auto-installed during init)
- SFTP server on the local machine (typically included with OpenSSH)

## Target OS

Currently targeted for Ubuntu systems. Future versions may support additional distributions with different package managers.

## Implementation Notes

- The initialization process is only run once per target host
- Host preferences are cached in `~/.yamc/hostname.env` (optional), and local machine cache is in `~/.yamc/yamc.env`
- Error checking has been implemented for SSH connections and command execution
- The script uses temporary directories that are cleaned up after execution
- A timeout mechanism prevents hung connections
- Interactive scripts are supported through SSH's terminal allocation

## Testing

YAMC includes a test module to verify functionality. To use it:

```bash
# Initialize the host if needed
yamc init -h your_remote_host -u <sudo_user>

# Basic functionality test
yamc -h your_remote_host test

# Test argument passing
yamc -h your_remote_host test args arg1 arg2 "argument 3"

# Test environment variable passing
yamc -h your_remote_host -e test_var1=hello -e test_var2="world" test env

# Verbose mode for debugging
yamc -h your_remote_host -v test
```

The test module verifies:
- SSH connectivity
- SSHFS file sharing
- Environment variable passing
- Command-line argument passing
- Local and remote script execution

## Automation with YAMCITY

YAMC includes a companion script called `yamcity` that allows you to automate the execution of multiple YAMC modules in sequence. This is useful for setting up complete machine configurations through a single profile file.

### How It Works

1. Create a profile file with module commands (one per line)
2. Run yamcity with the hostname and profile file
3. The script executes each command in sequence, applying the hostname to all of them
4. Profiles can include other profiles for modular composition
5. Comprehensive logs are saved for each command and a summary is provided

### Usage

```bash
# Basic usage
./yamcity -h hostname profile_file

# With default username (used when line doesn't specify -u)
./yamcity -h hostname -u username profile_file

# With verbose output
./yamcity -h hostname -v profile_file

# Continue execution after errors
./yamcity -h hostname profile_file true
```

### Profile File Format

Profile files use a **module-first syntax** - the module name comes first, followed by arguments and options:

```
# Comments start with a hash

# Simple module (no arguments or options)
timezone

# Module with argument
packages base

# Module with argument and user option
packages desktop -u root

# Module with multiple options
bind9 -u root -p master -v

# Include another profile (path must exist as a file)
profiles/base
./common-setup
```

**Key points:**
- Module name is always the first word
- Options (`-u`, `-p`, `-e`, `-v`, `-t`) can appear anywhere after the module
- Options are automatically reordered before passing to yamc
- If a line's first word is a file path, it's included as a nested profile
- Circular includes are detected and prevented

### Profile Composition

You can build modular profiles by including others:

```
# profiles/workstation - includes base server + adds desktop

# First, run the base server setup
profiles/server

# Then add desktop-specific modules
packages desktop -u root
xfce -u root
chrome -u root
```

### Logging

The yamcity script creates a timestamped log directory for each run:

- `yamc-logs/YYYYMMDD_HHMMSS/summary.log` - Overview of all commands and their status
- `yamc-logs/YYYYMMDD_HHMMSS/cmd_N.log` - Standard output for command N
- `yamc-logs/YYYYMMDD_HHMMSS/cmd_N.err` - Standard error for command N

### Example

To automate the setup of a new workstation:

1. Create a profile file (`profiles/workstation`) with the desired configuration
2. Run `./yamcity -h new_workstation profiles/workstation`
3. Review the logs to ensure all modules executed successfully

## Future Enhancements

- Support for multiple distribution package managers
- Configuration file for default settings
- Module templates for easier creation of new modules
- Comprehensive logging for troubleshooting
- Module validation checks before execution
- Local caching of installation states for faster execution