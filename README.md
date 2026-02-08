# blueray-burner Disk-to-USB Imaging Guide (macOS)

A practical, repeatable workflow to:

0. Burn data to a blueray or dvd
1. Build an image file (`.iso`) from data on disk  
2. Verify the image  
3. Write (“burn”) it to an external USB drive  
4. Eject safely

This is designed for reliability and clarity, with explicit safety checks. And in the case of bluerays to burn without using storage in your own computer but an external USB drive.

---

## What this does

- **Source data**: your folder/files on an internal or external disk
- **Image artifact**: a single `.iso` file created from that source
- **Burn step**: raw byte-for-byte write of the image to USB with `dd`
- **Safe finish**: flush + eject to avoid corruption

---

## Requirements

- macOS
- Terminal access
- `hdiutil`, `diskutil`, `dd`, `shasum` (built-in on macOS)
- Admin privileges for `dd` (`sudo`)
- A target USB drive

---

## Safety first

`dd` will overwrite the selected disk completely.

Before writing:
- Double-check `/dev/diskN` is the USB target
- Unmount the target disk first
- Never guess disk IDs

---

## Quick Start

Set your variables:

```bash
SRC="/Volumes/DataMa/path/to/source_folder"
IMG="$HOME/Desktop/mybackup.iso"
DISK="/dev/disk4"   # <-- replace with your actual USB disk from `diskutil list`

