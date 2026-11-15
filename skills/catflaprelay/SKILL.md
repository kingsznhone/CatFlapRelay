---
name: catflaprelay
description: Run, configure, or embed CatFlapRelay, a .NET 10 TCP/UDP port forwarder. Use for CLI flags, the Docker management Panel and its REST API, the CatFlapRelay NuGet library, UDP sender tuning, and config limits.
---

# CatFlapRelay

Dual-stack (IPv4/IPv6) TCP + UDP port forwarding. Three ways to use it:

| Component | Use it when | Entry point |
|---|---|---|
| `CatFlapRelay.CLI` | One relay, started from a shell | `catflaprelay-cli` |
| `CatFlapRelay.Panel` | Several relays, web UI + REST API, runs in Docker | `catflaprelay-panel`, port 8080 |
| `CatFlapRelay` (NuGet) | Embed the relay engine in your own .NET app | `FlapRelayFactory`, `FlapRelayManager` |

Full tables of options, limits, env vars and API routes: [reference.md](reference.md).

## CLI

```bash
dotnet build CatFlapRelay.CLI -c Release

# TCP + UDP relay
catflaprelay-cli -l 0.0.0.0:25565 -t 10.0.0.5:25565

# TCP only / UDP only
catflaprelay-cli -l 0.0.0.0:8080 -t 192.168.1.10:80 --no-udp
catflaprelay-cli -l [::]:53 -t 8.8.8.8:53 --no-tcp

# Many UDP clients at high packet rates, accept IPv4 on an IPv6 socket
catflaprelay-cli -l [::]:5000 -t 10.0.0.1:5000 --udp-senders 4 --dual-mode
```

Only `--listen` and `--target` are required. `-q` / `-v` / `--log-level` control logging.

## Panel (Docker)

```bash
docker run -d --name catflap-panel --network host \
  -v catflap-data:/app/data \
  -e Admin__UserName=admin -e Admin__Password=YourSecurePassword \
  kingsznhone/catflap-relay:latest
```

- Web UI `http://<host>:8080`, Swagger at `/swagger`.
- Use `--network host`: bridge networking puts NAT in front of the relays and breaks them.
- Without a mounted volume at `/app/data` the Panel falls back to an in-memory database and loses everything on restart.
- No `Admin__Password` set: a random one is printed to the container log.
- Forgot the password: run once with `CATFLAP_RESET_ADMIN=true`, then remove the variable.

REST API (`/api/v1`, JWT bearer):

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/api/v1/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"YourSecurePassword"}' | jq -r .token)

curl -X POST http://localhost:8080/api/v1/relay \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Game","listenHost":"0.0.0.0:25565","targetHost":"10.0.0.5:25565","udpSenderCount":1}'
```

A created relay is started immediately. An update stops and restarts it.

## Library

```csharp
using CatFlapRelay;

var relay = FlapRelayFactory.CreateBuilder(loggerFactory)   // NullLoggerFactory.Instance for no logging
    .WithName("MyRelay")
    .ListenOn("0.0.0.0:8080")
    .ForwardTo("192.168.1.100:3389")
    .WithUdpSenderCount(1)
    .Build();

relay.Start();                 // synchronous, there is no StartAsync
var stats = relay.Statistics;  // bytes, active tunnels, UdpPacketsDropped, ...
await relay.StopAsync();
await relay.DisposeAsync();
```

For several relays use `FlapRelayManager`: `AddRelay(option)` creates **and starts** the relay.

## Things that trip people up

- **Endpoints must be IP literals** (`127.0.0.1:80`, `[::1]:80`). Host names are rejected.
- **Units differ:** CLI `--timeout` is milliseconds, the Panel API's `socketTimeout` / `udpTunnelTimeout` are seconds.
- **`UdpSenderCount` must be a power of two, 1 to 64.** Leave it at 1 unless many clients send very high UDP packet rates. A client is pinned to one sender, so per-client order is preserved; a single client never gets more than one sender.
- **UDP overload drops datagrams** (UDP has no back-pressure). They are counted in `Statistics.UdpPacketsDropped` and shown as `Dropped` on the Panel card, red while it is still growing.
- **Dual mode** only matters for an IPv6 listen address; it is a no-op for IPv4 listen addresses.
- Two Panel relays conflict when they use the same port, their listen addresses overlap (same IP, or either is `0.0.0.0` / `[::]`) **and** they share a protocol. A TCP-only and a UDP-only relay may use the same port.
