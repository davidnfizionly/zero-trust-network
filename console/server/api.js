// Dev-only API for the posture dashboard (Vite middleware, never shipped to the browser).
// Reads the live state of every control with the local AWS CLI credentials and returns
// plain JSON with account IDs, ARNs, resource IDs and public IP addresses masked.

import { fromNodeProviderChain } from '@aws-sdk/credential-providers';
import {
  EC2Client, DescribeVpcsCommand, DescribeSubnetsCommand, DescribeRouteTablesCommand,
  DescribeInstancesCommand, DescribeSecurityGroupRulesCommand, DescribeVpcEndpointsCommand,
  DescribeNetworkInterfacesCommand,
} from '@aws-sdk/client-ec2';
import { EKSClient, DescribeClusterCommand } from '@aws-sdk/client-eks';
import {
  NetworkFirewallClient, DescribeFirewallCommand, DescribeFirewallPolicyCommand, DescribeRuleGroupCommand,
} from '@aws-sdk/client-network-firewall';
import { CloudWatchLogsClient, FilterLogEventsCommand } from '@aws-sdk/client-cloudwatch-logs';
import { SecurityHubClient, GetFindingsCommand, DescribeHubCommand } from '@aws-sdk/client-securityhub';
import { GuardDutyClient, ListDetectorsCommand, GetDetectorCommand } from '@aws-sdk/client-guardduty';
import { SSMClient, DescribeSessionsCommand } from '@aws-sdk/client-ssm';

const REGION = 'us-east-1';
const WORKLOAD = 'payment-platform';
const CLUSTER = `${WORKLOAD}-eks`;
const FIREWALL = `${WORKLOAD}-zero-trust`;
const ALERT_LOG = '/zero-trust/network-firewall/alert';

const cfg = { region: REGION, credentials: fromNodeProviderChain() };
const ec2 = new EC2Client(cfg);
const eks = new EKSClient(cfg);
const nfw = new NetworkFirewallClient(cfg);
const logs = new CloudWatchLogsClient(cfg);
const hub = new SecurityHubClient(cfg);
const gd = new GuardDutyClient(cfg);
const ssm = new SSMClient(cfg);

