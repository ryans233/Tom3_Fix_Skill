# Tom3 Fix Skill — The Treasures of Montezuma 3 audio-leak fix: executable spec and acceptance

**中文版 / Chinese: [README_ZH.md](README_ZH.md)**

This repository is the **specification + acceptance** companion to the audio-leak fix for The Treasures of Montezuma 3. It does not contain the patch itself, and it contains no game code, binaries, assets, or decompiler output.

It lets an LLM (or any implementer) build an ASI patch that satisfies the contract using **only the behavioral contract and interoperability coordinates**, and then verify it with the criteria in `tools\`.

## What this project solves

**The user-visible problem:** `TreasuresOfMontezuma3.exe` is a 32-bit process. After roughly 30 minutes of continuous play the window becomes “Not Responding” and can only be killed and restarted; the same failure recurs. The audio object pool reuses `{1 source + 3 buffers}` objects but overwrites the old buffer names without ever releasing them. Every play therefore leaks roughly one full audio PCM asset, memory grows at about 44 MB/min until the 32-bit address space is exhausted, an allocation failure in the audio thread raises a modal dialog, and a deadlock with the audio tick thread follows (behavioral root cause in §2).

**What this repository provides:**

1. **An executable specification** (`SKILLS.MD`): a contract for *what* to fix, *where*, and *when never to fix it* — delete the previous generation of three buffers immediately before the pool reuse overwrites their names, and pass every other call through untouched; fail closed when coordinates do not match. It does not depend on decompiled text, and the implementer does not need game source code.
2. **Reproducible acceptance** (`tools\`): fixed thresholds separate “reproduced” from “fixed” — an unfixed build grows at `≥ 60 MB/min` or exhausts the process, while a fixed build stays below `< 15 MB/min`. The counters `freed = 3 × hits` and `gen = 768 + 3 × hits` prove the hook fires only on the reuse path.
3. **A compliance boundary**: do not modify the game exe, and do not distribute game files or decompiler output; only an independent `.asi` add-on is accepted.

**Not provided:** the patched binaries, the ASI loader, or the game itself. The implementer builds both `.asi` files from the specification; acceptance judges behavior only, not language, compiler, or code structure.

```
Tom3_Fix_Skill/
  README.md                  English: project overview, acceptance criteria, compliance boundary
  README_ZH.md               Chinese version of this file
  SKILLS.MD                  LLM handbook (English): defect model, fix contract, reproducer contract, acceptance
  tools/set-gamepath.ps1     remembers the game install directory (git-ignored)
  tools/check-submission.ps1 submission compliance + artifact format (does not start the game)
  tools/verify-tom3fix.ps1   deployment + runtime verification (static checks, log, hook)
  tools/test-tom3-audio.ps1  end-to-end leak benchmark (repro / both / fix / none)
  tools/run-acceptance.ps1   one-shot acceptance: compliance → deployment verification → three benchmarks
