# CatFlapRelay configuration reference

## Relay options (`FlapRelayOption`)

| Property | CLI flag | Panel API field | Default | Notes |
|---|---|---|---|---|
| `Name` | `--name`, `-n` | `name` | `Unnamed` (CLI: `Relay_XXXX`) | Must be non-empty; Panel max length 128 |
| `ListenHost` | `--listen`, `-l` | `listenHost` | `127.0.0.1:56789` | IP literal + port |
| `TargetHost` | `--target`, `-t` | `targetHost` | `127.0.0.1:45678` | IP literal + port |
| `TCP` | `--no-tcp` | `tcp` | `true` | At least one of TCP / UDP must be on |
| `UDP` | `--no-udp`, `-U` | `udp` | `true` | |
| `BufferSize` | `--buffer-size`, `-b` | `bufferSize` | `131072` | TCP copy buffer, bytes. 1 to 64 MB (Panel: `PanelSettings:MaxBufferSize`) |
| `SocketTimeout` | `--timeout` (**ms**) | `socketTimeout` (**seconds**) | 1 s | TCP send/receive timeout |
| `UdpTunnelTimeout` | none | `udpTunnelTimeout` (seconds) | 60 s | A UDP client session is recycled after this much idle time |
| `UdpSenderCount` | `--udp-senders` | `udpSenderCount` | `1` | Power of two, 1 to 64 |
| `DualMode` | `--dual-mode` | `dualMode` | `false` | IPv6 listen address only (sets `IPV6_V6ONLY=false`) |

Validation is `FlapRelayFactory.ValidateOption`; the Panel returns 400 with the message for invalid values.

Builder equivalents: `WithName`, `ListenOn`, `ForwardTo`, `WithBufferSize`, `WithSocketTimeout`, `WithUdpTunnelTimeout`, `WithUdpSenderCount`, `EnableTCP`, `EnableUDP`, `TCPOnly`, `UDPOnly`, `EnableDualMode`.

## CLI logging

| Flag | Effect |
|---|---|
| `--verbose`, `-v` | Debug level |
| `--quiet`, `-q` | Warning level |
| `--log-level <level>` | `Verbose`, `Debug`, `Information`, `Warning`, `Error`, `Fatal`; wins over `-v` / `-q` |

## Statistics (`FlapRelayStatistics`)

| Field | Meaning |
|---|---|
| `IsRunning`, `StartTime`, `Uptime` | Run state. Uptime accumulates across stop/start |
| `TcpActiveConnections` | TCP connections being forwarded right now (goes up and down) |
| `TcpTotalConnections` | TCP connections accepted since the relay object was created |
| `UdpActiveTunnels` | Live UDP client sessions |
| `TcpBytesSent/Received`, `UdpBytesSent/Received` | Byte counters. "Sent" is client to target |
| `UdpPacketsDropped` | Datagrams discarded because a UDP sender queue was full |
| `ConnectionErrors` | Failed connects to the target |

Counters are not reset by stop/start, only when the relay object is recreated (for example after a Panel edit).

## Panel settings

Set in `appsettings.json` or as environment variables (`__` replaces `:`).

| Key | Env var | Default | Description |
|---|---|---|---|
| `Admin:UserName` | `Admin__UserName` | `admin` | Initial admin user |
| `Admin:Password` | `Admin__Password` | random, logged | Initial admin password |
| `JwtSettings:Key` | `JwtSettings__Key` | generated per start | Hex signing key. Set it to keep tokens valid across restarts |
| `Cors:AllowedOrigins` | `Cors__AllowedOrigins__0` | none | Allowed browser origins for the API |
| `DataPath` | `DataPath` | `data` (`/app/data` in Docker) | Directory for the SQLite database. Unwritable path falls back to in-memory |
| `ConnectionStrings:DefaultConnection` | `ConnectionStrings__DefaultConnection` | `Data Source=data/app.db;` | SQLite connection string |
| `PanelSettings:MaxRelays` | `PanelSettings__MaxRelays` | `256` | Maximum relays |
| `PanelSettings:MaxNameLength` | `PanelSettings__MaxNameLength` | `128` | |
| `PanelSettings:MaxEndpointLength` | `PanelSettings__MaxEndpointLength` | `64` | |
| `PanelSettings:MaxBufferSize` | `PanelSettings__MaxBufferSize` | `67108864` | Bytes |
| none | `CATFLAP_RESET_ADMIN` | unset | `true` resets the admin password on startup. Remove it afterwards |
| none | `ASPNETCORE_URLS` | `http://+:8080` (Docker) | Listen address of the web UI |

## REST API (`/api/v1`)

Every `relay` route needs `Authorization: Bearer <token>`.

| Method and route | Purpose |
|---|---|
| `POST /auth/token` | Body `{username, password, expiryDays}` (`expiryDays` 1 to 3650, default 30). Returns the JWT |
| `GET /relay` | List relays with statistics |
| `GET /relay/{id}` | One relay |
| `POST /relay` | Create and start. 400 invalid config, 409 duplicate name, port conflict, or `MaxRelays` reached |
| `PUT /relay/{id}` | Replace config, stop and restart the relay |
| `DELETE /relay/{id}` | Stop and remove |
| `POST /relay/{id}/start`, `POST /relay/{id}/stop` | Start or stop without removing |
| `POST /relay/start-all`, `POST /relay/stop-all` | Bulk start or stop |
| `DELETE /relay` | Stop and remove **all** relays |

Request body fields: `name`, `listenHost`, `targetHost`, `tcp`, `udp`, `bufferSize`, `socketTimeout` (s), `udpTunnelTimeout` (s), `dualMode`, `udpSenderCount`. Omitted fields take the defaults above.

Two relays conflict (409) when they use the same port, their listen addresses overlap (same IP, or either is `0.0.0.0` / `[::]`) and they share a protocol (both TCP or both UDP).

## Database upgrades

The Panel runs EF Core migrations on startup. Released migrations are never edited: a new column gets a new migration whose default fits existing rows (for example `UdpSenderCount` defaults to 1, since 0 fails validation).
