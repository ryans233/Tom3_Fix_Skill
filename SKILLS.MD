---
name: tom3-audio-fix
description: Build an ASI add-on for The Treasures of Montezuma 3 that stops the OpenAL buffer-name leak on the pooled {source + 3 buffers} reuse path, plus a reproducer and the exact acceptance checks.
---

# SKILLS — Tom3 audio leak fix

You are implementing an **interoperability add-on** for `TreasuresOfMontezuma3.exe`, not modifying the game. The goal is a pair of 32-bit DLLs (`.asi`) whose observable effect matches this document's contract:

1. `build\Tom3_Fix.asi` — stops the per-play OpenAL buffer leak.
2. `build\Tom3AudioLeakRepro.asi` — drives the engine's own replay entry so the leak can be measured without gameplay.

Acceptance is behavioral and must use the scripts in `tools\` with the thresholds in this file. No game code, no decompiled output, no dumps, no game assets may be committed or pasted anywhere.

RFC 2119 keywords apply (`MUST`, `MUST NOT`, `SHOULD`, `MAY`). `NEVER` = `MUST NOT`; `AVOID` = `SHOULD NOT`.

---

## 0. Legal & evidence boundary

* NEVER commit, upload, or paste: the game exe or any game DLL, assets, saves, memory dumps, IDA databases, disassembly listings, or decompiler output.
* NEVER modify, patch, repack, or redistribute the game executable. The deliverable is an independently loaded DLL.
* NEVER bypass DRM, activation, integrity checks, or anti-cheat.
* The offsets, RVAs, field offsets, and vtable addresses below are **interoperability facts** about the unmodified target. They exist so your hook can cooperate with the binary. They are not code and MUST NOT be expanded into instruction listings or decompiled text in your submission, docs, logs, or issues.
* Acceptance runs locally against a copy the user is licensed to use. Scripts do not upload or collect data.
* Game names and all game content belong to their owners. This project is unaffiliated.
* If local law or the EULA forbids in-process add-ons, stop. Do not use this skill.

`tools\check-submission.ps1` enforces the file-level part of this boundary. Passing it does not make a submission lawful; it only catches common accidental inclusions.

---

## 0.1 Execution order

0. Install the ASI loader from upstream. Do NOT write, reimplement, or bundle your own loader/proxy DLL. Download the Win32 package from [Ultimate ASI Loader v10.0.0](https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases/tag/v10.0.0) (asset `Ultimate-ASI-Loader-NoPDB.zip` or `Ultimate-ASI-Loader.zip`), take its 32-bit `dinput8.dll`, confirm it is i386, and place it next to the exe. The loader is third-party, is not a deliverable, and MUST NOT be committed or redistributed.
1. Read `tools\verify-tom3fix.ps1` and `tools\test-tom3-audio.ps1` so you know exactly what is parsed and how PASS is decided.
2. Confirm the target fingerprint in §1. If it does not match, stop: implement fail-closed behavior and report the mismatch instead of guessing offsets.
3. Implement `Tom3_Fix.asi` to the contract in §4. Keep the hit test as the only trigger for deletion.
4. Implement `Tom3AudioLeakRepro.asi` to the contract in §5 (`drive` mode is required).
5. Build both x86 DLLs into `build\` with the exact names.
6. Run `check-submission.ps1`, then `verify-tom3fix.ps1`, then the three benchmark scenarios (or `run-acceptance.ps1`).
7. Fix any failed step and re-run. Report the exact exit codes and verdict lines; never claim PASS without them.


---

## 1. Target fingerprint and coordinates

Target: The Treasures of Montezuma 3, `TreasuresOfMontezuma3.exe`.

| Fact | Value |
|---|---|
| File size | `8,504,320` bytes (unchanged by the optional LAA edit) |
| Format | PE32, i386 (`machine 0x014C`), DLL-capable loader |
| ImageBase | `0x400000` |
| ASLR | none (preferred base is honored); still compute `base = GetModuleHandle(NULL)`, never hard-code absolute VAs for code |
| Audio stack | `OpenAL32.dll` → `wrap_oal.dll` → DirectSound |
| Import | main module imports `OpenAL32.dll!alGenBuffers` by name |

Coordinates are RVAs relative to ImageBase unless marked VA. They are the only locations the add-on needs.

| Coordinate | Meaning | Use |
|---|---|---|
| `0x197E30` | pool-reuse routine entry | documentation only |
| `0x197EA9` | `call ds:alGenBuffers` (6 bytes: `FF 15 <IAT slot VA>`) inside the pool-reuse routine | recommended install-time guard |
| `0x197EAF` | **return address** of the buffer-generation call inside the pool-reuse routine | hook hit test |
| `0x197DEC` | call site in the pool-initialization path | MUST NOT be treated as a hit |
| `0x1988F0` | first-packet fill: uploads the whole stream as one buffer payload | explains leak size = audio length |
| `0x194F00` | engine start routine (`thiscall`, sound object, float volume) | optional reproducer |
| `0x1951C0` | engine restart routine: stop → seek to start → start (`thiscall`, sound object, float volume) | reproducer drive target |
| `0x194970` | stop / return bundle to pool | documentation only |
| `0x40B60`, `0x40B67` | two direct start calls in the game's sound API | optional `multiply` mode only |
| `0xAEC9AC` | sound-object vtable address (VA; ASLR off) | reproducer scan tag |

**Stock build vs LAA build.** The stock `TreasuresOfMontezuma3.exe` and the same file with `LARGEADDRESSAWARE` set differ by exactly one byte: the `DllCharacteristics` bit at file offset `0x19E` (`0x8100` → `0x8120`). File size, `SizeOfImage`, machine type, code, and every coordinate above are shared, so one add-on serves both and a version guard MUST NOT reject either. LAA only raises the 32-bit address-space ceiling; it is not part of the fix.

Version guard (RECOMMENDED): after locating the `alGenBuffers` IAT slot, read the six bytes at `0x197EA9` and require `FF 15 <operand>` with `<operand>` equal to the slot address you just hooked. That is the exact precondition for the `0x197EAF` hit test, costs one read, and catches a moved call site that file size or `SizeOfImage` cannot (both stay identical across the two builds above, and across unrelated copies of the same size). On mismatch, log `fix: ERROR no call ds:alGenBuffers at <addr> (found <6 bytes>; slot=<addr>) - unsupported exe build`, do not enable the hook, install nothing, and exit cleanly. A wrong-version hook must never call `alDeleteBuffers`. Also scanning the executable sections for every `FF 15 <slot>` and logging those addresses (the pool-init call at `0x197DEC` is one of them) makes future drift diagnosable.

---

## 2. Defect model (behavioral, no decompilation)

The engine keeps a pool of reusable bundles. Each bundle is one OpenAL source plus three buffer names. On reuse the engine:

1. deletes the source,
2. creates a new source,
3. calls `alGenBuffers(3, names)` **over the still-live array** to fill the bundle with a new generation of buffer names.

Step 3 overwrites the only references to the previous three buffer names. No `alDeleteBuffers` happens. The abandoned buffer objects keep their PCM payload. Because the first-packet fill uploads the entire stream in one buffer, **every replay leaks roughly one full sound asset**, allocated as private memory by the OpenAL wrapper.

Observed consequences:

* growth is proportional to play events, not frames;
* idle menu is flat; gameplay grows ~44 MB/min in the original report;
* 32-bit address space exhausts after roughly 30 minutes;
* allocation failure inside the wrapper leads to a CRT abort dialog; the modal loop re-enters the game window procedure while holding the per-sound lock and deadlocks against the audio tick thread (ABBA). The visible result is “Not Responding”, not a clean crash.

The fix is therefore narrow: **when, and only when, the engine is about to overwrite the three names on the reuse path, delete the previous generation first.** Do not change streaming, sample counts, volume, or timing.

---

## 3. Deliverable layout

Produce at minimum:

```
build\Tom3_Fix.asi            32-bit DLL, exact name
build\Tom3AudioLeakRepro.asi  32-bit DLL, exact name
src\*.cpp, src\*.h            your own source
build.bat or equivalent       reproducible x86 build
```

REQUIRED build shape (either toolchain below satisfies it; the acceptance scripts validate only the PE, not the build command):

MSVC x86:

```
cl /nologo /O2 /MT /LD /EHsc /D_CRT_SECURE_NO_WARNINGS /W3 <sources> /Fe:build\<name>.asi
```

MinGW-w64 i686 (equivalent):

```
i686-w64-mingw32-g++ -m32 -O2 -shared -static -static-libgcc -static-libstdc++ ^
  -D_CRT_SECURE_NO_WARNINGS -Wall <sources> ^
  -o build\<name>.asi -lpsapi -luser32 -ladvapi32
