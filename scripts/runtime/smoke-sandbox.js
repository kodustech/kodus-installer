// Smoke check of the Kody Runtime sandbox, run inside the runtime-worker
// container by scripts/runtime/smoke.sh (node, no dependency). It speaks to
// the worker's sandbox listener exactly as the product's runtime-sandbox
// provider does (kodus-ai libs/sandbox/infrastructure/providers/
// runtime-sandbox.client.ts): every request signed with the HMAC key derived
// from RUNTIME_SECRET_SEAL_KEY (libs/runtime/contracts/env-session.ts).
//   1. a sandbox opens on a cell and its guest agent runs a command;
//   2. a host on the sandbox's allow-list answers;
//   3. a host off the allow-list is refused.
// Env: SMOKE_ORG (organization id), SMOKE_ALLOWED_HOST (default github.com),
// SMOKE_DENIED_HOST (default example.com), SMOKE_URL (default the local listener).
'use strict';
const crypto = require('crypto');

const base = (process.env.SMOKE_URL || 'http://127.0.0.1:3430').replace(/\/+$/, '');
const org = process.env.SMOKE_ORG;
const allowed = process.env.SMOKE_ALLOWED_HOST || 'github.com';
const denied = process.env.SMOKE_DENIED_HOST || 'example.com';

function keyFrom(configured) {
    const v = (configured || '').trim();
    const seal = /^[0-9a-f]{64}$/i.test(v) ? Buffer.from(v, 'hex') : Buffer.from(v, 'base64');
    if (seal.length !== 32) throw new Error('RUNTIME_SECRET_SEAL_KEY must be 32 bytes');
    return crypto.createHmac('sha256', seal).update('kody-runtime/env-session/v1').digest();
}

function sign(key, method, path, body, at, nonce) {
    const bodyHash = crypto.createHash('sha256').update(body).digest('hex');
    const mac = crypto.createHmac('sha256', key).update(`${method}\n${path}\n${at}\n${nonce}\n${bodyHash}`).digest('hex');
    return `t=${at},n=${nonce},v1=${mac}`;
}

async function post(key, path, payload, timeoutMs) {
    const body = JSON.stringify(payload);
    const res = await fetch(base + path, {
        method: 'POST',
        headers: {
            'content-type': 'application/json',
            'x-kodus-env-signature': sign(key, 'POST', path, body, Date.now(), crypto.randomBytes(16).toString('hex')),
        },
        body,
        signal: AbortSignal.timeout(timeoutMs),
    });
    const text = await res.text();
    let parsed = {};
    try {
        parsed = JSON.parse(text);
    } catch {
        /* not JSON */
    }
    if (res.status !== 200) throw new Error(`${path} answered ${res.status}: ${parsed.code || ''} ${parsed.message || text.slice(0, 300)}`);
    return parsed;
}

const fetchProbe = (host) =>
    `node -e "fetch('https://${host}/',{signal:AbortSignal.timeout(15000)}).then(r=>{console.log('status',r.status);process.exit(0)},e=>{console.log('refused',e.cause&&e.cause.code||e.message);process.exit(7)})"`;

async function main() {
    if (!org) throw new Error('SMOKE_ORG (an organization id) is required');
    const key = keyFrom(process.env.RUNTIME_SECRET_SEAL_KEY);
    const ref = { organizationId: org, sandboxId: crypto.randomUUID() };
    let failed = 0;
    const check = (ok, what, detail) => {
        console.log(`${ok ? 'ok     ' : 'FAILED '} ${what}${detail ? `: ${detail}` : ''}`);
        if (!ok) failed++;
    };
    const exec = (command) =>
        post(key, '/sandbox/op', { ...ref, stepId: crypto.randomUUID(), op: { op: 'exec', command, timeoutMs: 30000 } }, 120000);

    const view = await post(key, '/sandbox/open', { ...ref, egressAllow: [allowed] }, 300000);
    check(view.state === 'ready', 'sandbox opens on a cell', view.state === 'ready' ? `cell ${view.cellId}` : JSON.stringify(view.blockers || []));
    if (view.state !== 'ready') process.exit(1);
    try {
        const echo = await exec('echo kodus-smoke-ok');
        check(echo.ok && echo.exec && echo.exec.exitCode === 0 && echo.exec.stdout.includes('kodus-smoke-ok'), 'the guest agent runs a command');
        const yes = await exec(fetchProbe(allowed));
        check(yes.exec && yes.exec.exitCode === 0, `${allowed} (on the allow-list) answers`, (yes.exec && yes.exec.stdout.trim()) || JSON.stringify(yes.error));
        const no = await exec(fetchProbe(denied));
        check(no.exec && no.exec.exitCode !== 0, `${denied} (off the allow-list) is refused`, (no.exec && no.exec.stdout.trim()) || JSON.stringify(no.error));
    } finally {
        await post(key, '/sandbox/release', ref, 30000).catch((e) => console.log(`warning: release failed: ${e.message}`));
    }
    process.exit(failed ? 1 : 0);
}

if (require.main === module) {
    main().catch((e) => {
        console.log(`FAILED  ${e.message}`);
        process.exit(1);
    });
}
module.exports = { keyFrom, sign };