```

---

## 1. Target and deliverables

Target: `TreasuresOfMontezuma3.exe` (PE32 i386, ImageBase `0x400000`, no ASLR, 8,504,320 B).

The optional LARGEADDRESSAWARE edit changes a single `DllCharacteristics` bit (file offset `0x19E`, `0x8100` → `0x8120`) and nothing else: same code, same size, same coordinates. Both variants are the same target, and an implementation must not gate on the LAA flag (see §9).

Deliverables (created by the implementer; not shipped here):

| Path | Purpose |
|---|---|
| `build\Tom3_Fix.asi` | The fix; IAT-hooks `OpenAL32.dll!alGenBuffers` and releases the previous generation of three buffers only on the pool-reuse path |
| `build\Tom3AudioLeakRepro.asi` | Reproduction/load driver; calls the engine's own “stop → seek to start → restart” entry at a fixed rate to create leak events |
| `src\` + build script | Reproducible source for both DLLs; built with the implementer's own x86 toolchain (MSVC or MinGW-w64; see `SKILLS.MD` §3) |

Acceptance judges **behavior only**, not implementation language, compiler, or code structure. Both `.asi` files are ordinary 32-bit DLLs with a different extension, loaded in-process by the upstream Ultimate ASI Loader (`dinput8.dll`, see §4).

---

## 2. Why this patch is needed (behavioral root cause)

The game becomes “Not Responding” after long play in a 32-bit address space. Field evidence (memory curve, full memory dump, lock ownership) points to the audio subsystem's object pool:

1. When the engine reuses a pooled `{1 source + 3 buffers}` object, it deletes and recreates only the source, then calls `alGenBuffers(3, …)` **directly over** the previous generation of three buffer names. It never calls `alDeleteBuffers`.
2. The old buffers and their PCM payload are abandoned forever. The first-packet fill uses the whole stream length as the `alBufferData` size, so **every play leaks roughly one full audio asset**.
3. The OpenAL wrapper/DirectSound holds that PCM in private `VirtualAlloc` regions. Measured growth is about 44 MB/min; a 32-bit process runs out in roughly 30 minutes.
4. Once memory is exhausted, new allocations fail. The static CRT inside `wrap_oal` calls `abort()` and raises a modal dialog; the modal message loop re-enters the game window procedure and forms an ABBA deadlock with the audio tick thread. The visible result is “Not Responding”, not a clean crash exit.

The fix does not change audio quality, volume, or timing: it releases the buffer names that are about to become orphaned, immediately **before** they are overwritten. The detailed contract is in `SKILLS.MD`.

---

## 3. Acceptance criteria (behavioral)

All criteria are implemented by `tools\verify-tom3fix.ps1` and `tools\test-tom3-audio.ps1`; they compare against the artifacts passed by the caller (`-AsiPath` / `-ReproAsiPath`), which may live in any directory.

### 3.1 Deployment / runtime verification

| Check | Criterion | Level |
|---|---|---|
| Game exe | present | FAIL |
| ASI Loader `dinput8.dll` | present; should be the 32-bit build of upstream Ultimate ASI Loader v10.0.0 | FAIL |
| `Tom3_Fix.asi` | present; deployed copy has the same SHA256 as the passed artifact | FAIL / WARN |
| `Tom3_Fix.ini` | missing file or key = `AudioMemoryLeakFix=1`; explicit `0` disables | PASS / WARN |
| `HIGHDPIAWARE` compatibility layer | not set (read-only check) | WARN |
| Game startup | window appears within 40 s | FAIL |
| Log | contains `Tom3_Fix.asi attached`; contains `fix: alGenBuffers hooked` when enabled | FAIL |
| Log errors | no `fix: ERROR` | FAIL (judged indirectly by the hook check) |
| Reproducer left behind | no `Tom3AudioLeakRepro.asi` in the install directory | WARN |
| LARGEADDRESSAWARE | informational only; not the fix | WARN |

Exit codes: `0` = no FAIL; `1` = at least one FAIL.

### 3.2 Leak benchmark (hard-coded thresholds)

| Scenario | Deployment | Criterion | Exit |
|---|---|---|---|
| `repro` | fix (`Fix=0`) + reproducer | process OOM/crash, or growth `≥ 60 MB/min` → PASS; `20–60` → WEAK; `< 20` → FAIL | 0 only on PASS |
| `both` | fix (`Fix=1`) + reproducer | alive and growth `< 15 MB/min` and `fix.hits > 0` → PASS; flat but `hits=0` → INCONCLUSIVE; still growing/crashed → FAIL | 0 only on PASS |
| `fix` | fix only (idle) | alive and growth `< 15 MB/min` → PASS | 0 only on PASS |
| `none` | fix only (`Fix=0`, reference baseline) | reports growth only, no verdict | 1 |

> **Noise warning (expected; do not panic):** the `repro` and `both` scenarios load `Tom3AudioLeakRepro.asi`, which repeatedly triggers the engine's “stop → seek to start → restart” entry at a fixed rate. The game will therefore emit **noise** (rapid replays, clicks, static-like audio). This is the reproducer's intended behavior — not a game crash, not a failed fix, and not an audio-device fault. Verdicts depend only on memory growth and log counters; noise affects nothing. Lower the system volume while measuring and close the game normally afterwards.

Measurement: launch → wait for the window → warm up (default 26 s, covering the intro) → sample `PrivateMemorySize64` every 250 ms, record once per second → least-squares fit in `MB/min` → read the tail of the patch log for counters → close the game and restore the deployment (leave only `Tom3_Fix.asi`, delete both ini files so they are regenerated next time).

### 3.3 Counter invariants (diagnostic, does not change the verdict)

After `both` / `fix`, the log tail should satisfy:

```
freed == 3 × hits
gen   == 768 + 3 × hits
```

`768` is the initial generation count for the 256 bundles in the pool. These identities prove the hook **fires only on the reuse path**. The scripts print them as `INFO`; they do not participate in PASS/FAIL.

---

## 4. Quick start

Prerequisites: Windows 10/11 x64, PowerShell 5.1+, a legally installed copy of the game, the upstream ASI Loader (`dinput8.dll`, see below), and an x86 toolchain that can produce a 32-bit DLL (MSVC or MinGW-w64; for the implementer).

**Use the upstream ASI Loader. Do not write or “invent” a loader.** Download the Win32 asset `Ultimate-ASI-Loader-NoPDB.zip` (or `Ultimate-ASI-Loader.zip`) from [ThirteenAG/Ultimate-ASI-Loader v10.0.0](https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases/tag/v10.0.0), take its 32-bit `dinput8.dll`, and place it in the game directory. Do not switch to another version, do not use an x64 build, and do not write your own proxy DLL: the loader is not a deliverable of this repository and must not be committed (`check-submission.ps1` rejects it).

> The `repro` / `both` scenarios make the game produce noise. This is the reproducer's intended behavior; see the noise warning in §3.2.

```powershell
# 1) Remember the game directory (priority: -GameDir > TOM3_GAMEDIR > tools\gamepath.txt)
powershell -ExecutionPolicy Bypass -File tools\set-gamepath.ps1 -GameDir "E:\...\The Treasures of Montezuma 3"

