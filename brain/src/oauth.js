// Remote MCP servers that sign in with OAuth (e.g. Hevy at mcp.hevy.com): Brain is its own OAuth client, so they work from
// the Brain app and every Claude that uses Brain. `brain connect <name>` signs in once in the browser; the tokens stay in
// data/oauth/<name>.json and the SDK refreshes them. A server is listed in brain.config.json "remote": { name: url }.
import { execFile } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { UnauthorizedError } from "@modelcontextprotocol/sdk/client/auth.js";
import { p } from "./paths.js";
import { readJSON, writeJSON } from "./store.js";

const PORT = 33418;   // fixed, so the registered redirect URL stays valid
const REDIRECT = `http://127.0.0.1:${PORT}/callback`;
const file = (name) => p("oauth", `${name}.json`);

/** The SDK's OAuth client provider, persisted per server. Without `interactive`, a needed sign-in is an error to act on. */
export function provider(name, { interactive = false } = {}) {
  const load = () => readJSON(file(name), {});
  const store = (k, v) => { fs.mkdirSync(path.dirname(file(name)), { recursive: true }); writeJSON(file(name), { ...load(), [k]: v }); };
  return {
    get redirectUrl() { return REDIRECT; },
    get clientMetadata() {
      return { client_name: "Brain", redirect_uris: [REDIRECT], grant_types: ["authorization_code", "refresh_token"],
               response_types: ["code"], token_endpoint_auth_method: "none" };
    },
    clientInformation: () => load().client,
    saveClientInformation: (c) => store("client", c),
    tokens: () => load().tokens,
    saveTokens: (t) => store("tokens", t),
    saveCodeVerifier: (v) => store("verifier", v),
    codeVerifier: () => load().verifier,
    redirectToAuthorization: async (url) => {
      if (!interactive) throw new Error(`${name} needs a sign-in: run \`node ~/Developer/brain/src/cli.js connect ${name}\``);
      execFile("open", [url.toString()]);
    },
  };
}

export const connected = (name) => !!readJSON(file(name), {}).tokens;

export function transport(name, url, opts) {
  return new StreamableHTTPClientTransport(new URL(url), { authProvider: provider(name, opts) });
}

/** One-time sign-in in the browser; returns the server's tools once connected. */
export async function connect(name, url) {
  const server = http.createServer();
  await new Promise((ok, fail) => server.once("error", fail).listen(PORT, "127.0.0.1", ok));
  try {
    const code = new Promise((ok, fail) => {
      server.on("request", (req, res) => {
        const u = new URL(req.url, REDIRECT);
        if (u.pathname !== "/callback") { res.writeHead(404).end(); return; }
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<h2>Brain je pripojený k ${name}. Toto okno môžeš zavrieť.</h2>`);
        u.searchParams.get("code") ? ok(u.searchParams.get("code")) : fail(new Error(u.searchParams.get("error") || "not approved"));
      });
      setTimeout(() => fail(new Error("no sign-in within 5 minutes")), 300000).unref();
    });
    let t = transport(name, url, { interactive: true });
    let c = new Client({ name: "brain", version: "0.1.0" });
    try {
      await c.connect(t);
    } catch (e) {
      if (!(e instanceof UnauthorizedError)) throw e;
      await t.finishAuth(await code);
      t = transport(name, url);
      c = new Client({ name: "brain", version: "0.1.0" });
      await c.connect(t);
    }
    const tools = (await c.listTools()).tools.map((x) => x.name);
    await c.close();
    return { connected: name, tools };
  } finally {
    server.close();
  }
}
