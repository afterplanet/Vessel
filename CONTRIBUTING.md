# Contributing to Vessel

Thanks for helping make Vessel better. Vessel is version 1, so bug reports, ideas and feedback are just as valuable as code.

## Reporting a bug

[Open an issue](https://github.com/afterplanet/Vessel/issues) and include:

- what you did, what you expected, and what happened instead;
- your macOS version and Mac model;
- your radio (for example RTL-SDR Blog V4 or Airspy Mini), or the SpyServer host you used;
- the satellite you were tracking, if it matters.

Screenshots and the log from **Capture > Log** help a lot.

## Suggesting an idea

Open an issue describing what you'd like to do and why. It's easiest to agree on an approach before any code is written.

## Contributing code

1. Fork the repository and create a branch for your change.
2. Build with `./build_app.sh` and run the tests with `swift test`. See the [README](README.md) for setup.
3. Keep each pull request to one change, and add tests for new behaviour where you can.
4. Open a pull request and **tick the Contributor Licence Agreement box** in the template.

### Contributor Licence Agreement

Vessel is dual-licensed: it's open source under the GPL v3.0 and also offered under a commercial licence (see [LICENSING.md](LICENSING.md)). To make that possible, every contribution is accepted under the [Contributor Licence Agreement](CLA.md).

You keep the copyright in your work. The agreement gives the maintainer the right to distribute your contribution under both licences. Pull requests without the agreement can't be merged.

### Third-party code

Don't copy code from other projects into a pull request without saying where it came from and what licence it's under. Code under the GPL or another copyleft licence can't be accepted into Vessel's own source, because it couldn't be offered under the commercial licence.

## Transmit safety

Vessel only transmits on public amateur satellite uplinks, and only for licensed operators. Changes that remove these limits, add free tuning of the transmit frequency, or allow transmitting without a licence confirmation won't be accepted.
