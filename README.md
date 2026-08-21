# PowerShell MyKit

A collection of PowerShell scripts for automating various tasks on Windows (basically for my own purposes). Compatible with PowerShell 5.1, no extra modules required.

## Directory Layout

```
bin/
├── TT.MyKit.ps1            # Toolkit entry: import, browse, help (all-in-one)
├── _core/                   # Core utilities (excluded from scan)
│   └── TT.LoadScript.Utils.ps1
├── _sceneinit/              # Scene init scripts (mutually exclusive, manual dot-source)
│   ├── TT.Home.Init.ps1
│   ├── TT.Normal.Init.ps1
│   └── TT.Work1.Init.ps1
├── git/                     # Git utilities
│   ├── TT.Git.AddAllAsSafe.ps1        (@archived)
│   ├── TT.Git.AddAllAsSafe_v2.ps1
│   ├── TT.Git.CodeStat.ps1
│   └── TT.Git.SplitCommit.ps1
├── net/                     # Networking utilities
│   ├── TT.NetIP.Utils.ps1
│   ├── TT.Net.PrintConnection.ps1
│   ├── TT.Net.PrintDnsServers.ps1
│   └── TT.Net.PrintProxy.ps1
├── disk/                    # Disk utilities
│   └── TT.Disk.NewDiffVhd.ps1
└── wallpaper/               # Wallpaper utilities
    ├── TT.Wallpaper.GetCurrentWallpaperPath.ps1
    ├── TT.Wallpaper.ImageDedupe.ps1
    ├── TT.Wallpaper.SaveAs_IdentifyImageNoExt.ps1
    └── TT.Wallpaper.SaveUsedWallpaper.ps1
```

### Naming Convention

All scripts follow `TT.<Category>.<Command>.ps1` (PascalCase). Archived scripts are marked with `# @archived` in the first 5 lines (v1 keep original names, v2 keep `_v2` suffix).

## Toolkit Commands

Dot-source `TT.MyKit.ps1` to register four commands:

| Command | Description |
|---------|-------------|
| `Import-MyKit` | Import scripts by category or all at once (`-All`, `-Category`, `-List`) |
| `Get-MyKitCommand` | Browse commands as a script-centric list (`-Category`, `-Name`, `-Preview`, `-Detail`) |
| `Get-MyKitCommandList` | List all commands expanded by function (`-Category`, `-Name`) |
| `Get-MyKitCategory` | List all category directories |

```powershell
. bin\TT.MyKit.ps1          # Load toolkit entry
Get-MyKitCommand            # Browse available commands
Import-MyKit -List -All     # Dry-run: see what would be imported
Import-MyKit -Category git  # Import a specific category
```

### Scene Init Scripts

`_sceneinit/` contains mutually exclusive network environment init scripts (Home / Normal / Work1). They are skipped by `Import-MyKit` and must be dot-sourced manually:

```powershell
. bin\_sceneinit\TT.Home.Init.ps1    # then call: Home-NetInit
. bin\_sceneinit\TT.Normal.Init.ps1  # then call: Normal-NetInit
. bin\_sceneinit\TT.Work1.Init.ps1   # then call: Work1-NetInit
```

Use `*-NetSaveFile` to save current network config to JSON, then `*-NetInit` to restore.

## Setup

Add `bin` directory to `%USERPROFILE%\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`. You may refer to this: [examples/setup/Microsoft.PowerShell_profile.ps1](examples/setup/Microsoft.PowerShell_profile.ps1).


## Notes

- This project uses CP-65001 encoding for PowerShell terminals. Files are encoded in UTF-8 or UTF-8 with BOM.
- `Import-MyKit` auto-detects mixed-type scripts (function definitions + script-level executable code) and skips them to avoid interactive blocking on dot-source.
- Archived scripts (`# @archived`) are skipped by `Import-MyKit` but still visible in `Get-MyKitCommand` (marked as `archived`).