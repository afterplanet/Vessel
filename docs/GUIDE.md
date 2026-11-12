# Vessel user guide

The details behind each part of Vessel. For an overview, see the [README](../README.md).

## Choosing a decoder

Each satellite gets its decoder automatically, in this order:

1. A decoder picked by hand for that satellite, saved in `~/Library/Application Support/Vessel/pipeline_choices.json`.
2. The rules in `pipeline_rules.json`, kept in the same folder, first match winning. Each rule lists decoders by preference, and the first that can run live is used. If only non-live ones exist, the satellite is saved to file.
3. A decoder named exactly after the satellite, which picks up new decoders without a rule.
4. The analog demodulator for voice and tone downlinks.
5. No decoder, in which case the signal can still be saved to file.

At every start, the app compares its decoders with the latest upstream definitions and downloads what changed. Each file is tested against the engine, and any that would stop a decoder loading is left out. Accepted ones go in `engine-run/pipelines.json`.

## Using it

- **Globe:** drag to rotate, scroll or pinch to zoom, double-click to zoom in.
- **Satellites:** hover for the name, click to lock.
- **Footer:** click a type to show only that type, and click it again to show all.

  | Type | Colour | Rule (first match wins) |
  |---|---|---|
  | Deep | Green | Period over 1500 min |
  | HEO | Magenta | Eccentricity 0.25 or more |
  | GEO | White | Period 1380–1500 min |
  | MEO | Purple | Period 130–1380 min |
  | SSO | Orange | Inclination 95.5–104°, eccentricity under 0.1 |
  | LEO | Blue | Everything else |

- **Address bar:** type an address and choose a suggestion, or click the cursor button and then click the globe. A red pulse marks the spot.
- **Radar:** shows the sky above the address, with straight up at the centre and north at the top. It plots the highest 24 satellites above the horizon that your filters and groups allow, plus the latest few from the approaching list once they rise, ringed so they stand out. Geostationary and deep-space objects hang still, so they appear only when their type is chosen in the footer. A locked satellite always appears, with its current or next pass drawn across the sky in its type's colour, faint where it has been. Its countdown switches from *Arrives in* to *Leaves in* as it rises, and moves on to the next pass, however far away, once it sets. **Now overhead** opens a list of everything in view, and **Next approaching** lists the next 10 to rise, timed to the second. Fast orbits are predicted 15 minutes ahead and slower ones 3 hours ahead. Hover a dot for its name and flag.
- **History:** the clock beside the search bar lists every satellite you've locked, by day and time. Click one to lock it again. It's kept in `~/Library/Application Support/Vessel/lock_history.json`.
- **Zoom:** imagery streams in as you zoom, down to about 10 km up. Tiles are cached in `~/Library/Caches/Vessel/tiles`.
- **Satellite panel:** rotating model, country, launch year, category, frequency, encryption, and the next event once a location is set.
- **Listener panel:** source, hardware, spy hosts, and location with auto-suggestions.
- **Spy hosts:** clicking a host connects to it. A spinner shows next to the client count, then a green tick that stays, or a red cross if it fails. Connection details and strength appear under the selected host. Strength comes from round-trip time and lost attempts, not spare bandwidth.
- **Spectrum:** **Show spectrum** in the Capture panel opens a live plot and waterfall at the top right of the globe, showing the frequency and whether it's listening or recording. The arrows button makes it larger, and hovering reads off a frequency.
- **Receive and Transmit:** the toggle beside the window controls switches between the two. Leaving Transmit stops any transmission.
- **Capture panel:** choose **Live decoding**, which decodes as it receives and makes images and products when it stops, or **Save to file only**, which saves the raw signal for later. With **Listen automatically** on, listening starts when the tracked satellite is in view, using its frequency, decoder and sample rate. It restarts when the satellite or host changes and stops when the satellite sets. **Stop** holds until you press **Start listening** or the satellite or host changes. Saving to file stops itself below 2 GB of free disk. Output goes to `~/Documents/Vessel`, and listening adds files there on every pass.
- **AGC:** the Capture panel offers automatic gain wherever the source really has it: RTL-SDR, RTL-TCP, Airspy, HydraSDR, Airspy HF+, SDRplay, PlutoSDR, bladeRF and Aaronia. Elsewhere it's greyed out and says why. The choice is remembered per source.
- **Saved files:** the folder beside that toggle shows a bar while saving, and clicking it drops down recent files, like Safari's downloads. Each opens with a click or shows in Finder.
- **Results:** **All Results** in that dropdown opens every capture with its times and what came of it. Images show as thumbnails. Click any image, readable file or audio file to view it in Quick Look, or download a copy.

## Transmit

Transmit works only on public amateur satellite uplinks, and only while you hold the button. The frequency always comes from the list below, so there is no way to type one in.

