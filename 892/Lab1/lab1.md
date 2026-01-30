````markdown
# COE892 Lab 1 Instructions (Lab1.md)

## Project Overview
This repository contains my solution for **COE892 Lab 1: Concurrency vs Parallelism**, split into:

- **Part 1 (Rovers):** Fetch rover command strings from an HTTP endpoint, simulate rover movement on a terrain map, and output each rover’s trace map to a file.
- **Part 2 (Mines):** Brute-force a valid PIN per mine serial using SHA-256, and compare sequential vs threaded vs multiprocessing performance.

## Author and Usage Notice
**Author:** Krish Patel (KrishAdmin)  
Website: https://krishadmin.com

**NOTICE:**  
This repository and its contents are intended only for individuals who were directly provided the GitHub repository link by the author. Any use, copying, modification, or distribution without explicit permission from the author is prohibited.

---

## Requirements

### Python
- Python 3.8+ recommended

### Python Package
Install `requests`:

```bash
python3 -m pip install requests
````

---

## Repository Layout

Recommended structure:

```text
Lab1/
  COE892-Lab1-Krish_Patel.py
  Lab1.md
  map.txt
  mines.txt                      # optional, used for Part 2 if provided
  output/                        # generated
    part1/
      trace_1.txt
      trace_2.txt
      ...
    part2/
      disarmed_mines.json
```

---

## Input File Formats

### map.txt format (required for Part 1, can also be used for Part 2)

The map file format:

* Line 1: `ROWS COLS`
* Next `ROWS` lines: `COLS` integers per line

  * `0` means clear
  * `1` means mine

Example:

```text
5 6
0 0 0 0 0 0
0 1 0 0 0 0
0 0 0 1 0 0
0 0 0 0 0 0
1 0 0 0 0 0
```

### mines.txt format (optional for Part 2)

If provided, Part 2 can use this file instead of extracting mines from `map.txt`.

Supported formats per line:

* `serial` only
* `row col serial` (row/col optional, serial required)

Examples:

```text
b113qv2l9g
xrspark1erv
12 7 b113qv2l9g
```

If the same serial appears multiple times, the program assigns a unique mine identifier by adding a suffix.

---

## Part 1: Rover Navigation

### What Part 1 does

For each rover id:

1. Fetch rover commands (`L`, `R`, `M`, `D`) from the rover API
2. Simulate rover movement on the map
3. Write a trace output file named:

* `trace_<rover_id>.txt`

Each trace file contains:

* First line: `ROWS COLS`
* Then a grid of `0` and `*`

  * `*` means visited cell
  * `0` means not visited

### Rover API Endpoint

Rover commands are fetched using:

* `--base-url` (must point to `.../rover`)
* The rover id is appended automatically

Example:

* base url: `https://coe892.reev.dev/lab1/rover`
* rover 3 request: `https://coe892.reev.dev/lab1/rover/3`

### Run Part 1 (Sequential)

```bash
python3 COE892-Lab1-Krish_Patel.py --p1 --seq --map map.txt --base-url https://coe892.reev.dev/lab1/rover
```

### Run Part 1 (Threaded)

```bash
python3 COE892-Lab1-Krish_Patel.py --p1 --threaded --map map.txt --base-url https://coe892.reev.dev/lab1/rover
```

### Run Part 1 (Both Sequential and Threaded)

If you omit `--seq` and `--threaded`, the script runs both and prints the delta:

```bash
python3 COE892-Lab1-Krish_Patel.py --p1 --map map.txt --base-url https://coe892.reev.dev/lab1/rover
```

### Output Location (Part 1)

Part 1 output is written to:

```text
output/part1/trace_<rover_id>.txt
```

---

## Part 2: Mine Neutralization

### What Part 2 does

Part 2 brute-forces a PIN for each mine serial using SHA-256.

* For each mine serial, find a PIN such that:

  * `sha256(pin + serial)` has a hex digest that starts with `N` leading zeros
* `N` is controlled by:

```text
--difficulty
```

### Mine Identifiers

Part 2 includes a mine identifier for each mine in:

* Console print statements
* JSON output file

If mines come from `map.txt`, mine identifiers are generated using coordinates (and optionally the map value depending on `--serial-mode`).
If mines come from `mines.txt`, mine identifiers are derived from the serial and made unique with suffixes if needed.

### Run Part 2 (Sequential)

```bash
python3 COE892-Lab1-Krish_Patel.py --p2 --seq --map map.txt --mines mines.txt --difficulty 6
```

### Run Part 2 (Threaded)

```bash
python3 COE892-Lab1-Krish_Patel.py --p2 --threaded --p2-threads 4 --map map.txt --mines mines.txt --difficulty 6
```

### Run Part 2 (Multiprocessing)

```bash
python3 COE892-Lab1-Krish_Patel.py --p2 --mp --p2-threads 4 --map map.txt --mines mines.txt --difficulty 6
```

### Output Location (Part 2)

Part 2 output is written to:

```text
output/part2/disarmed_mines.json
```

The output format is JSON mapping mine identifiers to their solved PIN and metadata.

---

## Useful Options

### Rover selection

Run only specific rovers:

```bash
python3 COE892-Lab1-Krish_Patel.py --p1 --rovers 1,3,10 --map map.txt --base-url https://coe892.reev.dev/lab1/rover
```

Run a rover range:

```bash
python3 COE892-Lab1-Krish_Patel.py --p1 --rovers 1-5 --map map.txt --base-url https://coe892.reev.dev/lab1/rover
```

### Cache rover commands

Cache commands to avoid repeated HTTP calls:

```bash
python3 COE892-Lab1-Krish_Patel.py --p1 --cache rover_cache.json --map map.txt --base-url https://coe892.reev.dev/lab1/rover
```

Force refresh the cache:

```bash
python3 COE892-Lab1-Krish_Patel.py --p1 --cache rover_cache.json --refresh-cache --map map.txt --base-url https://coe892.reev.dev/lab1/rover
```

### Hash difficulty

Increase difficulty for longer runs:

```bash
python3 COE892-Lab1-Krish_Patel.py --p2 --seq --difficulty 7
```

### Yield control in brute force loop

The brute force loop yields occasionally to reduce CPU starvation:

```bash
python3 COE892-Lab1-Krish_Patel.py --p2 --threaded --yield-every 20000
```

---

## Notes on Performance Results

* Part 1 is mostly I/O-bound due to HTTP calls, so threading often improves performance significantly when the API has noticeable latency.
* Part 2 is CPU-bound due to brute force hashing. Multiprocessing usually provides the strongest scaling on multi-core CPUs, while threading may show limited improvements depending on environment and workload.

---

## Git Usage (Quick)

From your `Lab1/` directory:

```bash
git init
git add COE892-Lab1-Krish_Patel.py Lab1.md map.txt mines.txt
git commit -m "Add COE892 Lab 1 solution"
git branch -M main
git remote add origin <YOUR_GITHUB_REPO_URL>
git push -u origin main
```

Replace `<YOUR_GITHUB_REPO_URL>` with your repository URL.

```
```
