#!/usr/bin/env node
// scout company <domain> [--fresh] · scout person "<name>" <domain> [--fresh] · scout list · scout block <email|domain> [--undo]
// · scout forget <email|domain> · scout people [--q=…] [--role=…] [--seniority=owner,c-level] [--industry=…] [--size=10-49] [--region=…]
// [--list=…] [--email] · scout companies [same filters] · scout lists [show|create|add|remove|delete] <name> [members…]
// · scout export [--list=…|filters]. JSON on stdout (the Scout app and Brain read it); export prints CSV.
import { block, company, exportCsv, forget, lists, overview, person, searchCompanies, searchPeople } from "./scout.js";

const [cmd, ...rest] = process.argv.slice(2);
const fresh = rest.includes("--fresh");
const args = rest.filter((a) => !a.startsWith("--"));
const opt = Object.fromEntries(rest.filter((a) => a.startsWith("--") && a.includes("=")).map((a) => a.slice(2).split(/=(.*)/s).slice(0, 2)));
for (const k of ["size", "seniority", "region", "country", "nace", "section", "legalForm", "origin", "confidence"]) if (opt[k]) opt[k] = opt[k].split(",");
for (const k of ["withSite", "withPeople", "includeDissolved", "noCount", "withEmail"]) if (rest.includes(`--${k}`)) opt[k] = true;
if (rest.includes("--email")) opt.emailOnly = true;
const log = process.env.SCOUT_VERBOSE ? (l) => console.error(l) : undefined;

const out = cmd === "company" ? await company(args[0], { fresh, log, org: opt.org })
  : cmd === "person" ? await person({ name: args[0], domain: args[1], fresh })
  : cmd === "list" ? overview()
  : cmd === "block" ? block(args[0], { undo: rest.includes("--undo") })
  : cmd === "forget" ? forget(args[0])
  : cmd === "people" ? searchPeople(opt)
  : cmd === "companies" ? searchCompanies(opt)
  : cmd === "lists" ? lists(args.length ? { action: args[0], name: args[1], members: args.slice(2) } : {})
  : cmd === "export" ? exportCsv(opt)
  : cmd === "prospect" ? (await import("./prospect.js")).prospect({ ...opt, listKey: opt.list && (await import("./scout.js")).listKey(opt.list) })
  : cmd === "prospect-people" ? (await import("./prospect.js")).prospectPeople(opt)
  : cmd === "org" ? (await import("./prospect.js")).orgDetail(args[0])
  : cmd === "facets" ? (await import("./prospect.js")).facets()
  : cmd === "export-companies" ? (await import("./prospect.js")).exportCompaniesCsv({ ...opt, listKey: opt.list && (await import("./scout.js")).listKey(opt.list) })
  : cmd === "enrich" ? await (async () => {
      // scout enrich SK:12345678 CZ:… [--list=…] [--fresh]: one JSON line per company as it finishes, then the summary
      const { enrichMany } = await import("./enrich.js");
      let ids = args;
      if (opt.list) ids = ids.concat((await import("./scout.js")).lists({ action: "show", name: opt.list }).companies.map((c) => c.id).filter(Boolean));
      return enrichMany(ids, { fresh, concurrency: Number(opt.concurrency) || 4, log: (l) => console.error(l),
        onResult: (r, n, total) => console.log(JSON.stringify({ progress: n, total, ...r })) });
    })()
  : cmd === "update" ? await (await import("./bulk.js")).update({ log: (l) => console.error(l) })
  : cmd === "import" ? await (await import("./bulk.js"))[args[0] === "cz" ? "importCZ" : "importSK"](args[1], { log: (l) => console.error(l) })
  : 'usage: scout company <domain> [--fresh] | person "<name>" <domain> | list | block <email|domain> [--undo] | forget <email|domain> | people [--filters] | companies [--filters] | lists [action name members…] | export [--list=…] | import sk|cz [file|dir] | update';
console.log(typeof out === "string" ? out : JSON.stringify(out, null, 2));
