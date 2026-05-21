# CUPS Module

Install CUPS and configure network printers, including support for custom PPD files and filter scripts.

## Usage

```bash
yamc -h hostname -u root cups
```

Configure only specific queue(s) by appending their short names from `printers.conf` (first field before `|`). Other queues on the host are not removed or changed.

```bash
yamc -h hostname -u root cups L
yamc -h hostname -u root cups setup L M
```

PPDs and filters under `yamc.local/cups/` are still deployed in full on every run; only `lpadmin` targets the named printer(s).

## Directory Structure

```
yamc.local/cups/
├── printers.conf        # Printer definitions
├── ppd/                 # Custom PPD files (optional)
│   └── Epson-Label.ppd
└── filters/             # Custom filter scripts (optional)
    └── labfilt.sh
```

## Printer Configuration

Create `yamc.local/cups/printers.conf`:

```bash
# Format: name|uri|description|driver|options
# driver and options are optional
# Default driver is "everywhere" (driverless IPP)

# Network printers via DNS-SD (auto-discovery URI)
B|dnssd://Brother%20MFC-L2750DW%20series._ipp._tcp.local/|Basement Laser
J|dnssd://Brother%20MFC-J6920DW._ipp._tcp.local/|Color Inkjet

# Network printers via IP
M|ipp://192.168.5.220/ipp/print|Loft Laser

# Printer with custom PPD (file must exist in ppd/ directory)
L|socket://L.batemans.org|Label Printer|Epson-Label.ppd

# Printer with options
K|ipp://192.168.5.223/ipp/print|Photo Printer||Quality=Photo
```

## Custom PPD Files

For printers that need special handling (label printers, receipt printers, etc.):

1. Place PPD file in `yamc.local/cups/ppd/`
2. Reference it by filename in printers.conf (4th field)

The module automatically:
- Detects `.ppd` extension
- Copies PPD to `/usr/share/cups/model/`
- Uses `-P /path/to/ppd` instead of `-m driver`

## Custom Filter Scripts

PPD files can reference custom CUPS filters. Place filter scripts in `yamc.local/cups/filters/`:

```bash
# Example: yamc.local/cups/filters/labfilt.sh
# Referenced in PPD as: *cupsFilter: "text/plain 0 /usr/lib/cups/filter/labfilt.sh"
```

The module copies filters to `/usr/lib/cups/filter/` with mode 755 (AppArmor on Ubuntu allows CUPS to execute filters there, not under `/usr/local/bin/`).

## Finding Printer URIs

```bash
# Discover network printers via DNS-SD
avahi-browse -t _ipp._tcp

# List available printer URIs
lpinfo -v

# For HP printers specifically
hp-probe
```

## Driverless IPP (Recommended)

Modern printers support **IPP Everywhere** - CUPS queries the printer's capabilities directly, no PPD/driver needed.

The module uses `-m everywhere` by default. Only specify a driver for:
- Old printers without IPP support
- Special printers (label, receipt, etc.)
- When driverless doesn't work correctly

## What It Does

1. Installs CUPS, hplip (HP drivers)
2. Enables CUPS service
3. **Deploys custom PPD files** to `/usr/share/cups/model/`
4. **Deploys filter scripts** to `/usr/lib/cups/filter/`
5. Configures each printer via `lpadmin`

## Troubleshooting

```bash
# List configured printers
lpstat -p

# Print test page
lp -d PrinterName /usr/share/cups/data/testprint

# CUPS web interface
http://hostname:631

# Check if printer responds
ping printer-ip
lpinfo -v | grep printer-ip

# CUPS error log
tail -f /var/log/cups/error_log
```

## Notes

- If no printers.conf exists, CUPS is installed but no printers configured
- Printers are removed and re-added on each run (clean configuration)
- PPD and filter files are deployed before printer configuration
- Web admin available at http://hostname:631
