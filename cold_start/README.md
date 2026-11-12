# Cold Start

A BeamNG.drive mod that makes engines hard to start in the cold, with a small UI app showing outside temperature, engine temperature, battery charge and how hard the next start will be.

It works on its own in freeroam, scenarios and any career. Written against BeamNG.drive **0.39 / 0.40**.

## What it simulates

| Effect | What happens |
| --- | --- |
| **Time to fire** | A warm engine starts as it always did. Below about 15°C it has to be cranked before it catches, and the colder it is the longer that takes: about 1 s at 0°C, 4 s at −20°C, 6 s at −24°C and 12 s at −30°C on a full battery. It is random, so you never know if this attempt is the one. |
| **False starts** | A very cold engine can catch, stumble and die again. |
| **Battery** | Charge, cold cranking power and voltage. Every attempt drains it (roughly 0.7% per second of cranking at −24°C). A cold or half-empty battery turns the engine slower, which makes it less likely to fire. Below about 20% at −24°C the starter only clicks. The alternator charges it back while the engine runs, and leaving the ignition or lights on drains it. |
| **Starter** | Turns slower and sounds lower when it is cold or short of volts. It overheats after about 24 s of cranking and cuts out until it has cooled. |
| **Diesel glow plugs** | Switch the ignition on and wait (about 11 s at −24°C). Without them a cold diesel rarely starts. They time out after a while, so cycle the key if you waited too long. |
| **Flooding** | Long cranking of a cold gasoline engine wets the plugs and makes it harder still. Hold full throttle while cranking to clear it, or wait a few minutes. |
| **After the start** | Fast idle and rough running until there is some heat in the engine. |
| **Cold wear** | Revving hard on cold oil permanently adds engine friction (until the vehicle is reset). Can be switched off. |
| **Block heater** | Plug it in on a parked car to warm the engine. It is sped up to about two minutes and unplugs itself when you drive off. |

Electric vehicles are left alone. AI drivers always get a normal start.

## Every engine starts differently

The mod works out what each engine is and gives it its own starting character. The app shows what it found (for example "8 cyl · carb"), with the full line in settings.

| What | How it is found | What it changes |
| --- | --- | --- |
| **Fuel system** | From the fitted parts (carburetor, throttle-body or port injection). If the parts do not say, from the model year: before 1984 carburetor, before 1991 throttle-body, otherwise injection. | A carburetor takes about twice as long to fire in the cold, floods about twice as fast, dies again more often and runs rough for longer. Throttle-body injection sits in between. Injection from 2005 on is a little better than the baseline. |
| **Carburetor throttle** | | A little throttle while cranking works the accelerator pump: it fires sooner but floods faster. |
| **Diesel type** | Model year: before 1998 is an old mechanical-pump diesel, later is common-rail. | Old diesels need about 50% longer on the glow plugs, are slower to fire and run rough for longer. |
| **Cylinders** | The engine's sound setup. | More cylinders fire sooner and catch more smoothly; a three-cylinder is the roughest. |
| **Displacement** | Estimated from peak torque, because the game does not store it. | Bigger engines get a bigger battery but pull more starter current, so they sag the voltage more. Diesels over 6 L glow for longer. |
| **Starter and base start time** | The engine's own values in the game. | A weak starter cranks slower in the cold. |

At −24°C in testing, a 1996 injected four-cylinder started on the first 10-second attempt about 70% of the time and a 1968 carbureted V8 about half the time.

## Install

1. Build the zip with `./build.sh`, or download `cold_start.zip`.
2. Put the zip in your BeamNG user folder under `mods/` and leave it zipped.
3. In game, open the UI Apps editor, click **Add app** and pick **Cold Start**.

## Using it

1. Set the outside temperature with **−** / **+** on the *Outside* tile (Shift-click for 5 degrees), or pick one in settings.
2. Switch the engine off, then hold the ignition key to crank. The *Start* tile shows the rating beforehand and the cranking speed while you crank.
3. If it will not go: let the starter rest, clear a flooded engine with full throttle, plug in the block heater, or charge the battery.

## The app

- **Outside:** the air temperature at the car. It can differ a little from what you set, because the game takes the setting as the sea-level temperature.
- **Engine:** the game's own engine block temperature.
- **Battery:** charge and voltage. The voltage sags while cranking and rises to about 14 V while charging.
- **Start:** easy, normal, hard, very hard, almost impossible or won't start, with the cranking time to expect. Shows cranking, catching or running during a start.
- **Flood / Glow** and **Starter** bars, and a hint line that tells you what is going on.
- **Gear button:** settings.
  - **Outside temperature:** from the level, presets, or a slider from −45°C to 45°C.
  - **Realism:** Arcade, Realistic or Brutal.
  - **Cold start simulation**, **Cold engine wear**, **Cold engine after spawn / reset**, **Spawn with ignition off**, **Full battery on vehicle reset**, **Parked and traffic cars too**.
  - **Battery:** drain and charging speed. Charging is 4× real time by default.
  - **Current vehicle:** cold soak now, block heater, charge battery, or set the battery to 70%, 40% or 15%.

Settings are saved to `settings/coldStart.json` in your user folder.

## How it works

- `lua/vehicle/extensions/coldStart.lua`: the per-vehicle simulation. BeamNG's starter kills the throttle until its start timer runs out. While the starter is engaged this extension holds that timer and decides when to let go, so the game's own starter, sounds, ignition levels and stall handling keep working. Cranking speed is changed through the starter's torque and speed only. Engine friction is not touched, except by cold wear.
- `lua/ge/extensions/coldStartManager.lua`: settings and the outside temperature. The temperature is written to the game's own environment temperature, so engine thermals, the temperature gauge, air density and exhaust steam follow it. It loads the simulation into every vehicle and runs the app's commands.
- `scripts/cold_start/modScript.lua`: starts the manager.
- `ui/modules/apps/ColdStart/`: the UI app.

## Notes

- BeamNG pre-warms engines on spawn by default. **Cold engine after spawn / reset** overrides that while the mod is on.
- By default only cars you have driven are simulated. Turn on **Parked and traffic cars too** to include the rest.
- Battery charge lasts for the session and is refilled by a vehicle reset unless you turn that off.
- If Dynamic Tyres is installed, it follows the outside temperature set here unless you set its own ambient temperature.
