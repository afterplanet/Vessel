# Licensing

Copyright © 2026 Ryvan Prabhu. Vessel is **dual-licensed**: you can use it under either of two licences.

## 1. Open source: GNU GPL v3.0

Vessel is free and open source under the [GNU General Public License v3.0](LICENSE). Under the GPL you may:

- use Vessel for any purpose, including personal use, learning, experimenting and research;
- study and change the source code;
- share copies, and share your changed versions.

If you distribute Vessel or anything built from it, you must do so under the GPL too. That means publishing the full source code of your version under the same licence. Nobody can take Vessel, change it, and ship it as closed source under this licence.

## 2. Commercial licence

If you want to use Vessel's code in a product whose source stays closed, or in any other way the GPL doesn't allow, you can buy a commercial licence from the copyright holder, Ryvan Prabhu.

To ask about a commercial licence, contact [@afterplanet on GitHub](https://github.com/afterplanet) or open an issue titled "Commercial licence enquiry". Terms are agreed case by case.

### What a commercial licence can cover

A commercial licence covers only the code whose copyright Ryvan Prabhu holds: Vessel's own source, and contributions made under the [Contributor Licence Agreement](CLA.md).

It **cannot** cover third-party components that are under their own licences. Vessel uses several of these, and the GPL ones need particular care:

| Component | Licence | How Vessel uses it |
|---|---|---|
| SatDump | GPL-3.0 | Built from source into the app as its receiving and decoding engine, run as a background program |
| GNSS-SDR | GPL-3.0 | Ships inside the app as a separate program, for GPS positions |
| ssdv (`Sources/CSSDV`) | GPL-3.0 | Compiled into the app, for SSDV pictures |
| ft8_lib (`Sources/CFT8`) | MIT | Compiled into the app |
| SGP4 (`Sources/CSGP4`) | MIT | Compiled into the app |
| Draco (`Sources/CDraco`) | Apache-2.0 | Compiled into the app |
| Yams | MIT | Swift package dependency |

A closed-source product built under a commercial licence would need to remove or replace the GPL components, or get permission from their own authors. The permissive (MIT and Apache-2.0) components can be kept, as long as their licence notices are kept.

## Contributions

To keep dual licensing possible, every contribution is accepted under the [Contributor Licence Agreement](CLA.md). You keep the copyright in your work, and grant Ryvan Prabhu the right to distribute it under both the GPL and commercial licences. See [CONTRIBUTING.md](CONTRIBUTING.md).

---

*This summary is for convenience and isn't legal advice. The [LICENSE](LICENSE) file and any signed commercial agreement are what count.*
