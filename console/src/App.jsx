import { useEffect, useState } from 'react';

const REFRESH_MS = 15000;

function useApi(path) {
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  useEffect(() => {
    let alive = true;
    const load = async () => {
      try {
        const r = await fetch(`/api${path}`);
        const j = await r.json();
        if (!alive) return;
        if (!r.ok) setError(j.error ?? `HTTP ${r.status}`);
        else { setData(j); setError(null); }
      } catch (e) {
        if (alive) setError(String(e));
      }
    };
    load();
    const t = setInterval(load, REFRESH_MS);
    return () => { alive = false; clearInterval(t); };
  }, [path]);
  return { data, error };
}

const time = (iso) => (iso ? new Date(iso).toISOString().replace('T', ' ').slice(0, 19) + ' UTC' : '-');
const duration = (s) => (s == null ? '-' : s < 60 ? `${s} s` : `${Math.floor(s / 60)} min ${s % 60} s`);

function Panel({ title, subtitle, children, testid }) {
  return (
    <section data-testid={testid} className="rounded-xl border border-slate-700 bg-slate-900 p-6">
      <h2 className="text-2xl font-bold text-white">{title}</h2>
      {subtitle && <p className="mt-1 text-base text-slate-300">{subtitle}</p>}
      <div className="mt-5">{children}</div>
    </section>
  );
}

function Empty({ children }) {
  return <p className="text-lg text-slate-300">{children}</p>;
}

function Badge({ state }) {
  const style = state === 'pass'
    ? 'bg-emerald-400 text-emerald-950'
    : state === 'fail' ? 'bg-rose-500 text-white' : 'bg-slate-500 text-white';
  return <span className={`rounded-md px-3 py-1 text-base font-extrabold tracking-wide ${style}`}>{state === 'pass' ? 'PASS' : state === 'fail' ? 'FAIL' : 'N/A'}</span>;
}

function Controls() {
  const { data, error } = useApi('/controls');
  if (error) return <Panel title="Controls" testid="controls"><Empty>Could not read the controls: {error}</Empty></Panel>;
  if (!data) return <Panel title="Controls" testid="controls"><Empty>Loading...</Empty></Panel>;
  if (!data.deployed) return <Panel title="Controls" testid="controls"><Empty>The workload VPC is not deployed.</Empty></Panel>;
  const passing = data.controls.filter((c) => c.state === 'pass').length;
  return (
    <Panel title="Controls" subtitle={`${passing} of ${data.controls.length} controls passing, read live from AWS`} testid="controls">
      <ul className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {data.controls.map((c) => (
          <li key={c.id} data-testid={`control-${c.id}`} className="flex flex-col gap-2 rounded-lg border border-slate-700 bg-slate-950 p-4">
            <div className="flex items-start justify-between gap-3">
              <span className="text-lg font-semibold text-white">{c.name}</span>
              <Badge state={c.state} />
            </div>
            <span className="text-base text-slate-300">{c.detail}</span>
          </li>
        ))}
      </ul>
      {data.ruleGroups?.length > 0 && (
        <details className="mt-5">
          <summary className="cursor-pointer text-lg font-semibold text-sky-300">Firewall rules, in evaluation order</summary>
          <ol className="mt-3 space-y-1 text-base">
            {data.ruleGroups.flatMap((g) => g.rules).map((r, i) => (
              <li key={i} className="flex gap-3">
                <span className={`w-14 font-bold uppercase ${r.action === 'pass' ? 'text-emerald-300' : 'text-rose-300'}`}>{r.action}</span>
                <span className="text-slate-100">{r.msg}</span>
              </li>
            ))}
            <li className="flex gap-3"><span className="w-14 font-bold uppercase text-rose-300">drop</span><span className="text-slate-100">Default: anything not passed above</span></li>
          </ol>
        </details>
      )}
      {data.endpoints?.length > 0 && (
        <p className="mt-4 text-base text-slate-300">
          Endpoints: {data.endpoints.map((e) => `${e.service} (${e.type.toLowerCase()})`).join(', ')}
        </p>
      )}
    </Panel>
  );
}

