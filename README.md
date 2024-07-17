# Backup My Files

Backup My Files is a CLI (command line interface) tool to help backup computer files in a directory or a Tar archive file. Written in Zig 0.13.0

## Table of Contents

- **[Features](#features)**
- **[Installation](#installation)**
- **[Example Json File](#example-json-file)**
- **[About Project](#about-project)**
- **[Current Bugs](#current-bugs)**

## Features

- **Store as Directory or Tar**: Each backup object may store the files as a directory or in a Tape Archive (Tar) file.
  - **Compress Tar File**: The tar file can optionally be compressed with `gzip` or `zlib`. Warning: Experimental, see [Current Bugs](#current-bugs) for more information.
- **File/Directory Filters**: Filters can be used to search certain file names to include or exclude from being copied. See [Example Json File](#example-json-file).
  - **Limited support of Regexp**: The anchor `^` can be used to allow the filter to only search for a string from the beginning. The anchor `$` can be used to allow the filter to search only a string from the end (e.g. file extensions). Alternation groups e.g. `(a|bc|def)` can be used to search either term in the parenthesis delimited by `|`.
  - **Directory Depth Limit**: Filters can be added to allow the filter to only work in certain depths of a directory.
  - **File and/or Directory Type**: The type can be used by the filter to only be allowed to work for a `file` or a `directory`, or `all`. By default, the filter works for `file` types only.
- **Date Support for naming Backups**: Backup file names can have limited use of adding dates using [format specifiers](https://linux.die.net/man/1/date). See `src/date.zig` or use the command `./backup_my_files -k` for more information.
- **Command Line Interface (CLI)**:
  - **Run Certain Backup Objects**: `-b` or `--backup` flag to filter backup object names from running.
  - **Scan Only for Filters**: `-s` or `--scan` to scan files or directories without copying yet. This is used to check filters if a file or directory is allowed or disallowed from being copied. Also see `--logs Filters` for debugging information on filters.
- **Deletes Old Backups**: Based on the `max_backups` key, it can attempt to delete old backups. Note: If the program exits abruptly due to errors, it may not delete the backup directory or file correctly inside the `output_dir` directory.
- **Progress Bar**: Display a progress bar indicating the search progress.

## Installation
The current version to build is Zig `0.13.0` [here](https://ziglang.org/download/#release-0.13.0). Note: Other versions may work, but it is not recommended.

```sh
zig build -Doptimize=ReleaseFast
#or
zig build -Doptimize=ReleaseSafe
```

To run the program with a .json file (.json in the same directory as the binary):
```sh
.\backup_my_files -i .\input.json
```

## Example Json File

(Example as of July 17, 2024)

To see the definition of the keys below, type
```sh
.\backup_my_files -k
```

### Windows .json file example
```js
{
  "output_dir": "C:\\The\\Directory\\Where\\Backup\\Files\\Will\\Be\\Placed",
  "max_backups": 20,
  "backups": [
    {
      "name": "Backup that will be a .tar.gz file",
      "type": {
        "tar": {
          "gzip": "level_8"
        },
      },
      "search_dir": "C:\\The\\Directory\\Where\\You\\Want\\To\\Copy\\Files\\From",
      "output_name": "BackupFilesNameWithDate_D%Y-%m-%d_T%H-%M-%S",
      "backup_files": [
        {
          "name": "subdirectory\\folder\\pictures",
          "filters": [
            {
              "type": "include",
              "component": "file",
              "value": "(.png|.jpg|.gif)$"
            }
          ],
          "dir_limit": 4
        },
        {
          "name": "just_a_file.txt"
        },
        {
          "name": "subdirectory\\number_2",
          "filters": [
            {
              "type": "exclude",
              "component": "directory",
              "value": "^test_"
            },
            {
              "type": "exclude",
              "component": "all",
              "value": "^."
            }
          ],
        }
      ]
    }
  ]
}

```
## About Project

I wanted to try to create a CLI project in the [Zig Programming Language](https://github.com/ziglang/zig) where it involved using the current `zig.std` library only.

I have learned a lot of things in this project, such as parsing a unix timestamp to a date, reading and writing tar headers for files and directories, reading and parsing arguments from the command line, and parsing objects in a .json file using `std.json.Scanner`.

For now, this project seems to work in Windows. I am not sure if it works correctly in Linux yet.

## Current Bugs
- When using compression to backup the files in a tar file, decompression of the compressed file may not work, and thus, the compressed archive may be corrupted.
  - In case you cannot open the compressed file due to corruption, there still exists the uncompressed `.tar` backup file so that you can compress externally to other programs instead.
- The progress bar counts incorrectly.
- There is no implementation for pax tar headers yet (TODO -  implement this feature). This means that extremely long path names may be not be supported, and files larger than 8GiB will not copy correctly.