```

* x86 only (`/MACHINE:X86`; MinGW `-m32`); the game is PE32.
* No dependency on a non-system runtime DLL: MSVC `/MT`; MinGW `-static -static-libgcc -static-libstdc++` (depending on the system `msvcrt.dll` is fine).
* `.asi` is only a filename; the PE must be a DLL (`IMAGE_FILE_DLL`, characteristics bit `0x2000`).
* No third-party runtime downloads at build time. Link only Windows SDK import libs you use (`psapi`, `advapi32`, `user32` as needed).
* Portability notes for non-MSVC toolchains: keep the `__cdecl` hook signature, do not rely on `__try`/`__except` with 32-bit MinGW GCC, and replace `#pragma comment(lib, ...)` with explicit `-l` flags.

The acceptance scripts check the PE machine and DLL flag; they do not build your source.

The ASI loader is NOT part of the deliverable. Do not create one: fetch the 32-bit `dinput8.dll` from the upstream Ultimate ASI Loader v10.0.0 release (§0.1, step 0) and leave it out of the submission.

---

## 4. Fix contract — `Tom3_Fix.asi`

### 4.1 Hook

* Enumerate the **main module's** import directory; find the descriptor whose DLL name equals `OpenAL32.dll` (case-insensitive).
* Walk its thunks; find the by-name import `alGenBuffers`; skip ordinal imports.
* Save the current pointer as `original_alGenBuffers`; replace the IAT slot with your hook. Use `VirtualProtect` on the slot only (page `PAGE_READWRITE`), restore protection, and do **not** patch any code page.
* If `OpenAL32.dll` is not loaded, `LoadLibraryA("OpenAL32.dll")` once; resolve `alDeleteBuffers` and `alGetError` with `GetProcAddress`.
* Hook signature: `void __cdecl hook(ALsizei n, ALuint* buffers)`, matching `AL_APIENTRY` (`__cdecl`) on Win32.

