// UDP load generator + sink for relay benchmarks.
//
//   UdpLoad --sink 127.0.0.1:5201 --target 127.0.0.1:5202 --flows 8 --payload 64 --pps 200000 --duration 8
//
// Each flow is its own socket (= its own source port = its own "client" for the relay). Every datagram
// carries [flowId:int32][seq:int64]; the sink uses them to count loss and out-of-order delivery per flow.
// Run it once with --target equal to --sink to measure the generator/sink ceiling without the relay.

using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;

var a = ParseArgs(args);
var sinkEp = IPEndPoint.Parse(a.GetValueOrDefault("sink", "127.0.0.1:5201"));
var targetEp = IPEndPoint.Parse(a.GetValueOrDefault("target", "127.0.0.1:5202"));
int flows = int.Parse(a.GetValueOrDefault("flows", "1"));
int payload = Math.Max(12, int.Parse(a.GetValueOrDefault("payload", "64")));
long totalPps = long.Parse(a.GetValueOrDefault("pps", "100000"));
int seconds = int.Parse(a.GetValueOrDefault("duration", "8"));

var sentPerFlow = new long[flows];
var recvPerFlow = new long[flows];
var oooPerFlow = new long[flows];
var lastSeq = new long[flows];
Array.Fill(lastSeq, -1);

using var sink = new Socket(sinkEp.AddressFamily, SocketType.Dgram, ProtocolType.Udp);
sink.ReceiveBufferSize = 16 * 1024 * 1024;
sink.Bind(sinkEp);
sink.ReceiveTimeout = 500;

bool stopSink = false;
var sinkThread = new Thread(() =>
{
    var buf = new byte[65536];
    EndPoint any = new IPEndPoint(sinkEp.AddressFamily == AddressFamily.InterNetworkV6 ? IPAddress.IPv6Any : IPAddress.Any, 0);
    while (!Volatile.Read(ref stopSink))
    {
        int n;
        try { n = sink.ReceiveFrom(buf, ref any); }
        catch (SocketException) { continue; } // receive timeout
        if (n < 12) continue;
        int flow = BinaryPrimitives.ReadInt32LittleEndian(buf);
        long seq = BinaryPrimitives.ReadInt64LittleEndian(buf.AsSpan(4));
        if ((uint)flow >= (uint)flows) continue;
        recvPerFlow[flow]++;
        if (seq < lastSeq[flow]) oooPerFlow[flow]++; else lastSeq[flow] = seq;
    }
}) { IsBackground = true };
sinkThread.Start();

long perFlowPps = Math.Max(1, totalPps / flows);
long ticksPerSecond = Stopwatch.Frequency;
var start = Stopwatch.StartNew();
var threads = new Thread[flows];
for (int f = 0; f < flows; f++)
{
    int flow = f;
    threads[f] = new Thread(() =>
    {
        using var s = new Socket(targetEp.AddressFamily, SocketType.Dgram, ProtocolType.Udp);
        s.SendBufferSize = 4 * 1024 * 1024;
        var pkt = new byte[payload];
        BinaryPrimitives.WriteInt32LittleEndian(pkt, flow);
        long seq = 0;
        long t0 = Stopwatch.GetTimestamp();
        long end = t0 + seconds * ticksPerSecond;
        while (true)
        {
            long now = Stopwatch.GetTimestamp();
            if (now >= end) break;
            // packets that should have been sent by now at the target rate
            long due = (now - t0) * perFlowPps / ticksPerSecond;
            if (seq >= due) { Thread.SpinWait(50); continue; }
            long burst = Math.Min(due - seq, 256);
            for (long i = 0; i < burst; i++)
            {
                BinaryPrimitives.WriteInt64LittleEndian(pkt.AsSpan(4), seq);
                try { s.SendTo(pkt, targetEp); } catch (SocketException) { }
                seq++;
            }
        }
        sentPerFlow[flow] = seq;
    }) { IsBackground = true };
    threads[f].Start();
}
foreach (var t in threads) t.Join();
Thread.Sleep(1000); // let in-flight datagrams arrive
Volatile.Write(ref stopSink, true);
sinkThread.Join();

long sent = sentPerFlow.Sum(), recv = recvPerFlow.Sum(), ooo = oooPerFlow.Sum();
double secs = seconds;
Console.WriteLine($"flows={flows} payload={payload}B target={totalPps:N0}pps | sent {sent / secs:N0} pps, recv {recv / secs:N0} pps, " +
                  $"loss {(sent == 0 ? 0 : 100.0 * (sent - recv) / sent):F1}%, out_of_order {ooo}");

static Dictionary<string, string> ParseArgs(string[] args)
{
    var d = new Dictionary<string, string>();
    for (int i = 0; i + 1 < args.Length; i += 2)
        d[args[i].TrimStart('-')] = args[i + 1];
    return d;
}