An uplink qualifies when SatNOGS lists it as an active `Amateur` service with no frequency violation, not declined or uncoordinated by IARU, inside 145.8–146, 435–438, 1260–1270 or 2400–2450 MHz, and for public use. Command, telemetry and beacon links are excluded.

**Radios.** *USB radio* uses one the app finds plugged in. *Real radio* connects to a `rigctld` you run on this Mac:

```bash
brew install hamlib
```

```bash
rigctld -m YOUR_RADIO_MODEL -r /dev/cu.YOUR_RADIO -T 127.0.0.1
```

`rigctl --list` shows the model numbers. Test into a dummy load first, because no real radio has been tested with this yet.

**Modes so far:** FM voice with CTCSS, SSB voice, CW, APRS, packet at 1200 and 9600 baud, PSK31, RTTY, FT8 and FT4. Each uplink offers only the modes it can carry: linear transponders get SSB, CW and the digital text modes, and 9600 appears only where the listing says AX.25. On linear transponders the dial is offset so the whole signal stays inside the passband. Voice uses the radio's microphone by default; everything else needs an audio output chosen, and 9600 needs the radio's data port rather than its microphone input. FT8 and FT4 key on the next UTC slot, so keep holding until the message finishes and make sure your Mac's clock is accurate. Plain-text modes add `DE <callsign>` if the message lacks it. Transmit stops on release, timeout, low elevation, stale orbit data, a lost radio link, a change of satellite or uplink, or the app losing focus. If the app crashes, a small guard process unkeys the radio.

Every transmission is logged to `~/Documents/Vessel/transmit_log.csv`.

## Scanning for unlisted frequencies

Satellites with no public frequency get a **Scan** button in the Satellite panel. It listens through whatever source the Listener panel has selected, across likely bands, and tests each signal against the Doppler shift the satellite's orbit predicts. A signal that follows it is a good lead, not proof: only a successful decode confirms it. This only listens. SpyServer hosts must allow retuning, and are fastest because they stream a waterfall directly. Other radios restart the decoder engine for each window, so sweeps take longer.

## Data sources

| Data | Source | Refreshed |
|---|---|---|
| Orbital elements, categories | CelesTrak GP | 2 hours / 7 days |
| Owner country | CelesTrak SATCAT | 7 days |
| Downlink frequencies | SatNOGS DB | 1 day |
| Spy hosts | Airspy directory | 1 minute |
| Recent receptions, photos | SatNOGS Network and DB | 10 minutes, per locked satellite |
| Your location | macOS Wi-Fi positioning, then ipwho.is or ipapi.co, or GPS and GNSS-SDR with no Wi-Fi | Only when you click the crosshair |
| Telemetry formats | satnogs-decoders on GitLab | Checked daily, downloaded when changed |

Caches live in `~/Library/Application Support/Vessel`.

## What is inferred

- **Encryption** comes from the published design of each kind of system: Yes, Partly, No or Unknown, with the method where one is documented. No public catalogue records it per satellite.
- **Station frequencies:** modules, and vehicles docked at the ISS or CSS, show the station's radios and say so.
- **3D models** are labelled by how close they are: NASA's model of that spacecraft, of the same design family, or a stand-in of a similar type. Satellites with no model of their own, such as GPS, get a labelled stand-in, and a plain shape only if a model can't be loaded.
- **Signal level** is the demodulator's SNR when it reports one, otherwise an estimate from the spectrum (peak over noise floor).

## Layout

| Path | Contents |
|---|---|
| `Sources/CSGP4` | Vallado SGP4 with a C wrapper |
| `Sources/Vessel/Globe` | Metal renderer, shaders, mouse handling |
| `Sources/Vessel/Model` | Satellites, catalogues, countries |
| `Sources/Vessel/Radio` | SatDump process control, pipeline selection, spy directory |
| `Sources/Vessel/Transmit` | Uplink rules, Hamlib link, keying, signal generation |
| `Sources/Vessel/UI` | Stacked panels, 3D preview |
| `reference/SatDump` | SatDump source for reference (not built, not in git) |

## Scripted checks

`VESSEL_TEST` opens the app in a known state:

```bash
VESSEL_TEST="--lock 25544 --test-mouse --snapshot /tmp/shot" ./Vessel.app/Contents/MacOS/Vessel
```

Unit tests run with `swift test` (set `DEVELOPER_DIR` to Xcode). For the transmit path, start a dummy rig and let the app drive it:

```bash
rigctld -m 1 -T 127.0.0.1 -t 14532
```

```bash
VESSEL_TEST="--tx-test --i-started-a-dummy-rig --rig-port 14532" ./Vessel.app/Contents/MacOS/Vessel
```