function Blocked() {
  const { data, error } = useApi('/blocked');
  const body = error ? <Empty>Could not read the firewall log: {error}</Empty>
    : !data ? <Empty>Loading...</Empty>
    : !data.deployed ? <Empty>Network Firewall logging is not deployed.</Empty>
    : data.events.length === 0 ? <Empty>No blocked or alerted traffic in the last 6 hours.</Empty>
    : (
      <div className="overflow-x-auto">
        <table className="w-full text-left text-base">
          <thead className="text-slate-300">
            <tr><th className="py-2 pr-4">Time</th><th className="pr-4">Action</th><th className="pr-4">Why</th><th className="pr-4">From</th><th className="pr-4">To</th><th>Detail</th></tr>
          </thead>
          <tbody>
            {data.events.map((e, i) => (
              <tr key={i} className="border-t border-slate-800 align-top">
                <td className="whitespace-nowrap py-2 pr-4 text-slate-300">{time(e.time)}</td>
                <td className={`pr-4 font-bold uppercase ${e.action === 'blocked' ? 'text-rose-300' : 'text-amber-300'}`}>{e.action}</td>
                <td className="pr-4 text-white">{e.reason}</td>
                <td className="pr-4 text-slate-200">{e.source}</td>
                <td className="pr-4 text-slate-200">{e.proto} {e.destination}</td>
                <td className="text-slate-200">{e.detail}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    );
  return <Panel title="Blocked attempts" subtitle="Network Firewall alert log, newest first" testid="blocked">{body}</Panel>;
}

function Findings() {
  const { data, error } = useApi('/findings');
  const body = error ? <Empty>Could not read Security Hub: {error}</Empty>
    : !data ? <Empty>Loading...</Empty>
    : !data.deployed ? <Empty>Security Hub CSPM is not enabled.</Empty>
    : data.findings.length === 0 ? <Empty>No active findings.</Empty>
    : (
      <ul className="space-y-2">
        {data.findings.map((f, i) => (
          <li key={i} className="flex flex-wrap items-baseline gap-3 border-t border-slate-800 pt-2">
            <span className={`w-24 font-bold ${['CRITICAL', 'HIGH'].includes(f.severity) ? 'text-rose-300' : f.severity === 'MEDIUM' ? 'text-amber-300' : 'text-slate-300'}`}>{f.severity}</span>
            <span className="w-60 text-sky-300">{f.source}{f.sample ? ' (sample)' : ''}</span>
            <span className="flex-1 text-white">{f.title}</span>
            <span className="text-slate-400">{time(f.updated)}</span>
          </li>
        ))}
      </ul>
    );
  return <Panel title="Security findings" subtitle="Security Hub CSPM: GuardDuty, firewall alerts (custom integration), failed controls" testid="findings">{body}</Panel>;
}

function Sessions() {
  const { data, error } = useApi('/sessions');
  const body = error ? <Empty>Could not read Session Manager: {error}</Empty>
    : !data ? <Empty>Loading...</Empty>
    : data.sessions.length === 0 ? <Empty>No Session Manager sessions recorded.</Empty>
    : (
      <table className="w-full text-left text-base">
        <thead className="text-slate-300">
          <tr><th className="py-2 pr-4">Started</th><th className="pr-4">Instance</th><th className="pr-4">Type</th><th className="pr-4">Duration</th><th className="pr-4">Status</th><th>By</th></tr>
        </thead>
        <tbody>
          {data.sessions.map((s, i) => (
            <tr key={i} className="border-t border-slate-800">
              <td className="whitespace-nowrap py-2 pr-4 text-slate-300">{time(s.start)}</td>
              <td className="pr-4 text-white">{s.target}</td>
              <td className="pr-4 text-slate-200">{s.document}</td>
              <td className="pr-4 text-slate-200">{duration(s.seconds)}</td>
              <td className="pr-4 text-slate-200">{s.status}</td>
              <td className="text-slate-200">{s.owner}</td>
            </tr>
          ))}
        </tbody>
      </table>
    );
  return <Panel title="Administrative access" subtitle="Every Session Manager session: no SSH, no bastion, no open inbound port" testid="sessions">{body}</Panel>;
}

export default function App() {
  return (
    <main className="mx-auto max-w-7xl space-y-6 p-8">
      <header>
        <h1 className="text-4xl font-extrabold text-white">Zero Trust Posture</h1>
        <p className="mt-2 text-lg text-slate-300">Payment platform on EKS, us-east-1. Live AWS data, refreshed every 15 seconds. Account IDs, ARNs, resource IDs and public IPs are masked.</p>
      </header>
      <Controls />
      <Blocked />
      <div className="grid gap-6 xl:grid-cols-2">
        <Findings />
        <Sessions />
      </div>
    </main>
  );
}