### 4.2 Hit test (the critical invariant)

```
base = (uintptr_t)GetModuleHandleA(nullptr)
hit  = _ReturnAddress() == (void*)(base + 0x197EAF)
```

* The hook MUST call `original_alGenBuffers(n, buffers)` **unconditionally**, whether or not it is a hit.
* On a hit, before the original call:
  1. `alDeleteBuffers(n, buffers)` — at this instant the array still holds the previous generation's names.
  2. Drain `alGetError()` until it returns `AL_NO_ERROR` so the engine's own error check stays clean.
  3. increment `hits` once and `freed` by `n`.
* On every call (hit or not), add `n` to `gen` before/after the original call.
* MUST NOT delete on `0x197DEC` or any other return address. If the return address does not match, behave as a pure pass-through.
* If `alDeleteBuffers` is unavailable, do not hook; log the error.

Why it is safe (state this in comments if you like): before reuse the source has already been deleted, and the stop/return path detaches the buffers from the source, so the old names have no live owner. Deleting happens before the overwrite, while the array is still valid.

### 4.3 Counters and log

Process-wide counters, atomic (`Interlocked*`):

| Counter | Definition |
|---|---|
| `hits` | number of calls whose return address was `base + 0x197EAF` |
| `freed` | sum of `n` over hits; MUST equal `3 × hits` for this target |
| `gen` | sum of `n` over **all** calls, including non-hits; after pool init this starts at `768` (256 bundles × 3) |

Log file: **`Tom3_Fix.log` next to the game exe**. Create with `CREATE_ALWAYS`, `FILE_SHARE_READ | FILE_SHARE_WRITE` so test scripts can tail it while the game runs. Flush every line. Guard writes with a critical section.

Exact substrings the acceptance script matches (keep them):

```
Tom3_Fix.asi attached (Fix=<0|1>, ini=Tom3_Fix.ini)
fix: alGenBuffers hooked (orig=<ptr> delete=<ptr> target_ret=<ptr>)
priv=<n.n>MB fix=<0|1> hits=<n> freed=<n> gen=<n>
fix: ERROR <reason>
```

