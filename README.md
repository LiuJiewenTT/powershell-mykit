# PowerShell MyKit

This is a collection of PowerShell scripts and modules that can be used to automate various tasks on Windows (basically for my own purposes).

## Usages

### Networking {#usages}

1. Dynamically set IP addresses of network interfaces.
2. Show settings and status of **system proxy**.
3. Show settings of **DNS servers**.
4. Show **network connections** in a table format.

## User Manual

> This section's list items are referring to that with same number in the [Usages](#usages) section.

### Networking {#user-manual}

refers to: [section](#networking-usages)

1. If you're setting from blank, you can save your adjusted environment with `*-NetSaveFile` in `TT.*.init.ps1`. Or you can use the command and select the target interface and then edit configuration in the configuration file formatted in JSON.


## Setup

Add `bin` directory to `%USERPROFILE%\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`. You may refer to this: [examples/setup/Microsoft.PowerShell_profile.ps1](examples/setup/Microsoft.PowerShell_profile.ps1).


## Notes

- This project uses CP-65001 encoding for powershell terminals. The files are encoded in UTF-8 or UTF-8 with BOM. Don't worry about the encoding, entrance files will take care of it.
- This project will not change encoding for cmd terminals if running with *.bat* scripts only.

