<p align="center">
  <img src="docs/icon.png" width="128" alt="BatteryOracle">
</p>

<h1 align="center">BatteryOracle</h1>

<p align="center">
  <b>Tells you in the morning whether you need to bring your charger today.</b><br>
  A macOS menu bar app that learns how you use your Mac and forecasts battery life with
  <a href="https://github.com/mistralai/timestral">Mistral Timestral</a>, running locally.
</p>

<p align="center">
  <img src="docs/forecast.png" width="340" alt="Forecast">
  &nbsp;
  <img src="docs/habits.png" width="340" alt="Habits">
</p>

<p align="center">
  <img src="docs/menubar.png" width="720" alt="The battery in the menu bar: normal, charging, low power mode, below threshold">
</p>

> BatteryOracle is a macOS menu bar app that learns how much power your Mac draws through the day and uses Mistral's Timestral time-series model, running locally on the CPU, to tell you whether the battery will last until the evening, with a probability, not a guess.

---

## What it does

- **Verdict with a probability**: *You'll make it to the end of the day*, *You'll make it, but it's close* or *Bring your charger*, with the probability of staying above the minimum threshold until the chosen time.
- **Chart for the next few hours**: actual level over the last 12 hours, median forecast and two uncertainty bands (80% and 50%), with hover to read each point.
- **After the end of the day**: the forecast shifts to the next 3 hours and the remaining battery life, since the Mac may stay on much longer. It switches back to the end-of-day forecast after the time of the morning alert.
- **Habits**: average hour-by-hour consumption, daily energy split between battery and charger, peak usage hour, typical battery life.
- **Alerts**: one notification in the morning if the day looks tight, and another during the day if the pace isn't holding up. They only arrive while the screen is on: if they would have fired while the Mac was closed, they wait until you reopen it.
- **Battery health**: remaining capacity, cycle count and temperature right in the popover.
- **Apple-style battery icon in the menu bar**, with the percentage inside to save space. It turns **yellow** when Low Power Mode is on and **red** below the chosen threshold; a lightning bolt appears while charging. If you won't make it to the end of the day at this pace, a warning triangle appears next to the battery, without hiding it.
- **Low Power Mode switch** in the popover (see below).
- Launch at login, configurable threshold and times, percentage-inside-the-icon toggle in settings.

## How it works

```
 IOKit (AppleSmartBattery)          every 2 minutes: level, power source, system power draw (W)
          │                         + sleep/wake events
          ▼
 history.csv  ─────────────▶  15-minute power series (last 30 days)
                                         │
                                         ▼
                Mistral Timestral  ◀── known covariates: time of day, day of week, weekend
                (short-lived Python process)  past covariate: plugged into power
                                         │
                                         ▼  21 consumption quantiles for the next 26 hours
                      discharge simulation  →  level, time threshold is crossed, probability
```

The key choice is **forecasting power draw, not the percentage**. The percentage depends on when you plug in the cable, which is unpredictable. Power draw depends on how you work, which is very regular. The Mac measures system power draw even while plugged in (`PowerTelemetryData.SystemLoad`), so every minute of use becomes useful data.

From there the battery is simulated: *level = current level − forecast consumption ÷ capacity in Wh*. Each consumption quantile produces a level path, and the probability of reaching the end of the day is the quantile that lands exactly on the threshold. The bands are deliberately conservative, since they assume the heaviest hours stack up together.

Two constants are learned from your own data:
- **sleep consumption**, measured from the battery drain during unplugged nights;
- **calibration**, i.e. the ratio between the actual battery drop and the integrated power draw. It corrects the Wh estimate and measurement differences.

Until the Timestral engine is installed, the app uses a **statistical profile**: power-draw quantiles for the same time slot on similar days over the last two weeks. So it works right away.

## Efficiency

Measured on the installed app, at rest (macOS 27, Apple Silicon):

