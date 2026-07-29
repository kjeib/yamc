# Pref Module

This YAMC module sets up user preferences on a remote host.

## Purpose

Install user preference files, including:
- Shell command editing preferences (.inputrc)
- Shell profile customizations (.bash_profile or .bashrc)

## Usage

```bash
# Basic usage
yamc -h hostname pref

# Custom inputrc file
INPUTRC=/path/to/custom/inputrc yamc -h hostname pref
```

## What It Does

1. Copies your local .inputrc file to the remote machine (if it exists)
2. Installs a set of useful shell aliases in the user's `~/.bashrc`
3. Keeps track of whether changes have already been made (idempotent)
4. Ensures a login-shell startup file sources `.bashrc`, so the aliases are
   available in both login and non-login shells
5. Migrates any block a previous version of this module wrote into
   `.bash_profile` (keeping a `.bash_profile.yamc-bak` backup)

## Why .bashrc and not .bash_profile

Aliases are per-shell state and are not inherited through the environment, so
they have to be re-defined by every interactive shell. Bash reads
`.bash_profile` **only for login shells**; a terminal window starts a non-login
shell and reads only `.bashrc`. Aliases placed in `.bash_profile` therefore
appear to "not work" in every terminal you open.

Earlier versions of this module preferred `.bash_profile` whenever it existed,
which produced exactly that failure. Rule of thumb: aliases and functions go in
`.bashrc`; `export`s and one-shot login commands go in `.bash_profile`.

## Default Aliases Added

The module adds these useful aliases to your shell profile:

```bash
alias ls='ls --color=tty'
alias ll='ls -lF'
alias lt='ll --sort=time -r'
alias cd='pushd "$(pwd)" >/dev/null; cd '
alias pd='popd >/dev/null'
```

## Customization

You can modify the `profile` file in the module directory to change what gets added to the user's shell profile.

## Private Customization

You can create private profile customizations without modifying the public module:

1. Create one of these files:
   - `$HOME/.yamc/pref/profile` (user-specific customizations)
   - `/etc/yamc/pref/profile` (system-wide customizations)

2. Add your custom bash profile settings to this file.

3. When you run the module, it will automatically detect and use your private 
   profile instead of the default one provided with the module.

This approach allows you to:
- Keep sensitive or personal customizations private
- Maintain your own settings separate from the public repository
- Easily update the YAMC project without losing your customizations

Example of a private profile file:
```bash
#Local additions:

# Custom environment variables
export MY_PRIVATE_VAR="secret value"

# Personal aliases
alias myserver='ssh user@private-server.example.com'
alias mydb='mysql -u username -p mydatabase'

# Company-specific settings
export COMPANY_API_KEY="1234567890"
```

## Notes

- This module only adds the customizations once (idempotent)
- It detects and uses the appropriate profile file (.bash_profile or .bashrc)
- The module works for the user running it, not for all users on the system
- If you want to apply preferences for multiple users, run the module for each user