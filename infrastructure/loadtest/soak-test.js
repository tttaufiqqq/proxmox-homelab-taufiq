// plans/07-k3s-production-cutover-plan Stage 4 (soak period). Nobody knows
// this deployment exists yet, so there's zero organic traffic to observe
// behavior under sustained real-world use before app-server (the rollback
// safety net) gets powered off. This manufactures "close to real" traffic
// deliberately at low concurrency/think-time — node 1 (linux-k3s) is a
// single-core CT already running the k3s control-plane + all 3 asw-app
// replicas, so the goal is realistic load, not a stress test that DoSes
// our own single-core node.
//
// Run: k6 run soak-test.js
//
// To run longer, edit the `stages` array below directly — do NOT pass
// --duration/--vus on the CLI alongside this script. k6 treats any CLI
// execution flag as overriding the `scenarios` block entirely (silently,
// with only a WARN), which drops the 3-VU ramp-up/ramp-down and falls
// back to k6's bare default (1 VU, no ramp) instead of the soak profile
// below (found running this for real, 2026-08-02).
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = 'https://animal-shelter-workshop.tttaufiqqq.com';

// Real emails from the live users DB (see plan 07 Stage 3 verification).
// Picked per-VU below, not a single shared constant — Laravel's password
// reset token repository does delete-then-insert without a transaction,
// so two concurrent runs hammering the *same* email raced past the delete
// and both tried to insert, throwing a real 23505 unique-violation 500
// (found running two soak-test instances at once, 2026-08-02). Spreading
// across several real emails makes that collision as rare as it would be
// for actual distinct users, instead of guaranteed.
const RESET_EMAILS = ['admin2@gmail.com', 'caretaker2@gmail.com', 'shafiqah@gmail.com', 'atiqah@gmail.com', 'danish@gmail.com'];

export const options = {
  scenarios: {
    soak: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 3 },   // ramp up gently
        { duration: '56m', target: 3 },  // hold — adjust total soak time here
        { duration: '2m', target: 0 },   // ramp down
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<6000'],
  },
};

function think() {
  // Real users pause between actions — 3-10s, not back-to-back requests.
  sleep(3 + Math.random() * 7);
}

function browsePublicPages() {
  const pages = ['/', '/about', '/rescue-map'];
  const path = pages[Math.floor(Math.random() * pages.length)];
  const res = http.get(`${BASE}${path}`, { tags: { name: 'browse' } });
  check(res, { 'browse: status 200': (r) => r.status === 200 });
}

function checkDbStatus() {
  const res = http.get(`${BASE}/api/database-status`, { tags: { name: 'db-status' } });
  check(res, {
    'db-status: 200': (r) => r.status === 200,
    'db-status: allOnline': (r) => {
      try {
        return JSON.parse(r.body).allOnline === true;
      } catch {
        return false;
      }
    },
  });
}

function viewLoginPage() {
  const res = http.get(`${BASE}/login`, { tags: { name: 'login-page' } });
  check(res, { 'login-page: status 200': (r) => r.status === 200 });
}

function forgotPasswordFlow() {
  // k6 keeps one persistent cookie jar per VU automatically (like a real
  // browser session) — no need to pass one explicitly between requests.
  const getRes = http.get(`${BASE}/forgot-password`, { tags: { name: 'forgot-password-get' } });
  const match = getRes.body.match(/name="_token" value="([^"]+)"/);
  if (!match) return;
  const token = match[1];
  const email = RESET_EMAILS[Math.floor(Math.random() * RESET_EMAILS.length)];
  const postRes = http.post(
    `${BASE}/forgot-password`,
    { _token: token, email },
    { tags: { name: 'forgot-password-post' } }
  );
  // 302 = real submission accepted; 200 = Laravel's own password-reset
  // rate limiter throttling repeat requests for the same email (expected
  // and correct, not a bug) — only 419/500 are real failures here.
  const ok = check(postRes, {
    'forgot-password: not broken (419/500)': (r) => r.status === 302 || r.status === 200,
  });
  if (!ok) {
    console.log(`forgot-password unexpected status: ${postRes.status}`);
  }
}

export default function () {
  // Weighted action pick — mostly browsing, DB status occasionally,
  // forgot-password rarely (real users don't reset passwords every visit).
  const roll = Math.random();
  if (roll < 0.55) {
    browsePublicPages();
  } else if (roll < 0.78) {
    checkDbStatus();
  } else if (roll < 0.97) {
    viewLoginPage();
  } else {
    forgotPasswordFlow();
  }
  think();
}
