# Dynamic Tyres

A BeamNG.drive mod that makes tyre grip change as you drive, plus a live UI app showing every wheel.

It works on its own in freeroam, scenarios and any career, and doesn't need RLS Career Overhaul. When RLS Career Overhaul's own tyre system or *Tyre Wear and Thermals* runs on a car, Dynamic Tyres stands by on that car and leaves grip to it. The UI app tells you when this happens.

## What it simulates

| Effect | What happens |
| --- | --- |
| **Temperature** | Each tyre has three tread zones (inner, middle and outer) plus the carcass. Sliding, rolling flex and brake heat warm them; airflow, rain and water cool them. Every compound has a grip window: cold slicks are slippery, road tyres barely care, and overheated tyres lose grip and wear fast. |
| **Wear** | Tread is lost with distance and with real sliding (burnouts, slides, lock-ups). It goes faster when the tyre is overheated or at the wrong pressure, and on gravel and sand. Bald tyres lose a lot of grip and puncture. |
| **Pressure** | Hot tyres gain pressure (gas law). The pressure is applied to the physics tyre, so it changes how the car rides as well as how it grips. Under-inflation heats the shoulders; over-inflation heats the middle and shrinks the contact patch. You can adjust the front and rear cold pressure in the app. |
| **Surface and wet** | The tyre type is detected from the tyre part (slick, sport, road, all-terrain, mud-terrain or winter), or you can pick it per axle in the app. Each type grips differently on tarmac, dirt, mud, sand, grass, snow and ice. Rain wets the road over time and it dries out afterwards. Worn tread clears less water. |
| **Aquaplaning** | Standing water is patchy, and each side of the car runs through its own puddles. In deep water it starts around 95 km/h on new road tyres and around 65 km/h on bald ones. Partial aquaplaning (light, vague steering) starts about 20% below that. A fully aquaplaning tyre keeps only about 7% of its wet grip, so one side letting go yanks the car. |
| **Snow and ice** | In Auto mode, falling snow settles on the roads below about 2°C. Wet roads freeze into ice below 0°C, rain below freezing becomes freezing rain, and everything thaws back into water above 0°C. Snow leaves road tyres about 45% of their grip and winter tyres about 72%; ice leaves road tyres about 15%, winter tyres about 32% and slicks about 10%. You can also force Snow, Ice or Black ice. |
| **Extras** | New tyres need about 1.5 km to scrub in. Slicks and sport tyres lose a little peak grip with each heat cycle. Locking the wheels causes flat spots. Worn-through and overheated tyres can puncture or blow out. |

Every effect can be switched off on its own. Grip effect, heat rate and wear rate each have a slider.

## Install

1. Build the zip with `./build.sh`, or download `dynamic_tyres.zip`.
2. Put the zip in your BeamNG user folder under `mods/` and leave it zipped.
3. In game, open the UI Apps editor, click **Add app** and pick **Dynamic Tyres**.

## The app

- **Wheel view:** colour-coded tread zone temperatures (blue is cold, green is in the window, red is overheated), plus core temperature, pressure, tread and total grip, with warnings for flats, aquaplaning, flat spots and exposed cords.
- **≡ view:** a breakdown of grip into temperature, wear, pressure, surface, wet and extras, plus distance and heat cycles.
- **⚙ view:** all the settings, plus:
  - **Road:** Auto (follows the weather), Dry, Damp, Wet, Soaked, Snow, Ice or Black ice.
  - **Snowfall:** Off, Light or Heavy. This spawns falling snow if the level has a snow effect, and keeps the temperature below freezing so the snow settles. Without a snow effect, snow still builds up on the roads.
  - Ambient temperature, and units (°C/°F, psi/kPa/bar).
  - **Current vehicle:** tyre type per axle (Auto, Slick, Sport, Road, All-terrain, Mud-terrain, Winter), fit new tyres, tyre warmers and pressure adjustment.

Settings are saved to `settings/dynamicTyres.json` in your user folder.

## Files

- `lua/vehicle/extensions/dynamicTyres.lua`: the per-vehicle simulation.
- `lua/ge/extensions/dynamicTyresManager.lua`: settings, weather and ambient temperature. It loads the simulation into every vehicle and runs the app's commands.
- `scripts/dynamic_tyres/modScript.lua`: starts the manager.
- `ui/modules/apps/DynamicTyres/`: the UI app.

## Notes

- BeamNG's reset repairs the car, so by default it also fits new tyres. Turn off **New tyres on vehicle reset** to keep wear across resets (temperatures and flats still reset).
- Tyre state lasts for the session; it isn't saved between game launches.
- While it's active, the mod replaces BeamNG's built-in temperature-based tyre friction with its own model.
