const args = new Map(
  Bun.argv.slice(2).map((arg) => {
    const eq = arg.indexOf("=");
    if (!arg.startsWith("--") || eq === -1) throw new Error(`bad arg: ${arg}`);
    return [arg.slice(2, eq), arg.slice(eq + 1)];
  }),
);

const url = args.get("url") ?? "ws://127.0.0.1:19090/ws";
const clients = Number(args.get("clients") ?? "200");
const durationMs = Number(args.get("duration-ms") ?? "30000");
const messagesPerConn = Number(args.get("messages-per-conn") ?? "32");

if (!Number.isFinite(clients) || !Number.isFinite(durationMs) || !Number.isFinite(messagesPerConn)) {
  throw new Error("numeric args are invalid");
}

const deadline = Date.now() + durationMs;
let connections = 0;
let sent = 0;
let received = 0;
let failures = 0;

async function oneConnection(workerId: number, round: number): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    let closed = false;
    let localSent = 0;
    let localReceived = 0;

    const ws = new WebSocket(url);

    ws.onopen = () => {
      connections += 1;
      for (let i = 0; i < messagesPerConn; i += 1) {
        const payload = `w${workerId}-r${round}-m${i}`;
        ws.send(payload);
        sent += 1;
        localSent += 1;
      }
    };

    ws.onmessage = (event) => {
      const text = String(event.data);
      if (!text.startsWith("user-0: ")) {
        failures += 1;
        ws.close();
        reject(new Error(`unexpected echo payload: ${text}`));
        return;
      }

      received += 1;
      localReceived += 1;
      if (localReceived === localSent) {
        ws.close(1000, "done");
      }
    };

    ws.onerror = () => {
      if (closed) return;
      failures += 1;
      reject(new Error("websocket error"));
    };

    ws.onclose = () => {
      closed = true;
      if (localReceived !== localSent) {
        failures += 1;
        reject(new Error(`connection closed early: sent=${localSent} received=${localReceived}`));
        return;
      }
      resolve();
    };
  });
}

async function worker(id: number): Promise<void> {
  let round = 0;
  while (Date.now() < deadline) {
    await oneConnection(id, round);
    round += 1;
  }
}

await Promise.all(Array.from({ length: clients }, (_, i) => worker(i)));

console.log(
  `bun websocket soak complete: clients=${clients} duration_ms=${durationMs} connections=${connections} sent=${sent} received=${received} failures=${failures}`,
);

if (failures !== 0) {
  process.exitCode = 1;
}
