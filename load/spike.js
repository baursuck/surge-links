// Campaign spike: steady traffic, then a 10x jump in 10 seconds (an ad goes live).
// Run: docker compose --profile load run --rm k6            (spike)
//      SCENARIO=smoke docker compose --profile load run --rm k6
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8000';
const SCENARIO = __ENV.SCENARIO || 'spike';

const scenarios = {
  smoke: {
    executor: 'constant-vus', vus: 5, duration: '20s',
  },
  spike: {
    executor: 'ramping-arrival-rate',
    startRate: 50, timeUnit: '1s', preAllocatedVUs: 100, maxVUs: 1000,
    stages: [
      { target: 200, duration: '30s' },   // normal day
      { target: 2000, duration: '10s' },  // campaign starts
      { target: 2000, duration: '60s' },  // campaign holds
      { target: 200, duration: '20s' },   // back to normal
    ],
  },
};

export const options = {
  scenarios: { [SCENARIO]: scenarios[SCENARIO] },
  thresholds: {
    // Same numbers as the SLOs in docs/slo.md.
    'http_req_failed{kind:redirect}': ['rate<0.001'],
    'http_req_duration{kind:redirect}': ['p(99)<100'],
  },
};

export function setup() {
  const codes = [];
  for (let i = 0; i < 20; i++) {
    const res = http.post(`${BASE}/api/v1/links`,
      JSON.stringify({ target_url: `https://example.com/offer/${i}`, campaign: 'k6_spike' }),
      { headers: { 'Content-Type': 'application/json' } });
    check(res, { 'link created': (r) => r.status === 201 });
    codes.push(res.json('code'));
  }
  return { codes };
}

export default function (data) {
  // A few links take most of the traffic, like real campaigns.
  const idx = Math.random() < 0.8 ? Math.floor(Math.random() * 3)
                                   : Math.floor(Math.random() * data.codes.length);
  const res = http.get(`${BASE}/${data.codes[idx]}`, { redirects: 0, tags: { kind: 'redirect' } });
  check(res, { 'is 307': (r) => r.status === 307 });
}