# 2) Implementer builds build\Tom3_Fix.asi and build\Tom3AudioLeakRepro.asi per SKILLS.MD

# 3) Submission compliance + artifact format (does not start the game)
powershell -ExecutionPolicy Bypass -File tools\check-submission.ps1

# 4) One-shot acceptance (deployment verification + repro + both + fix, ~3 minutes)
powershell -ExecutionPolicy Bypass -File tools\run-acceptance.ps1

# Or run the steps individually
powershell -ExecutionPolicy Bypass -File tools\verify-tom3fix.ps1
powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario repro -DriveHz 30 -MeasureSeconds 10
powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario both  -DriveHz 30 -MeasureSeconds 30
powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario fix   -WarmupSeconds 25 -MeasureSeconds 15
```

You can pass your own artifact paths:

```powershell
powershell -File tools\test-tom3-audio.ps1 -Scenario both -AsiPath D:\out\Tom3_Fix.asi -ReproAsiPath D:\out\Tom3AudioLeakRepro.asi
```

---

## 5. Script behavior and safety boundary

* All scripts write/delete `Tom3_Fix.asi`, `Tom3AudioLeakRepro.asi`, their ini files, and logs in the **game install directory**, then restore it to “`Tom3_Fix.asi` only, test ini files removed”. Confirm the directory first.
* Scripts forcibly terminate the `TreasuresOfMontezuma3` process; save your progress before running.
* Scripts do not modify the game exe, do not write the registry (they only read `HIGHDPIAWARE`), do not use the network, and do not collect data.
* `run-acceptance.ps1` overwrites the installed `Tom3_Fix.asi` with the passed `-AsiPath` first, and leaves that file in place afterwards.
* Injection uses only the upstream Ultimate ASI Loader (`dinput8.dll`); it does not implement a loader, bypass DRM, or modify/distribute the game itself.

---

## 6. Local tooling

| Script | Purpose | Notes |
|---|---|---|
| `tools\set-gamepath.ps1` | Remember the game install directory | Priority `-GameDir` > `%TOM3_GAMEDIR%` > `tools\gamepath.txt`; file is git-ignored |
| `tools\check-submission.ps1` | Submission compliance and PE format check | Does not start the game and does not judge behavior |
| `tools\verify-tom3fix.ps1` | Deployment + runtime verification | Supports `-AsiPath` / `-ReproAsiPath`; compares the deployed copy's SHA256 with the passed artifact |
| `tools\test-tom3-audio.ps1` | End-to-end leak benchmark | Scenarios `repro` / `both` / `fix` / `none`; exit code `2` when an artifact is missing |
| `tools\run-acceptance.ps1` | Aggregate acceptance | Runs the checks above and the three benchmarks; adds no criteria |

---

## 7. Legal and compliance boundary

This repository is an **interoperability specification**, not a redistribution of game content:

* It **contains no** game exe, DLL, assets, saves, memory dumps, IDA databases, disassembly listings, or decompiled pseudocode. The repository's `.gitignore` and `check-submission.ps1` block common accidental inclusions.
* It **does not modify** the game executable. The patch is an independent DLL loaded by the upstream Ultimate ASI Loader v10.0.0 (`dinput8.dll`) and calls only public exports of `OpenAL32.dll`.
* It **does not bypass** any DRM, activation, or integrity check, and it does not provide the game or downloads.
* The addresses/RVAs, field offsets, and vtable addresses in this repository are **functional facts required for interoperability** with the unmodified target binary. They are not expressive content and contain no instructions or code from the target program.
* Acceptance scripts run locally against a copy the user is **licensed to use**. They do not upload, collect, or redistribute any game data.
* Game names, trademarks, and all game content belong to their owners. This project is not affiliated with or endorsed by them.
* Check the law of your jurisdiction and the game EULA before use. This repository is not legal advice.

Implementers MUST follow the “Legal & evidence boundary” in `SKILLS.MD`: **never** put decompiler output, dump contents, or game files into a submission, log, issue, or acceptance record.

---

## 8. Requirements

| Item | Requirement |
|---|---|
| OS | Windows 10/11 x64 |
| Shell | PowerShell 5.1+ |
| Game | A legally installed copy of The Treasures of Montezuma 3 (Steam, etc.) |
| Loader | The 32-bit `dinput8.dll` from upstream Ultimate ASI Loader **v10.0.0** (from the upstream release; do not reimplement it) |
| Build | Any x86 toolchain producing a PE32 DLL with no non-system runtime dependency — e.g. Visual Studio 2019/2022 (`cl` + `/MT`) or MinGW-w64 (`i686-w64-mingw32-g++ -m32 -static`); artifacts must be i386 DLLs |
| Display | A desktop session that can create a window (the scripts wait for the game window) |

---

## 9. Non-goals

* Do not fix the `% sampleFrames` divide-by-zero hazard (not reproduced).
* Do not address the audio/video desynchronization frame-time mechanism (inferred, not measured).
* Do not promise to eliminate all memory growth. The fix covers only “buffer leak when reusing a pooled object”; the residual 1–3 MB/min is normal engine fluctuation.
* Do not promise cross-version compatibility: after an exe update, the `0x197EAF` hit site may stop matching. The implementation must fail closed (`hits=0`, never delete wrongly). The recommended guard is a one-read check that `0x197EA9` still holds `FF 15 <IAT slot>` for the slot you just hooked — file size and `SizeOfImage` cannot distinguish builds, and they are identical between the stock and the LAA-enabled file, so neither variant may be rejected.

---

## 10. License

The documentation, scripts, and specification in this repository are original content under the MIT License (see `LICENSE`). That license **does not cover** the game itself, game assets, OpenAL, the ASI Loader, or other third-party components; their rights and licenses remain with their respective owners.

---

## 11. Self-check record

To avoid “the scripts only look correct”, the acceptance chain was run end-to-end with the reference artifacts on the author's machine (same machine, same game install, same 30 Hz drive):

| Step | Result | Key data |
|---|---|---|
| `check-submission.ps1` | PASS | two i386 DLLs; no forbidden files |
| `verify-tom3fix.ps1` | PASS | window, `attached`, `hooked`, no `fix: ERROR` |
| `repro` (10 s) | PASS | 789.5 MB/min, `drives=774` |
| `both` (30 s) | PASS | 1.4 MB/min, `hits=1274`, `freed=3822`, `gen=4590` |
| `fix` (idle 15 s) | PASS | 1.9 MB/min, `hits=1`, `freed=3`, `gen=771` |
| `run-acceptance.ps1` | PASS | 5/5 steps |

The last two also satisfy `freed = 3 × hits` and `gen = 768 + 3 × hits`. These values are local measurements proving the scripts run and distinguish “reproduced” from “fixed”; absolute numbers vary by machine, screen, and duration. Verdicts depend only on the thresholds above.