| | |
|---|---|
| App at rest | **0% CPU, 0 wakeups, ~16 MB of memory** (`footprint`, SwiftUI + Swift Charts) |
| Sampling | direct IOKit read every 2 minutes (60 s tolerance, so the system coalesces it with other wakeups), no external process |
| Mac closed | **no activity with the screen off**: the Mac's partial wakeups (Power Nap, Mail and iCloud checks: thousands per day) are ignored, and the night counts as a single sleep period in the history |
| Power source change | immediate system notification, no polling |
| Forecast | ~2 s per hour on battery, every 3 hours while plugged in (the outcome still updates with the real level on every reading); the Python process exits immediately, so **nothing stays in memory** between forecasts |
| Timestral 5M | ~10 ms of inference, the rest is PyTorch startup; *utility* priority, 2 threads |
| History | append-only CSV, ~1 MB for 30 days, compacted at launch |

## Low Power Mode without a password

The popover has a switch that turns macOS Low Power Mode on and off. There's no public API for this, so the app runs `pmset`, which requires root permissions. To avoid typing your password on every click, install a one-time `sudoers` rule limited to those two exact commands:

```sh
t=$(mktemp) && echo "$(whoami) ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1" > $t \
  && sudo visudo -cf $t && sudo install -m 440 -o root -g wheel $t /etc/sudoers.d/batteryoracle; rm -f $t
```

To remove it: `sudo rm /etc/sudoers.d/batteryoracle`.

The app tries, in order: `sudo -n pmset` (silent, with the rule), two quick commands called `BatteryOracle lowpowermode on` and `BatteryOracle lowpowermode off` (*Set Low Power Mode* action, also without a password), and finally `pmset` with a system password prompt.

## Installation

Requirements: macOS 14 or later, a Mac with a battery, Xcode command line tools (`xcode-select --install`). The engine also needs Python 3.10–3.13 (`brew install python@3.13`).

```bash
git clone https://github.com/migalella/BatteryOracle.git
cd BatteryOracle
make install      # builds BatteryOracle.app, copies it to /Applications and launches it
```

Then install the engine from the app's settings (**Install Timestral**) or from the terminal:

```bash
make engine
```

The engine lives in `~/Library/Application Support/BatteryOracle/engine`: a private Python environment with PyTorch, about 1 GB in total. Timestral 5M weights are 21 MB. You can switch to the 28M or 123M models from settings.

> The app is signed ad-hoc. On first launch, if macOS blocks it, open it with right-click → **Open**.

### Try it right away

```bash
make demo
```

Loads two weeks of simulated usage and shows the popover in a window.

## Privacy

Everything stays on your Mac. The history is stored at `~/Library/Application Support/BatteryOracle/history.csv` and the model runs locally. The only network access is the one-time download of PyTorch and the weights from Hugging Face during engine installation.

## Structure

```
Sources/BatteryOracle/
  Battery.swift          IOKit reads and power-source-change notifications
  History.swift          logging, 15-minute series, sleep handling, calibration, habits, demo
  Forecaster.swift       Timestral engine, statistical profile, discharge simulation
  AppModel.swift         sampling, scheduling, notifications, low power mode, settings
  Views/                 popover, charts, habits, settings
  Views/MenuBarBattery   the hand-drawn menu bar icon (percentage inside, colors)
engine/forecast.py       JSON request on stdin → consumption quantiles on stdout
scripts/                 .app build, icon, engine installation, docs/menubar.png rendering
```

## Known limitations

- Capacity in Wh is estimated from cell mAh and nominal voltage; calibration corrects the error after a few discharge cycles.
- `SystemLoad` telemetry is complete on Apple Silicon Macs. On Intel models the app uses battery current, which is only known while the Mac is unplugged.
- With the screen off (lid closed, or the Mac idle on power with the screen inactive) the app doesn't log data: partial wakeups can't be told apart from idle time, and logging them would skew sleep consumption. In clamshell mode with an external monitor it works normally.
- Low Power Mode needs the `sudoers` rule to avoid a password prompt (see above).
- Notifications and launch at login require the app installed as a bundle (`make install`), not `swift run`.
- A few hours of data are needed for the first forecast, and a few days for it to become reliable.

## Credits

- [Mistral Timestral](https://github.com/mistralai/timestral): inference code under Apache-2.0, weights under Mistral AI's Modified MIT license.
- Idea inspired by a reel from [@mattbonfanti](https://www.instagram.com/mattbonfanti/).

Code released under the [MIT license](LICENSE).