// --- masking: stable short labels per value, so the UI stays readable ---
const labels = new Map();
const counters = {};
const label = (kind, value) => {
  if (!labels.has(value)) {
    counters[kind] = (counters[kind] ?? 0) + 1;
    labels.set(value, `${kind}-${counters[kind]}`);
  }
  return labels.get(value);
};
const isPrivate = (ip) => /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.|169\.254\.)/.test(ip);
export const mask = (text) => String(text ?? '')
  .replace(/arn:aws[a-z-]*:[^\s"',]+/g, (m) => label('arn', m))
  .replace(/\b(vpc|subnet|sg|eni|igw|nat|rtb|vpce|i|fw)-[0-9a-f]{8,17}\b/g, (m, k) => label(k, m))
  .replace(/\ba[0-9a-f]{31}\b/g, (m) => label('lb-name', m))
  .replace(/(?<![0-9A-Za-z])\d{12}(?![0-9A-Za-z])/g, '<account-id>')
  .replace(/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/g, (ip) => (isPrivate(ip) ? ip : label('public-ip', ip)));

const safe = async (fn, fallback) => {
  try { return await fn(); } catch (e) { return typeof fallback === 'function' ? fallback(e) : fallback; }
};
const control = (id, name, ok, detail, state = ok ? 'pass' : 'fail') => ({ id, name, state, detail: mask(detail) });

// --- controls ---
async function controls() {
  const vpc = (await ec2.send(new DescribeVpcsCommand({ Filters: [{ Name: 'tag:Name', Values: [`${WORKLOAD}-vpc`] }] }))).Vpcs?.[0];
  if (!vpc) return { deployed: false, controls: [] };
  const vpcFilter = [{ Name: 'vpc-id', Values: [vpc.VpcId] }];
  const [subnets, routeTables, instances, endpoints, enis] = await Promise.all([
    ec2.send(new DescribeSubnetsCommand({ Filters: vpcFilter })).then((r) => r.Subnets ?? []),
    ec2.send(new DescribeRouteTablesCommand({ Filters: vpcFilter })).then((r) => r.RouteTables ?? []),
    ec2.send(new DescribeInstancesCommand({ Filters: [...vpcFilter, { Name: 'instance-state-name', Values: ['running'] }] }))
      .then((r) => (r.Reservations ?? []).flatMap((x) => x.Instances ?? [])),
    ec2.send(new DescribeVpcEndpointsCommand({ Filters: vpcFilter })).then((r) => r.VpcEndpoints ?? []),
    ec2.send(new DescribeNetworkInterfacesCommand({ Filters: vpcFilter })).then((r) => r.NetworkInterfaces ?? []),
  ]);
  const out = [];

  // 1. Workload subnets are private: no public IP on launch, no route to the internet gateway.
  const workloadSubnets = subnets.filter((s) => (s.Tags ?? []).some((t) => t.Key === 'kubernetes.io/role/internal-elb'));
  const rtFor = (id) => routeTables.find((rt) => (rt.Associations ?? []).some((a) => a.SubnetId === id))
    ?? routeTables.find((rt) => (rt.Associations ?? []).some((a) => a.Main));
  const exposed = workloadSubnets.filter((s) => s.MapPublicIpOnLaunch
    || (rtFor(s.SubnetId)?.Routes ?? []).some((r) => (r.GatewayId ?? '').startsWith('igw-')));
  out.push(control('private-subnets', 'Workload subnets are private', exposed.length === 0 && workloadSubnets.length > 0,
    `${workloadSubnets.length} workload subnets, ${exposed.length} with a public IP setting or a route to the internet gateway`));

  // 2. No public IP on any workload instance.
  const nodes = instances.filter((i) => (i.Tags ?? []).some((t) => t.Key === 'eks:cluster-name'));
  const publicNodes = nodes.filter((i) => i.PublicIpAddress);
  out.push(control('no-public-ip', 'No public IP on workload nodes', publicNodes.length === 0,
    `${nodes.length} nodes, ${publicNodes.length} with a public IP`));

  // 3. Private Kubernetes API.
  const cluster = await safe(async () => (await eks.send(new DescribeClusterCommand({ name: CLUSTER }))).cluster, null);
  const pub = cluster?.resourcesVpcConfig?.endpointPublicAccess;
  out.push(control('private-api', 'Kubernetes API is private only', cluster && !pub,
    cluster ? `public access ${pub ? 'enabled' : 'disabled'}, private access ${cluster.resourcesVpcConfig.endpointPrivateAccess ? 'enabled' : 'disabled'}` : 'cluster not found'));

  // 4. Network Firewall in the path with default deny.
  const fw = await safe(async () => (await nfw.send(new DescribeFirewallCommand({ FirewallName: FIREWALL }))), null);
  let fwDetail = 'firewall not deployed';
  let fwOk = false;
  let ruleGroups = [];
  if (fw) {
    const policy = await nfw.send(new DescribeFirewallPolicyCommand({ FirewallPolicyArn: fw.Firewall.FirewallPolicyArn }));
    const defaults = policy.FirewallPolicy.StatefulDefaultActions ?? [];
    ruleGroups = await Promise.all((policy.FirewallPolicy.StatefulRuleGroupReferences ?? []).map(async (ref) => {
      const rg = await nfw.send(new DescribeRuleGroupCommand({ RuleGroupArn: ref.ResourceArn }));
      const rules = (rg.RuleGroup.RulesSource.RulesString ?? '').split('\n').filter((l) => /^(pass|drop|alert|reject)\s/.test(l));
      return {
        name: rg.RuleGroupResponse.RuleGroupName,
        rules: rules.map((l) => ({ action: l.split(' ')[0], msg: (l.match(/msg:"([^"]+)"/) ?? [])[1] ?? '' })),
      };
    }));
    const status = fw.FirewallStatus?.Status;
    fwOk = status === 'READY' && defaults.includes('aws:drop_established');
    fwDetail = `status ${status}, default action ${defaults.join(' + ') || 'none'}, ${ruleGroups.reduce((n, g) => n + g.rules.length, 0)} stateful rules`;
  }
  out.push(control('firewall', 'Network Firewall inspects traffic, default deny', fwOk, fwDetail));

  // 5. Single deliberate ingress: one internet-facing load balancer.
  const lbEnis = enis.filter((n) => n.Association?.PublicIp && (n.Description ?? '').startsWith('ELB '));
  const lbNames = new Set(lbEnis.map((n) => n.Description));
  out.push(control('single-ingress', 'One deliberate entry point', lbNames.size === 1,
    `${lbNames.size} internet-facing load balancer(s), ${enis.filter((n) => n.Association?.PublicIp).length} public IPs in the VPC (load balancer nodes and NAT)`));

  // 6. VPC endpoints.
  const available = endpoints.filter((e) => e.State?.toLowerCase() === 'available');
  out.push(control('endpoints', 'AWS APIs reached through VPC endpoints', available.length > 0 && available.length === endpoints.length,
    `${available.length} of ${endpoints.length} endpoints available`));

  // 7. Admin access: no inbound rule from a CIDR and none on port 22 on the node security groups.
  const sgIds = [...new Set(nodes.flatMap((i) => (i.SecurityGroups ?? []).map((g) => g.GroupId)))];
  let sgDetail = 'no nodes';
  let sgOk = false;
  if (sgIds.length) {
    const rules = (await ec2.send(new DescribeSecurityGroupRulesCommand({ Filters: [{ Name: 'group-id', Values: sgIds }] })))
      .SecurityGroupRules.filter((r) => !r.IsEgress);
    const cidr = rules.filter((r) => r.CidrIpv4 || r.CidrIpv6);
    const ssh = rules.filter((r) => r.IpProtocol !== '-1' && r.FromPort <= 22 && r.ToPort >= 22);
    sgOk = cidr.length === 0 && ssh.length === 0;
    sgDetail = `${rules.length} inbound rules on node security groups, ${cidr.length} from an IP range, ${ssh.length} covering port 22`;
  }
  out.push(control('no-ssh', 'No SSH, no inbound rule from outside the VPC', sgOk, sgDetail));

  // 8 and 9. Detection services.
  const detectorId = await safe(async () => (await gd.send(new ListDetectorsCommand({}))).DetectorIds?.[0], null);
  const detector = detectorId ? await safe(() => gd.send(new GetDetectorCommand({ DetectorId: detectorId })), null) : null;
  out.push(control('guardduty', 'GuardDuty enabled', detector?.Status === 'ENABLED', detector ? `detector ${detector.Status}` : 'no detector'));
  const hubOn = await safe(async () => Boolean(await hub.send(new DescribeHubCommand({}))), false);
  out.push(control('securityhub', 'Security Hub CSPM enabled', hubOn, hubOn ? 'hub subscribed' : 'not subscribed'));

  return {
    deployed: true,
    controls: out,
    ruleGroups,
    endpoints: endpoints.map((e) => ({
      service: e.ServiceName.split('.').slice(3).join('.'),
      type: e.VpcEndpointType,
      state: e.State,
    })).sort((a, b) => a.service.localeCompare(b.service)),
  };
}

// --- blocked attempts from the firewall alert log ---
const readable = (sig) => {
  if (!sig) return 'Alert';
  if (sig.includes('aws:alert_established')) return 'Default deny: no rule allows this established connection';
  return sig;
};
async function blocked() {
  const since = Date.now() - 6 * 3600 * 1000;
  const res = await safe(() => logs.send(new FilterLogEventsCommand({ logGroupName: ALERT_LOG, startTime: since, limit: 500 })), null);
  if (!res) return { deployed: false, events: [] };
  const events = (res.events ?? []).map((e) => {
    const ev = JSON.parse(e.message).event ?? {};
    return {
      time: new Date(e.timestamp).toISOString(),
      action: ev.alert?.action,
      reason: readable(ev.alert?.signature),
      proto: ev.proto,
      source: mask(`${ev.src_ip}`),
      destination: mask(`${ev.dest_ip}:${ev.dest_port ?? ''}`),
      detail: mask(ev.tls?.sni ? `TLS ${ev.tls.sni}` : ev.http?.url ? `HTTP ${ev.http.http_method ?? ''} ${ev.http.url}` : ''),
    };
  }).reverse().slice(0, 100);
  return { deployed: true, events };
}

// --- findings ---
async function findings() {
  const res = await safe(() => hub.send(new GetFindingsCommand({
    Filters: { RecordState: [{ Value: 'ACTIVE', Comparison: 'EQUALS' }], WorkflowStatus: [{ Value: 'NEW', Comparison: 'EQUALS' }] },
    SortCriteria: [{ Field: 'UpdatedAt', SortOrder: 'desc' }],
    MaxResults: 100,
  })), null);
  if (!res) return { deployed: false, findings: [] };
  const source = (f) => {
    if (f.ProductName === 'GuardDuty') return 'GuardDuty';
    if (f.ProductFields?.Source?.includes('Network Firewall')) return 'Network Firewall (custom)';
    if (f.ProductName === 'Security Hub') return 'Security Hub control';
    return f.ProductName ?? 'Other';
  };
  const list = (res.Findings ?? [])
    .filter((f) => f.Compliance?.Status !== 'PASSED')
    .map((f) => ({
      source: source(f),
      severity: f.Severity?.Label,
      title: mask(f.Title),
      sample: f.ProductFields?.['aws/guardduty/service/additionalInfo/sample'] === 'true' || /sample/i.test(f.Title ?? ''),
      updated: f.UpdatedAt,
    }));
  const order = { 'Network Firewall (custom)': 0, GuardDuty: 1 };
  list.sort((a, b) => (order[a.source] ?? 2) - (order[b.source] ?? 2));
  return { deployed: true, findings: list.slice(0, 40) };
}

// --- admin sessions ---
async function sessions() {
  const get = (state) => safe(async () => (await ssm.send(new DescribeSessionsCommand({ State: state, MaxResults: 20 }))).Sessions ?? [], []);
  const [active, history] = await Promise.all([get('Active'), get('History')]);
  const rows = [...active, ...history].map((s) => {
    const end = s.EndDate ? new Date(s.EndDate) : null;
    const start = s.StartDate ? new Date(s.StartDate) : null;
    return {
      target: mask(s.Target),
      document: s.DocumentName ?? 'Standard shell',
      status: s.Status,
      start: start?.toISOString(),
      seconds: start ? Math.round(((end ?? new Date()) - start) / 1000) : null,
      // The principal name is not shown, only its kind.
      owner: (s.Owner ?? '').includes(':user/') ? 'IAM user' : s.Owner ? 'IAM role' : '',
    };
  });
  rows.sort((a, b) => (b.start ?? '').localeCompare(a.start ?? ''));
  return { sessions: rows };
}

const routes = { '/controls': controls, '/blocked': blocked, '/findings': findings, '/sessions': sessions };

export function postureApi() {
  return {
    name: 'posture-api',
    configureServer(server) {
      server.middlewares.use('/api', async (req, res) => {
        const handler = routes[req.url.split('?')[0]];
        res.setHeader('Content-Type', 'application/json');
        if (!handler) { res.statusCode = 404; res.end('{}'); return; }
        try {
          res.end(JSON.stringify(await handler()));
        } catch (e) {
          res.statusCode = 500;
          res.end(JSON.stringify({ error: mask(e.message) }));
        }
      });
    },
  };
}
