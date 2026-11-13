# Checks that one render of charts/kodus-runtime's generated values agree across the Secrets and
# ConfigMaps that carry them (scripts/runtime/test-chart.sh).
# Usage: check-chart-render.py <rendered.yaml> <fullname>
import re, base64, sys
docs = open(sys.argv[1]).read().split('\n---\n')
P = sys.argv[2]
def doc(kind, name):
    for d in docs:
        if re.search(r'^kind: %s$' % kind, d, re.M) and re.search(r'^  name: %s$' % name, d, re.M):
            return d
    raise SystemExit('missing %s %s' % (kind, name))
def field(d, k):
    return re.search(r'^  %s: (\S+)$' % re.escape(k), d, re.M).group(1)
pki = doc('Secret', P + '-pki'); cm = doc('ConfigMap', P + '-cell')
ca = base64.b64decode(field(pki, 'ca.pem')).decode().strip()
hub = '\n'.join(l[4:] for l in re.search(r'hub-ca.pem: \|\n((?:    .*\n?)+)', cm).group(1).splitlines()).strip()
ob = doc('Secret', P + '-openbao'); cob = doc('Secret', P + '-cell-openbao'); st = doc('Secret', P + '-state')
checks = {
    'the cell trusts the hub CA the hub uses': ca == hub,
    'the injector logs in with the AppRole OpenBao made': field(ob, 'injector-role-id') == field(cob, 'injector-role-id') and field(ob, 'injector-secret-id') == field(cob, 'injector-secret-id'),
    'the injector trusts the OpenBao CA': field(pki, 'openbao-ca.pem') == field(cob, 'ca.pem'),
    'the unseal key is 32 raw bytes': len(base64.b64decode(field(st, 'unsealKey'))) == 32 and field(st, 'unsealKey') == field(ob, 'unseal.key'),
    'the seal key is 32 bytes of hex': re.fullmatch(r'[0-9a-f]{64}', base64.b64decode(field(st, 'sealKey')).decode()) is not None,
}
for k, v in checks.items():
    print(('ok     ' if v else 'FAILED ') + k)
sys.exit(0 if all(checks.values()) else 1)
