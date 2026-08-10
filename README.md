# Shipyard

Docker Compose setup for a single Raspberry Pi 5 running an ADS-B flight tracking
station. It feeds FlightRadar24 and FlightAware, and serves a local map and
system graphs.

Built on the excellent images from [sdr-enthusiasts](https://github.com/sdr-enthusiasts).

> No Docker Swarm — this is a plain `docker compose` deployment on one host.

## 🗂️ Services

All services live in a single stack: [flight-tracking/docker-compose.yml](flight-tracking/docker-compose.yml).

| Service | Image | Purpose |
| --- | --- | --- |
| `ultrafeeder` | `sdr-enthusiasts/docker-adsb-ultrafeeder` | ADS-B decoder, aggregator feeder, TAR1090 map, graphs1090 |
| `fr24` | `sdr-enthusiasts/docker-flightradar24` | FlightRadar24 feeder |
| `piaware` | `sdr-enthusiasts/docker-piaware` | FlightAware feeder |
| `airnavradar` | `sdr-enthusiasts/docker-airnavradar` | AirNav Radar (ex-RadarBox) feeder |
| `planefinder` | `sdr-enthusiasts/docker-planefinder` | Plane Finder feeder |
| `portainer` | `portainer/portainer-ee` | Container management UI |
| `watchtower` | `nickfedor/watchtower` | Automatic image updates + cleanup |

### Ports

| Port | Service |
| --- | --- |
| `8080` | Ultrafeeder web interface (TAR1090 map, graphs1090) |
| `8754` | FlightRadar24 feeder status |
| `30053` | Plane Finder web UI |
| `9443` | Portainer UI (HTTPS) |

Only `ultrafeeder` touches the SDR. Every other feeder pulls from it over Beast
on the Compose network, so one dongle serves all of them.

### Who gets fed how

Ultrafeeder feeds these **natively**, from one `ULTRAFEEDER_CONFIG` block — no
container each: adsb.fi, adsb.lol, airplanes.live, Planespotters, TheAirTraffic,
AVDelphi, FlyItalyADSB, ADSB Exchange.

The rest run their own container because they ship a closed feeder binary:
FlightRadar24, FlightAware, AirNav Radar, Plane Finder.

Adding another native aggregator is one line in `ULTRAFEEDER_CONFIG`. Note that
ADS-B feeding is nearly free, but each `mlat,` line is a separate sync process —
CPU climbs with the MLAT count, not the ADS-B count.

### Why FlightRadar24 has MLAT disabled

`fr24` is set to `MLAT=no`, which is what FR24 asks for when you feed other
networks. Two reasons it is the right call here:

1. **Timing.** FR24's MLAT wants a direct, unmodified feed from the SDR for
   accurate timestamps. In this stack `fr24` reads a relayed Beast stream from
   `ultrafeeder`, so its MLAT solution would be degraded anyway.
2. **Feedback loop.** `READSB_FORWARD_MLAT_SBS=true` and the mlathub mean
   MLAT-derived positions from other networks are merged into ultrafeeder's
   output. If FR24 ran MLAT over that stream it would treat synthetic positions
   as real receptions and poison its own solver.

`no` is already the container's default; it is set explicitly so the intent is
obvious. There is no `MLAT-without-gps` variable in this container — that line
in FR24's docs refers to their own `fr24feed.ini` on a bare-metal install.

## 🔌 Hardware

- Raspberry Pi 5
- RTL-SDR USB dongle + 1090 MHz antenna

Install the udev rules so the dongle is accessible without root:

```bash
sudo cp flight-tracking/60-rtl-sdr.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

## ⚙️ Configuration

[flight-tracking/temp.env](flight-tracking/temp.env) is the template, committed
with every key blank. On the Pi:

```bash
cd ~/git/Shipyard/flight-tracking && cp temp.env .env
```

Then fill it in. `.env` is git-ignored; `temp.env` is not, so never put real
keys in the template.

Two of the values are generated rather than looked up:

```bash
# MULTIFEEDER_UUID and ADSBX_UUID - run once each, paste into .env
cat /proc/sys/kernel/random/uuid
```

Where the keys come from:

| Key | Source |
| --- | --- |
| `FR24_SHARING_KEY` | https://www.flightradar24.com/share-your-data |
| `FLIGHTAWARE_FEEDER_ID` | https://flightaware.com/adsb/piaware/ |
| `PLANEFINDER_SHARECODE` | https://planefinder.net/sharing/create-sharecode |
| `AIRNAV_SHARING_KEY` | generated on first run — see below |

AirNav Radar has no signup page for the key. Leave it blank, start the stack,
and read the key the container generates on its first run:

```bash
docker compose logs airnavradar | grep -i key
```

Paste it into `.env` and `docker compose up -d airnavradar` again.

## 🚀 Running

```bash
cd flight-tracking
docker compose pull
docker compose up -d
```

Ultrafeeder persists data to `/opt/adsb/ultrafeeder/` on the host. The
containers create these directories on first run; to pre-create them:

```bash
sudo mkdir -p /opt/adsb/ultrafeeder/globe_history /opt/adsb/ultrafeeder/graphs1090
```

Then open the map at `http://<pi-address>:8080`.

## 🤖 Remote setup

[setup_remote.sh](setup_remote.sh) provisions the Pi from scratch: it clones this
repo to `~/git/Shipyard`, installs `~/update_shipyard.sh`, registers a daily
cronjob at 03:00 that pulls and redeploys, and runs the first deployment.

Run it **on the Pi**:

```bash
curl -fsSL https://raw.githubusercontent.com/TheQuietBlock/Shipyard/main/setup_remote.sh | bash
```

The script will not overwrite an existing `flight-tracking/.env` — copy yours
into place before or after the first run.

## 📂 Layout

```
.
├── flight-tracking/
│   ├── docker-compose.yml     # The whole stack
│   ├── 60-rtl-sdr.rules       # RTL-SDR udev rules
│   ├── temp.env               # Config template (committed, keys blank)
│   └── .env                   # Your config (git-ignored, cp from temp.env)
├── setup_remote.sh            # Pi provisioning + auto-update cronjob
└── README.md
```

## 🛠️ Troubleshooting

```bash
cd flight-tracking
docker compose ps
docker compose logs -f ultrafeeder
docker compose logs -f fr24
docker compose logs -f piaware
```

- **RTL-SDR not detected** — check `lsusb`, confirm the udev rules are installed,
  and make sure no host process (e.g. `dump1090`) is holding the dongle.
- **No aircraft on the map** — verify the antenna connection and that
  `FEEDER_LAT`/`FEEDER_LONG` are set; an unset location breaks MLAT.
- **Empty environment variables** — Compose reads `.env` from the directory you
  run it in, so run `docker compose` from inside `flight-tracking/`.
- **Auto-update log** — `~/update_shipyard.log` on the Pi.

## 💾 microSD wear

This host boots from a microSD card, so the stack is tuned to write as little
as possible:

- **Capped container logs.** Every service uses a shared `x-logging` anchor —
  `json-file`, 5 MB × 2 files. Docker's default is *unbounded*, and a chatty
  container filling `/var/lib/docker` is the fastest way to kill a card.
- **`LOGLEVEL=error`** on ultrafeeder, `DEBUG_LEVEL=0` on airnavradar,
  `VERBOSE_LOGGING=false` on fr24.
- **`tmpfs` for `/var/log`** on every feeder, so in-container logs never touch
  the card at all.
- **`MAX_GLOBE_HISTORY=7`** trims aircraft trace retention. `globe_history` is
  the busiest writer in the stack.

Two writers are deliberately left alone, because disabling them costs you real
features:

- `graphs1090` writes RRD data to `/opt/adsb/ultrafeeder/graphs1090` roughly
  every minute. You can move it to a tmpfs, but you lose all history on reboot.
- `globe_history` still writes traces. `READSB_ENABLE_TRACES=false` and
  `READSB_ENABLE_HEATMAP=false` would stop it, at the cost of the heatmap and
  replay features on the map.

If you want to be properly safe about it, put `/opt/adsb` on an external SSD or
USB stick — that is a bigger win than any of the tuning above.

## 🔒 Security

Upstream ships no hardening keys, so what is here is this repo's own:

- `no-new-privileges:true` on all five feeder containers.
- Portainer exposes only `9443` (HTTPS). Its plain-HTTP `9000` and the unused
  Edge agent port `8000` are not published — `9000` was an unencrypted admin
  interface on the LAN.
- Portainer and Watchtower mount `/var/run/docker.sock`, which is equivalent to
  root on this host. That is inherent to what they do; keep both off the public
  internet.
- `/proc/diskstats` is mounted read-only.
- No reverse proxy or TLS termination in this repo — everything is LAN-only.

Worth knowing: all images are pulled by floating tag (`:latest` or untagged)
and Watchtower auto-updates them nightly, so an upstream compromise reaches
this host without review. That is the normal trade for unattended patching, but
it is a trade.

## 📚 Resources

- [docker-adsb-ultrafeeder](https://github.com/sdr-enthusiasts/docker-adsb-ultrafeeder)
- [Watchtower](https://containrrr.dev/watchtower/)
