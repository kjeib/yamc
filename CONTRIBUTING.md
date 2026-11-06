# YAMC Developer Notes

This document contains additional information useful for developing and debugging YAMC modules.

## Variable Naming Conventions

- Use lowercase variable names for parameters passed with `-e` flags
- Example: `yamc -h hostname -u user -e remote=server:/share -e local=/path mounter`
- Variables will be exported to the script environment automatically
- In setup scripts, use lowercase for variables from parameters: `$remote`, `$local`, `$version`
- For internal script variables, uppercase is acceptable: `CURRENT_VERSION`, `INSTALLED_VERSION`

## Module Development Process

1. **Create Module Structure**
   ```
   moduleDir/
   ├── README.md        # Module documentation
   ├── setup            # Main remote script (required)
   ├── setup.loc        # Local preparation script (optional)
   ├── setup.post.loc   # Local step after a successful remote run (optional)
   └── [other files]    # Supporting scripts and templates
   ```

2. **Local Script (setup.loc)**
   - Runs on the local machine before connecting to remote host
   - Used for preprocessing and preparation work
   - Environment variables created here are passed to the remote script
   - Receives command-line arguments in `$@`
   - Has access to `-e` flag variables directly in its environment

3. **Remote Script (setup)**
   - Runs on the remote machine
   - Has access to all environment variables from setup.loc
   - Has access to all environment variables from `-e` flags
   - Can access module files through `$MOD_DIR`
   - Can use temporary directory at `$MOD_TMP`

## Parameter Handling Flow

1. User runs command with `-e` parameters:
   ```bash
   yamc -h host -e param=value module
   ```

2. YAMC collects parameters in `ENV_VARS` array
   ```bash
   # Stored in ENV_VARS array
   ENV_VARS+=("param=value")
   ```

3. Parameters are written to a temporary env file
   ```bash
   # Written to MOD_TMP/env
   echo "param=value" >> "$ENV_FILE"
   ```

4. For local scripts, variables are exported directly to the environment
   ```bash
   # In subshell for local script
   export "param"="value"
   ```

5. For remote scripts, variables are added as export commands
   ```bash
   # Sent to remote host
   ssh user@host "export param=value; bash script"
   ```

## Debugging Techniques

1. **Enable Verbose Mode**
   ```bash
   yamc -h hostname -v module
   ```

2. **Examine Log Files**
   - When using yamcity, check generated logs in yamc-logs directory
   - Individual command logs are stored in cmd_N.log and cmd_N.err files

3. **Common Issues**
   - SSH key authentication problems: Run initialization again with `yamc init`
   - Variable access issues: Verify lowercase variable names in scripts
   - File permissions: Ensure scripts are executable (chmod +x)
   - Module not found: Check module search paths with -v flag

4. **Debugging a Module**
   - Add echo statements to track script execution
   - Print environment variables at the start of scripts with `env | sort`
   - Use `set -x` in scripts to show command execution

## Testing a New Module

1. Create `setup.loc` to validate/prepare parameters if needed
2. Create `setup` script with proper error handling
3. Test with various parameter combinations
4. Test with edge cases (missing parameters, invalid values)
5. Verify idempotent behavior (running multiple times is safe)

## Module Examples and Patterns

### Processing Command-line Arguments (setup.loc)
```bash
# Variables from -e flags are already available
# For positional args:
if [ $# -ge 1 ]; then
  echo "Using first argument: $1"
  echo "arg_value=\"$1\"" >> "$MOD_TMP/env"
fi
```

### Required Variable Validation (setup)
```bash
# Validate required variables
if [ -z "$remote" ]; then
  echo "ERROR: Remote parameter not specified."
  echo "Usage: yamc -h hostname -u username -e remote=value module"
  exit 1
fi
```

### Default Values Pattern
```bash
# Set default value if not provided
VERSION="${version:-22}"
echo "Using version: $VERSION"
```

### File Templating Pattern
```bash
# Replace placeholders in a template file
sed "s|^\(placeholder=\).*|\1$variable|" "$MOD_DIR/template.txt" > "$output_file"
```

## Version Control Notes

- Check YAMC repository status with: `git status`
- Recent commits show evolution of modules
- Current branch is main
- Each module should be logically separate for easy tracking
- Keep changes consistent with existing patterns