* `attached` line MUST be written on every load, before configuration is applied.
* `hooked` line MUST be written only when the fix is enabled and the hook is installed.
* Additional lines are allowed; the acceptance scripts match substrings, not the whole file. The reference writes one identity line before installing the hook so a support log says which build got the fix: `exe: base=<ptr> imageBase=400000 timestamp=4EC618FC sizeOfImage=83D000 LAA=<0|1>`. Reading those values from the main module's `IMAGE_NT_HEADERS32` at runtime also keeps the log honest when a wrapper renames or copies the exe.
* Status line MUST be written every **2 s** from a dedicated thread, and MUST start with `priv=%.1fMB`. The reference prints the process working set from `GetProcessMemoryInfo` (the `priv=` label is historical); the benchmark measures `PrivateMemorySize64` independently, so this value is diagnostic only.
* `fix: ERROR` MUST be used for “OpenAL32.dll not loaded”, “alDeleteBuffers not exported”, “alGenBuffers IAT slot not found”, and version-guard refusal (§1).
* When `Fix=0`, do not install the hook and do not emit the `hooked` line. The `attached` line still appears.

### 4.4 Configuration

File: **`Tom3_Fix.ini` next to the exe**, per-module (do not read the reproducer's ini).

Create it on first run if missing, with this content (ASCII/CRLF, comments in English):

```ini
[Fix]
; AudioMemoryLeakFix: release the stale OpenAL buffer names when the engine
; reuses a pooled {source + 3 buffers} object (the pool reuse path). This is the
; actual memory-leak fix for the crash after ~30 minutes of play.
; 0 = disabled, 1 = enabled
AudioMemoryLeakFix=1
```

Parsing: `GetPrivateProfileIntA("Fix", "AudioMemoryLeakFix", 1, path)`. Missing file or key = `1`. Only `0` disables. Existing files MUST NOT be overwritten.

### 4.5 Startup order

In `DllMain(DLL_PROCESS_ATTACH)`:

1. `DisableThreadLibraryCalls`.
2. Open the log.
3. Create the ini template if missing.
4. Read `AudioMemoryLeakFix`.
5. Log `attached`.
6. Optional: read `HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers` for this exe and WARN if `HIGHDPIAWARE` is present. Read-only; never write.
7. If enabled: install hook, log `hooked`, start the 2 s status thread.
8. Never fail process load because of the fix.

DPI: do nothing. The game manifest already declares awareness; the add-on MUST NOT call DPI APIs.

### 4.6 Non-goals

* Do not delete buffers from a source that still references them.
* Do not hook `alSourcei` / `alBufferData` / the stop path.
* Do not patch the game's call sites for the fix.
* Do not add a second leak fix for object destruction; not observed and out of scope.
* Do not change the audio stream or sample counts.

---

## 5. Reproducer contract — `Tom3AudioLeakRepro.asi`

Purpose: create measurable leak events without entering a level, without skipping the intro, and without clicking. The intro/menu music already creates a live sound object, so no input is required.

> **Expected noise — do not panic.** While `Tom3AudioLeakRepro.asi` is active (`repro` / `both` scenarios), the game will emit noise: the drive loop restarts the live sound object at a fixed rate, which produces rapid replays, clicks, and static-like audio. This is the intended behavior of the reproducer, not a crash, not a broken fix, and not an audio-device fault. Verdicts depend only on memory slope and log counters; the noise changes nothing. Lower the system volume while measuring and close the game normally afterwards. Do not "fix" the noise.

### 5.1 Modes

* `Mode=drive` (default, required): every tick, call the engine's restart routine at `base + 0x1951C0` with a validated live sound object and volume. One call performs one bundle take = one leak event when unfixed.
* `Mode=multiply` (OPTIONAL, parity only): redirect the two direct start calls at `0x40B60` / `0x40B67` to trampolines that replay the call `Multiplier` times, then jump back. Acceptance never uses this mode; skip it if it risks correctness.

### 5.2 Object scan

The drive thread MUST:

1. Sleep `WarmupMs` before the first scan/drive.
2. `VirtualQuery` from `lpMinimumApplicationAddress` to `lpMaximumApplicationAddress`.
3. Consider only `MEM_COMMIT`, `MEM_PRIVATE`, readable protection (`PAGE_READONLY`, `PAGE_READWRITE`, `PAGE_EXECUTE_READ`, `PAGE_EXECUTE_READWRITE`), never `PAGE_GUARD`.
4. Scan 4-byte aligned words for the vtable value `0xAEC9AC`.
5. Validate a candidate inside `__try/__except`:
   * `*(u32*)(p + 0x00) == 0xAEC9AC`
   * `res = *(u32*)(p + 0x58) != 0`
   * `ds  = *(u32*)(p + 0x14) != 0`
   * `state = *(u32*)(p + 0x5C) <= 6`
   * `*(u32*)(ds + 0x00)` lies inside the main module image, i.e. `base <= *(u32*)(ds + 0x00) < base + SizeOfImage`. The data source is an engine object, so its vtable must be an image address; without this check a stale heap block that still carries the sound-object vtable passes the four field tests above and then faults on the first engine call.
6. Estimate payload size from the data source: `ptr = *(u32*)(ds + 0x10)`, `end = *(u32*)(ds + 0x14)`, size = `end > ptr ? end - ptr : 0`.
7. Rank the valid objects: prefer the largest estimate `<= 1 MiB` (max bytes per event while keeping refill fast). When every estimate is `0`, keep **all** valid objects as an ordered candidate list (newest-first, i.e. descending address) instead of hard-coding one "first valid" object — address order is allocation order, so the lowest address is the oldest, and therefore the most likely stale, block. Re-scan if the current object becomes invalid.
8. Call `restart(obj, volume)` inside `__try/__except`. On fault: count it (`faults`), add the address to a skip list, clear the object and re-scan. A faulted address MUST NOT be selected again for the rest of the process. The scan is deterministic, so "clear the object and rescan" alone re-selects the same block and the drive loop then stalls at `drives=0` for the whole run.
9. Sleep `1000 / DriveHz` ms between drives (`DriveHz` clamped to `1..200`).

Volume: `DriveVolumePercent / 100.0f`; `0` is silent and still exercises the whole memory path. Do not add UI automation unless `PokeStart=1`.

### 5.3 Configuration (missing file = all defaults)

File: **`Tom3AudioLeakRepro.ini` next to the exe**. No template is required; the test script writes it.

```ini
[Repro]
Enabled=1
Mode=drive
DriveHz=10
DriveVolumePercent=0
PokeStart=0
PokeDelayMs=9000
WarmupMs=6000
Multiplier=30
```

* `Enabled=0`: log the attach line and do nothing else.
* `DriveHz` clamp `1..200`.
* `Multiplier` clamp `>= 2`.
* Do not share the fix's ini.

### 5.4 Log

File **`Tom3AudioLeakRepro.log` next to the exe**, same sharing/flush rules as the fix.

Exact substrings:

```
Tom3AudioLeakRepro.asi attached (enabled=<0|1> mode=<drive|multiply> mult=<n> hz=<n> poke=<n>)
priv=<n.n>MB mode=drive drives=<n> scans=<n> raw=<n> valid=<n> state=<n> obj=<ptr> size=<n> faults=<n> hz=<n> poke=<n>
priv=<n.n>MB mode=multiply events=<n> replays=<n> mult=<n>
```

Write status every 2 s. `drives` is the number of restart calls issued and is parsed by the acceptance script. `faults` is the number of restart calls that raised a fatal exception and had their object rejected; it is diagnostic only and is not part of any threshold. `drives > 0` with `faults` stuck at a small constant is the healthy shape.

### 5.5 Threading

* `DllMain` MUST stay short: parse config, log, then `CreateThread` for the drive thread and one for status.
* `DisableThreadLibraryCalls`.
* All engine calls happen off the loader lock.
* Guard object access with `__try/__except`; never crash the game because of a stale object.

---

## 6. Acceptance procedure

Run from the repository root. Game path resolution: `-GameDir` > `%TOM3_GAMEDIR%` > `tools\gamepath.txt`.

### 6.1 Compliance + artifact format

```powershell
powershell -ExecutionPolicy Bypass -File tools\check-submission.ps1
```

* FAIL if the tree contains the game exe, game DLLs, dumps, IDA databases, or decompiled listings.
* FAIL if `build\Tom3_Fix.asi` / `build\Tom3AudioLeakRepro.asi` are missing, not PE, not i386, or not DLLs.
* This step does not judge behavior.

### 6.2 Deployment / runtime

```powershell
powershell -ExecutionPolicy Bypass -File tools\verify-tom3fix.ps1
```

Expected result: `RESULT: PASS`, exit `0`.

It MUST observe:

* window appears within 40 s;
* `Tom3_Fix.log` contains `Tom3_Fix.asi attached`;
* with `Fix=1`, it contains `fix: alGenBuffers hooked`;
* with `Fix=0`, it does not;
* no `fix: ERROR`;
* deployed `Tom3_Fix.asi` hash equals the `-AsiPath`;
* no `Tom3AudioLeakRepro.asi` left in the install.

### 6.3 Leak benchmark

Acceptance criteria (fixed thresholds):

```powershell
powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario repro -DriveHz 30 -MeasureSeconds 10
powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario both  -DriveHz 30 -MeasureSeconds 30
powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario fix   -WarmupSeconds 25 -MeasureSeconds 15
```

Verdicts:

| Scenario | PASS | Not PASS |
|---|---|---|
| `repro` | process died from exhaustion, or slope `>= 60 MB/min` | `< 60` (WEAK `20–60`, FAIL `< 20`) |
| `both` | alive, slope `< 15 MB/min`, `fix.hits > 0` | flat + `hits=0` = INCONCLUSIVE; crashed or `>= 15` = FAIL |
| `fix` | alive, slope `< 15 MB/min` | crashed or `>= 15` = FAIL |

The measurement is ordinary least squares over `PrivateMemorySize64` samples, converted to MB/min. Do not change the fit, the sampling, the warmup defaults, or the thresholds.

### 6.4 One-shot acceptance

```powershell
powershell -ExecutionPolicy Bypass -File tools\run-acceptance.ps1
```

Runs compliance, deploys the fix, runs `verify`, then `repro`, `both`, `fix`, and exits `0` only if all pass. It does not add criteria.

### 6.5 Counter invariants

After `both` / `fix`, inspect the last status line:

```
freed == 3 * hits
gen   == 768 + 3 * hits
```

The scripts print these as `INFO`. They are evidence that only the reuse path was hit. If either fails, the hook is firing on the wrong site or the counters are wrong, even if the memory slope looks good.

Typical PASS shape from the reference implementation (drive 30 Hz, 30 s): `hits ≈ 1000`, `freed ≈ 3000`, `gen ≈ 7800`, slope `≈ 2–3 MB/min`. Absolute values vary with UI state and duration; proportionality and invariants matter.

---

## 7. Debugging map

| Symptom | Likely cause | Check |
|---|---|---|
| no `Tom3_Fix.log` | `.asi` not loaded | loader name/bitness; log path is game dir |
| `attached` but no `hooked` | fix disabled, IAT slot not found, or OpenAL missing | ini value; `fix: ERROR` line; `OpenAL32.dll` loaded |
| `both` flat but `hits=0` | reproducer never drove; wrong restart RVA; object validation too strict | repro log `drives=`, `valid=`, `state=`, `size=`; window open; warmup |
| `drives=0` while `valid>0` | every candidate faults: the scan selected a stale block that still carries the vtable, and the deterministic re-scan re-selects it | repro log `faults=` and `obj=`; require `*(u32*)ds` inside the image; skip faulted addresses |
| `repro` does not grow | reproducer not driving, or fix accidentally active | `Fix=0`; `drives` grows; `alGenBuffers` hook absent; slope `none` baseline |
| growth still high in `both` | hook not deleting (wrong return RVA), or deleting after generation | `hits>0` but `freed` wrong; log `target_ret` |
| game dies at startup | wrong PE flavor, loader mismatch, or DPI compatibility layer | i386 DLL; upstream v10.0.0 `dinput8.dll` (i386); remove `HIGHDPIAWARE` |
| `hits>0` but `freed≠3*hits` | counter race or `n` misread | atomic increments; use the hook argument `n` |
| `gen≠768+3*hits` | hook misses calls or adds extra ones | pass-through must always call original exactly once |

Fail closed: if any coordinate or export is missing, log an error and leave the engine untouched. A no-op add-on is acceptable; a wrong deletion is not.

---

## 8. Definition of done

- [ ] `build\Tom3_Fix.asi` and `build\Tom3AudioLeakRepro.asi` exist, are i386 DLLs, and are built from your own `src\`.
- [ ] `check-submission.ps1` exits `0`.
- [ ] `verify-tom3fix.ps1` exits `0`; log shows attach + hook; no `fix: ERROR`.
- [ ] `repro` exits `0` (growth `>= 60 MB/min` or process exhausted).
- [ ] `both` exits `0` (growth `< 15 MB/min`, `hits > 0`).
- [ ] `fix` exits `0` (idle growth `< 15 MB/min`).
- [ ] `freed == 3 × hits` and `gen == 768 + 3 × hits` in the `both` tail.
- [ ] No game files, dumps, decompiled output, or third-party binaries in the submission.
- [ ] Deployment restored: fix only, test ini files removed.

Report the exact commands run and their verdicts. Do not claim PASS without the scripts' exit codes.
